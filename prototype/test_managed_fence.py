from copy import deepcopy
from contextlib import nullcontext, ExitStack
import tempfile
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'infra'))
import managed_fence
import edge_deploy
import role_bootstrap
import role_prepare
import topology
import managed_state
import role_deploy
import role_release
import test_managed_release as baseline_tests
from test_node_inventory import key, fixture


class ManagedFenceTests(unittest.TestCase):
    execute = baseline_tests.ManagedBaselineInspectionTests.execute

    def setUp(self):
        baseline_tests.ManagedBaselineInspectionTests.setUp(self)
        self.target=deepcopy(self.manifest);self.target['commit']='b'*40
        self.attempt='a'*64;self.activated=Mock()

    def invoke(self, name, *args, attempt=None, run=None):
        options={'system_root':self.system,'run':run or (lambda *args:'0')}
        if name != 'retarget':options['execute']=self.execute
        if name == 'release':options['activate']=self.activated
        return getattr(managed_fence,name)(self.root,self.public,self.inventory,self.manifest,self.target,
                                          *args,attempt or self.attempt,**options)

    def test_claim_repeat_observe_and_cancel_preserve_apps_and_committed_state(self):
        original=managed_state.read(self.root/'state.json')
        proof=self.invoke('claim');self.assertEqual(proof['facts']['manifest'],self.manifest)
        self.assertEqual(proof['fence'],{'attempt':self.attempt,'target':role_release.json_digest(self.target)})
        self.assertEqual(self.invoke('claim'),proof)
        self.assertEqual(self.invoke('observe',self.manifest),proof)
        with self.assertRaisesRegex(ValueError,'Commit or roll back'):
            self.invoke('release',self.manifest)
        self.invoke('retarget',self.manifest)
        released=self.invoke('release',self.manifest)
        self.assertIsNone(released['fence']);self.assertEqual(released['facts']['manifest'],self.manifest)
        self.assertEqual(self.invoke('release',self.manifest),released)
        self.assertFalse(role_deploy.in_maintenance(self.root))
        self.assertEqual(managed_state.read(self.root/'state.json'),original)
        self.assertEqual(self.activated.call_count,2)
        self.assertFalse(any('up' in args or 'stop' in args for args in self.calls))

    def test_interrupted_first_claim_recovers_exact_marker_without_intent(self):
        persist=managed_state.persist
        def crash(path,value):
            if path == self.root/'runtime/managed-release.json':raise InterruptedError('intent write interrupted')
            return persist(path,value)
        with patch.object(managed_state,'persist',side_effect=crash):
            with self.assertRaises(InterruptedError):self.invoke('claim')
        self.assertIsNone(role_deploy.managed_operation(self.root))
        self.assertEqual(role_deploy.pending_rollout(self.root)['attempt'],self.attempt)
        proof=self.invoke('claim');self.assertEqual(proof['facts']['manifest'],self.manifest)
        self.assertEqual(role_deploy.managed_operation(self.root)['phase'],'held')

    def test_release_crash_after_marker_removal_remains_fenced_by_peer_intent(self):
        self.invoke('claim');self.invoke('retarget',self.manifest);persist=managed_state.persist
        def crash(path,value):
            if path == self.root/'runtime/managed-release.json' and value['phase']=='released':
                raise InterruptedError('release receipt write interrupted')
            return persist(path,value)
        with patch.object(managed_state,'persist',side_effect=crash):
            with self.assertRaises(InterruptedError):self.invoke('release',self.manifest)
        self.assertIsNone(role_deploy.pending_rollout(self.root))
        self.assertTrue(role_deploy.in_maintenance(self.root))
        with self.assertRaisesRegex(ValueError,'Finish the managed role operation'):
            role_deploy.require_rollout_owner(self.root)
        result=self.invoke('release',self.manifest)
        self.assertIsNone(result['fence']);self.assertFalse(role_deploy.in_maintenance(self.root))
        self.assertEqual(self.activated.call_count,1)

    def test_retarget_crash_between_marker_and_intent_is_recoverable(self):
        self.invoke('claim');persist=managed_state.persist
        def crash(path,value):
            if path == self.root/'runtime/managed-release.json' and value['active']==self.manifest:
                raise InterruptedError('retarget receipt write interrupted')
            return persist(path,value)
        with patch.object(managed_state,'persist',side_effect=crash):
            with self.assertRaises(InterruptedError):self.invoke('retarget',self.manifest)
        self.assertEqual(role_deploy.pending_rollout(self.root)['target'],role_release.json_digest(self.manifest))
        with self.assertRaisesRegex(ValueError,'differs from its maintenance fence'):
            role_deploy.require_rollout_owner(self.root,self.attempt,self.manifest)
        self.invoke('retarget',self.manifest)
        role_deploy.require_rollout_owner(self.root,self.attempt,self.manifest)

    def test_foreign_attempt_and_wrong_host_do_not_replace_the_held_operation(self):
        self.invoke('claim');original=role_deploy.managed_operation(self.root);self.calls.clear()
        with self.assertRaises(ValueError):self.invoke('claim',attempt='b'*64)
        with self.assertRaises(ValueError):self.invoke('release',self.manifest,attempt='b'*64)
        host=self.system/'etc/ssh/ssh_host_ed25519_key.pub';host.write_text(key(12))
        with self.assertRaisesRegex(ValueError,'another SSH host'):self.invoke('retarget',self.manifest)
        self.assertEqual(role_deploy.managed_operation(self.root),original)
        self.assertEqual(self.calls,[])

    def test_next_attempt_archives_only_a_completed_peer_receipt(self):
        self.invoke('claim');self.invoke('retarget',self.manifest);self.invoke('release',self.manifest)
        path=self.root/'runtime/managed-release.json';original=path.read_bytes()
        with self.assertRaisesRegex(ValueError,'already released'):self.invoke('claim')
        self.invoke('claim',attempt='b'*64)
        archived=self.root/'runtime/managed-releases'/(self.attempt+'.json')
        self.assertEqual(archived.read_bytes(),original)
        self.assertEqual(role_deploy.managed_operation(self.root)['attempt'],'b'*64)

    def test_symlinked_or_public_runtime_is_refused_before_fence_mutation(self):
        self.invoke('claim');runtime=self.root/'runtime';original=role_deploy.pending_rollout(self.root)
        runtime.chmod(0o755)
        with self.assertRaisesRegex(ValueError,'owner-only'):self.invoke('retarget',self.manifest)
        runtime.chmod(0o700)
        moved=self.root/'runtime-moved';runtime.rename(moved);runtime.symlink_to(moved)
        with self.assertRaisesRegex(ValueError,'private role runtime'):self.invoke('retarget',self.manifest)
        runtime.unlink();moved.rename(runtime)
        self.assertEqual(role_deploy.pending_rollout(self.root),original)

    def test_monitor_that_has_not_quiesced_keeps_fence_and_never_stops_apps(self):
        with patch.object(managed_fence.time,'monotonic',side_effect=[0,100]):
            with self.assertRaisesRegex(TimeoutError,'did not quiesce'):
                self.invoke('claim',run=lambda *args:'123')
        self.assertTrue(role_deploy.in_maintenance(self.root))
        self.assertEqual(role_deploy.managed_operation(self.root)['phase'],'held')
        self.assertFalse(any('up' in args or 'stop' in args for args in self.calls))


class ManagedEdgeFenceTests(ManagedFenceTests):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        self.base=Path(temporary.name).resolve();self.root=self.base/'edge';self.system=self.base/'system'
        self.public=topology.load(ROOT/'infra/three-vps.example.json');self.inventory=fixture()
        self.manifest=role_release.make(self.public,self.inventory,'edge','a'*40,
            'ghcr.io/fixture/web@sha256:'+'1'*64,'b')
        role_prepare.prepare(self.root,self.public,self.inventory,self.manifest)
        self.record=edge_deploy.record_for(self.public,self.inventory,self.manifest)
        self.state={'schema':1,'current':self.record,'previous':None,'pending':None}
        managed_state.persist(self.root/'state.json',self.state)
        host=self.system/'etc/ssh/ssh_host_ed25519_key.pub';host.parent.mkdir(parents=True)
        host.write_text(self.inventory['edges'][0]['ssh_host_key'])
        role_bootstrap.install(self.root,'edge','b',system_root=self.system,run=lambda *args:'')
        self.calls=[];self.stack=ExitStack();self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(edge_deploy,'network_ready',return_value=nullcontext()))
        self.stack.enter_context(patch.object(edge_deploy,'healthy'))
        self.target=deepcopy(self.manifest);self.target['commit']='b'*40
        self.attempt='a'*64;self.activated=Mock()

    def execute(self,args,**kwargs):
        self.calls.append(args)
        count=len(set(self.manifest['images'])-{'configure'})
        if 'ps' in args:return ('\n'.join(format(n+1,'064x') for n in range(count))+'\n').encode()
        if args[:2]==['docker','inspect']:
            return ('\n'.join(format(n+1,'064x')+' true 2026-10-29T00:00:00Z 0' for n in range(count))+'\n').encode()
        raise AssertionError('Unexpected command: '+repr(args))
