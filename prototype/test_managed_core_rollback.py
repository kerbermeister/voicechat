from contextlib import nullcontext
from copy import deepcopy
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'infra'))
import core_deploy
import managed_core_rollback
import managed_state
import role_release
import test_core_deploy as core_tests
from test_full_rollout_fence import fence


class ManagedCoreRollbackTests(unittest.TestCase):
    def setUp(self):
        self.fixture=core_tests.CoreDeployTests();self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root=self.fixture.root;self.original_execute=self.fixture.execute
        self.fixture.execute=self.execute
        self.configures=0;self.restores=0;self.crash_configure=False
        self.fixture.deploy(self.fixture.old)
        self.policy=deepcopy(self.fixture.policy);self.identity=self.fixture.data_identity.copy()
        self.active_reader=False

    def execute(self,args,**kwargs):
        if args[:2]==['docker','ps']:
            self.fixture.calls.append(args);return ('1'*64+'\n').encode() if self.active_reader else b''
        if args[:2]==['docker','inspect'] and '{{json .Mounts}}' in args:
            import json
            self.fixture.calls.append(args)
            return (json.dumps([{'Type':'bind','Source':str(self.root/'backups/repository')}])+'\n').encode()
        configure='up' in args and args[-1]=='configure'
        if configure:self.assertFalse(self.fixture.running,'Configure rewrote live writers')
        result=self.original_execute(args,**kwargs)
        if '--volume' in args and ':/prior-policy.json:ro' in ' '.join(args):
            self.assertFalse(self.fixture.running,'Policy restored while writers were running')
            source=next(item.removesuffix(':/prior-policy.json:ro') for item in args if item.endswith(':/prior-policy.json:ro'))
            self.fixture.policy=managed_state.read(Path(source));self.restores+=1
        if configure:
            self.configures+=1
            manifest=role_release.load(Path(args[args.index('-f')+1]).parent.parent/'release.json')
            if manifest==self.fixture.new:
                self.fixture.policy.setdefault('candidate_default',True)
                if self.crash_configure:
                    self.crash_configure=False
                    raise KeyboardInterrupt('Lost process after candidate configure')
        return result

    def health(self, root, record, **kwargs):
        if not self.fixture.running:raise RuntimeError('Committed services are down')
        return self.fixture.healthy(root,record,**kwargs)

    def own(self):
        self.marker=fence(self.root,self.fixture.old)

    def rollback(self):
        return managed_core_rollback.rollback(self.root,self.fixture.public,self.fixture.inventory,
            self.fixture.old,self.fixture.new,self.identity,self.marker['attempt'],
            execute=self.execute,check_network=lambda *a,**kw:nullcontext(),check_boot=lambda *a:None,
            check_health=self.health,identify_data=lambda *a,**kw:self.fixture.data_identity.copy(),
            activate_monitor=lambda *a:None)

    def test_committed_candidate_rollback_removes_its_policy_defaults_without_restoring_data(self):
        self.fixture.deploy(self.fixture.new);self.assertIn('candidate_default',self.fixture.policy)
        self.own();self.fixture.calls.clear();before=self.configures
        result=self.rollback()
        self.assertEqual(result['manifest'],self.fixture.old)
        self.assertEqual(self.fixture.state()['current']['manifest'],self.fixture.old)
        self.assertEqual(self.fixture.state()['previous']['manifest'],self.fixture.new)
        self.assertEqual(self.fixture.policy,self.policy);self.assertEqual(self.restores,1)
        self.assertEqual(self.fixture.data_identity,self.identity);self.assertTrue(self.fixture.running)
        self.assertIsNone(self.fixture.state()['pending']);self.assertEqual(self.configures,before+1)
        self.assertFalse(any('pg_restore' in args or 'rm' in args for args in self.fixture.calls))
        self.fixture.calls.clear();before=self.configures;self.rollback()
        self.assertEqual(self.configures,before)
        self.assertFalse(any('up' in args or 'stop' in args for args in self.fixture.calls))

    def test_interrupted_inner_apply_is_restored_from_the_original_policy(self):
        self.crash_configure=True
        with self.assertRaises(KeyboardInterrupt):self.fixture.deploy(self.fixture.new)
        self.assertEqual(self.fixture.state()['pending']['phase'],'applying')
        self.assertIn('candidate_default',self.fixture.policy)
        self.own();self.rollback()
        self.assertEqual(self.fixture.policy,self.policy)
        self.assertEqual(self.fixture.state()['current']['manifest'],self.fixture.old)
        self.assertIsNone(self.fixture.state()['pending']);self.assertTrue(self.fixture.running)

    def test_prepared_attempt_ignores_stale_snapshot_and_does_not_reconfigure(self):
        previous=self.fixture.state()['current'];candidate=core_deploy.record_for(self.root,self.fixture.inventory,self.fixture.new)
        managed_state.persist(core_deploy.policy_path(self.root,candidate),{'obsolete_snapshot':True})
        managed_state.persist(self.root/'state.json',{**self.fixture.state(),'pending':{'target':candidate,'phase':'prepared'}})
        self.own();before=self.configures;self.rollback()
        self.assertEqual(self.configures,before);self.assertEqual(self.fixture.policy,self.policy)
        self.assertEqual(self.fixture.state()['current'],previous);self.assertIsNone(self.fixture.state()['pending'])
        self.assertEqual(self.restores,0)

    def test_lost_rollback_commit_reply_does_not_replay_configure(self):
        self.fixture.deploy(self.fixture.new);self.own();persist=managed_state.persist
        def crash(path,value):
            if path.name.startswith('rollback-') and value.get('phase')=='committed':raise InterruptedError('lost commit reply')
            return persist(path,value)
        with patch.object(managed_state,'persist',side_effect=crash):
            with self.assertRaises(InterruptedError):self.rollback()
        self.assertEqual(self.fixture.state()['current']['manifest'],self.fixture.old)
        self.assertIsNone(self.fixture.state()['pending']);before=self.configures
        self.rollback();self.assertEqual(self.configures,before);self.assertEqual(self.fixture.policy,self.policy)

    def test_resume_starting_stops_live_writers_before_any_configure(self):
        self.fixture.deploy(self.fixture.new);self.own()
        original=self.execute;crash=True
        def after_up(args,**kwargs):
            nonlocal crash
            result=original(args,**kwargs)
            if crash and 'up' in args and args[-1]!='configure':
                crash=False;raise KeyboardInterrupt('lost response after previous writers started')
            return result
        self.execute=after_up
        with self.assertRaises(KeyboardInterrupt):self.rollback()
        self.assertTrue(self.fixture.running);self.assertEqual(self.fixture.state()['pending']['phase'],'managed-rollback')
        self.execute=original;self.rollback()
        self.assertTrue(self.fixture.running);self.assertEqual(self.fixture.policy,self.policy)
        self.assertIsNone(self.fixture.state()['pending'])

    def test_missing_or_modified_policy_snapshot_is_not_replaced_with_defaults(self):
        self.fixture.deploy(self.fixture.new);self.own();candidate=self.fixture.state()['current']
        core_deploy.policy_path(self.root,candidate).unlink();self.fixture.calls.clear()
        with self.assertRaises(FileNotFoundError):self.rollback()
        self.assertFalse(any('up' in args or 'stop' in args for args in self.fixture.calls))
        self.assertEqual(self.fixture.state()['current']['manifest'],self.fixture.new)
        self.assertIn('candidate_default',self.fixture.policy)

    def test_cancel_before_candidate_configuration_recovers_previous_without_configure(self):
        candidate=core_deploy.record_for(self.root,self.fixture.inventory,self.fixture.new)
        managed_state.persist(self.root/'state.json',{**self.fixture.state(),'pending':{'target':candidate,'phase':'stopping'}})
        self.fixture.running=False;self.own();before=self.configures
        self.rollback()
        self.assertTrue(self.fixture.running);self.assertIsNone(self.fixture.state()['pending'])
        self.assertEqual(self.configures,before);self.assertEqual(self.restores,0)

    def test_modified_snapshot_and_generic_deploy_cannot_bypass_pending_outer_rollback(self):
        self.fixture.deploy(self.fixture.new);self.own();persist=managed_state.persist
        def crash(path,value):
            if path.name.startswith('rollback-') and value.get('phase')=='starting':raise InterruptedError('lost phase write')
            return persist(path,value)
        with patch.object(managed_state,'persist',side_effect=crash):
            with self.assertRaises(InterruptedError):self.rollback()
        self.assertEqual(self.fixture.state()['pending']['phase'],'managed-rollback')
        with self.assertRaisesRegex(ValueError,'owned managed core rollback'):
            core_deploy.deploy(self.root,self.fixture.public,self.fixture.inventory,self.fixture.old,
                execute=self.execute,check_network=lambda *a,**kw:nullcontext(),check_boot=lambda *a:None,
                activate_monitor=lambda *a:None,rollout_attempt=self.marker['attempt'])
        candidate=core_deploy.record_for(self.root,self.fixture.inventory,self.fixture.new)
        managed_state.persist(core_deploy.policy_path(self.root,candidate),{'modified_snapshot':True})
        self.fixture.calls.clear()
        with self.assertRaisesRegex(ValueError,'policy snapshot changed'):self.rollback()
        self.assertFalse(any('up' in args or 'stop' in args for args in self.fixture.calls))
        self.assertFalse(self.fixture.running)

    def test_orphaned_backup_is_waited_for_without_killing_it_or_starting_writers(self):
        self.fixture.deploy(self.fixture.new);self.own()
        (self.root/'backups/repository').mkdir(parents=True,mode=0o700)
        self.active_reader=True;self.fixture.calls.clear()
        with self.assertRaisesRegex(ValueError,'backup container still uses'):self.rollback()
        self.assertFalse(any('up' in args or 'stop' in args or 'rm' in args for args in self.fixture.calls))
        self.active_reader=False;self.rollback();self.assertEqual(self.fixture.policy,self.policy)

    def test_changed_data_identity_or_foreign_attempt_is_rejected_before_mutation(self):
        self.fixture.deploy(self.fixture.new);self.own();self.fixture.calls.clear()
        self.fixture.data_identity['signing_sha256']='0'*64
        with self.assertRaisesRegex(ValueError,'data identity changed'):self.rollback()
        self.assertEqual(self.fixture.calls,[])
        self.fixture.data_identity=self.identity.copy();self.marker['attempt']='b'*64
        with self.assertRaisesRegex(ValueError,'Finish the full rollout'):self.rollback()
        self.assertEqual(self.fixture.calls,[])
