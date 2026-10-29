from contextlib import nullcontext
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'infra'))
import edge_deploy
import managed_edge_rollback
import managed_state
import role_release
import test_edge_deploy
from test_full_rollout_fence import fence


class ManagedEdgeRollbackTests(unittest.TestCase):
    def setUp(self):
        self.fixture=test_edge_deploy.EdgeDeployTests();self.fixture.setUp();self.addCleanup(self.fixture.doCleanups)
        self.root=self.fixture.root;self.fixture.deploy(self.fixture.old)
        self.marker=None

    def own(self):self.marker=fence(self.root,self.fixture.old)

    def rollback(self,scope='edge'):
        return managed_edge_rollback.rollback(self.root,self.fixture.public,self.fixture.inventory,
            self.fixture.old,self.fixture.new,self.marker['attempt'],scope=scope,
            execute=self.fixture.execute,check_network=lambda *a,**kw:nullcontext(),
            check_boot=lambda *a:None,activate_monitor=lambda *a:None,
            check_health=self.health)

    def health(self,root,record,**kw):
        if not self.fixture.running:raise RuntimeError('Edge is down')
        return self.fixture.health(root,record,**kw)

    def test_web_rollback_changes_only_web_and_preserves_previous_bundle(self):
        self.fixture.deploy(self.fixture.new,'web');self.own();self.fixture.calls.clear()
        before=(edge_deploy.release_path(self.root,self.fixture.state()['previous'])/'infra/Caddyfile').read_bytes()
        self.rollback('web')
        self.assertEqual(self.fixture.state()['current']['manifest'],self.fixture.old)
        self.assertEqual(self.fixture.state()['previous']['manifest'],self.fixture.new)
        self.assertEqual([a[-2:] for a in self.fixture.calls if 'up' in a],[['180','web']])
        self.assertFalse(any('stop' in a or 'configure'==a[-1] for a in self.fixture.calls))
        self.assertEqual((edge_deploy.release_path(self.root,self.fixture.state()['current'])/'infra/Caddyfile').read_bytes(),before)
        self.fixture.calls.clear();self.rollback('web');self.assertEqual(self.fixture.calls,[])

    def test_full_rollback_waits_for_configure_and_never_renders_old_source(self):
        self.fixture.deploy(self.fixture.new);self.own();self.fixture.calls.clear()
        with patch.object(role_release,'verify_bundle',side_effect=AssertionError('Must use recorded bundle')):
            self.rollback()
        commands=self.fixture.calls
        stop=next(i for i,a in enumerate(commands) if 'stop' in a)
        configure=next(i for i,a in enumerate(commands) if 'up' in a and a[-1]=='configure')
        wait=next(i for i,a in enumerate(commands) if 'wait' in a)
        up=next(i for i,a in enumerate(commands) if 'up' in a and a[-1]!='configure')
        self.assertLess(stop,configure);self.assertLess(configure,wait);self.assertLess(wait,up)
        self.assertTrue(self.fixture.running);self.assertIsNone(self.fixture.state()['pending'])

    def test_prepared_cancel_does_not_touch_services(self):
        candidate=edge_deploy.record_for(self.fixture.public,self.fixture.inventory,self.fixture.new)
        managed_state.persist(self.root/'state.json',{**self.fixture.state(),'pending':{'target':candidate,'scope':'edge','phase':'prepared'}})
        self.own();self.fixture.calls.clear();self.rollback()
        self.assertEqual(self.fixture.calls,[]);self.assertIsNone(self.fixture.state()['pending'])

    def test_interrupted_inner_apply_can_be_rolled_back(self):
        self.fixture.interrupt=True
        with self.assertRaises(KeyboardInterrupt):self.fixture.deploy(self.fixture.new)
        self.fixture.interrupt=False;self.own();self.rollback()
        self.assertEqual(self.fixture.state()['current']['manifest'],self.fixture.old)
        self.assertIsNone(self.fixture.state()['pending']);self.assertTrue(self.fixture.running)

    def test_interrupted_outer_apply_is_fenced_and_can_resume(self):
        self.fixture.deploy(self.fixture.new);self.own();self.fixture.interrupt=True
        with self.assertRaises(KeyboardInterrupt):self.rollback()
        self.assertEqual(self.fixture.state()['pending']['phase'],'managed-rollback')
        with self.assertRaisesRegex(ValueError,'owned managed edge rollback'):
            edge_deploy.deploy(self.root,self.fixture.public,self.fixture.inventory,self.fixture.old,self.fixture.core,
                execute=self.fixture.execute,check_network=lambda *a,**kw:nullcontext(),check_boot=lambda *a:None,
                activate_monitor=lambda *a:None,rollout_attempt=self.marker['attempt'])
        self.fixture.interrupt=False;self.rollback()
        self.assertEqual(self.fixture.state()['current']['manifest'],self.fixture.old)

    def test_lost_commit_reply_never_restarts_healthy_services(self):
        self.fixture.deploy(self.fixture.new,'web');self.own();persist=managed_state.persist
        def lost(path,value):
            persist(path,value)
            if path.name.startswith('rollback-') and value.get('phase')=='committed':
                raise KeyboardInterrupt('Lost commit reply')
        with patch.object(managed_state,'persist',side_effect=lost):
            with self.assertRaises(KeyboardInterrupt):self.rollback('web')
        self.fixture.calls.clear();self.rollback('web');self.assertEqual(self.fixture.calls,[])

    def test_tls_tampering_or_foreign_nonce_is_rejected_before_up(self):
        self.fixture.deploy(self.fixture.new);self.own();self.fixture.calls.clear()
        with patch.object(edge_deploy,'certificate',side_effect=ValueError('Invalid TLS')):
            with self.assertRaisesRegex(ValueError,'Invalid TLS'):self.rollback()
        self.assertEqual(self.fixture.calls,[])
        self.marker['attempt']='e'*64
        with self.assertRaisesRegex(ValueError,'Finish the full rollout'):self.rollback()
        self.assertEqual(self.fixture.calls,[])

    def test_changed_scope_or_recorded_bundle_cannot_resume_rollback(self):
        self.fixture.deploy(self.fixture.new);self.own();self.fixture.interrupt=True
        with self.assertRaises(KeyboardInterrupt):self.rollback()
        self.fixture.interrupt=False;self.fixture.calls.clear()
        with self.assertRaisesRegex(ValueError,'same valid managed edge rollback'):self.rollback('web')
        self.assertEqual(self.fixture.calls,[])
        path=edge_deploy.release_path(self.root,self.fixture.state()['current'])/'infra/Caddyfile'
        path.write_text('tampered')
        with self.assertRaises(ValueError):self.rollback()
        self.assertEqual(self.fixture.calls,[])
