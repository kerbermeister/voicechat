from pathlib import Path
from unittest.mock import patch
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'infra'))
import managed_apply
import managed_state
import role_release
import test_core_deploy
import test_edge_deploy
from test_full_rollout_fence import fence


class ManagedApplyTests(unittest.TestCase):
    def prepare(self,role):
        self.fixture=(test_core_deploy.CoreDeployTests() if role=='core' else test_edge_deploy.EdgeDeployTests())
        self.fixture.setUp();self.addCleanup(self.fixture.doCleanups)
        self.fixture.deploy(self.fixture.old);self.root=self.fixture.root
        self.marker=fence(self.root,self.fixture.new)
        self.intent={'phase':'held','active':self.fixture.new}
        self.events=[];self.proof={'facts':{'manifest':self.fixture.new},'fence':{'attempt':self.marker['attempt']}}
        self.enterContext(patch('managed_fence._parameters',return_value=self.root))
        self.enterContext(patch('managed_fence._owned',side_effect=lambda *a:self.intent))
        self.enterContext(patch('managed_fence._quiesce',side_effect=lambda *a,**kw:self.events.append('quiesce')))
        self.enterContext(patch('role_bootstrap.install',side_effect=lambda *a,**kw:self.events.append('install')))
        self.observe=self.enterContext(patch('managed_fence.observe',return_value=self.proof))

    def apply(self,**kw):
        return managed_apply.apply(self.root,self.fixture.public,self.fixture.inventory,
            self.fixture.old,self.fixture.new,self.marker['attempt'],**kw)

    def test_core_apply_installs_owned_operator_before_deploy_and_observes_actual_target(self):
        self.prepare('core')
        with patch('core_deploy.deploy',side_effect=lambda *a,**kw:self.events.append('deploy')) as deploy:
            self.assertEqual(self.apply(),self.proof)
        self.assertEqual(self.events,['quiesce','install','deploy'])
        self.assertEqual(deploy.call_args.kwargs['rollout_attempt'],self.marker['attempt'])
        self.assertEqual(self.observe.call_args.args[5],self.fixture.new)

    def test_lost_commit_reply_does_not_replay_core_deployment(self):
        self.prepare('core');state=self.fixture.state()
        target=managed_apply.core_deploy.record_for(self.root,self.fixture.inventory,self.fixture.new)
        managed_state.persist(self.root/'state.json',{**state,'current':target,'previous':state['current']})
        with patch('core_deploy.deploy',side_effect=AssertionError('No configure replay')):
            self.assertEqual(self.apply(),self.proof)
        self.assertEqual(self.events,['quiesce','install'])

    def test_web_apply_has_explicit_scope_core_contract_and_nonce(self):
        self.prepare('edge')
        with patch('edge_deploy.deploy') as deploy:self.apply(scope='web',core_manifest=self.fixture.core)
        self.assertEqual(deploy.call_args.kwargs['scope'],'web')
        self.assertEqual(deploy.call_args.args[4],self.fixture.core)
        self.assertEqual(self.events,['quiesce','install'])

    def test_rollback_intent_or_foreign_pending_cannot_apply(self):
        self.prepare('core');self.intent['active']=self.fixture.old
        with self.assertRaisesRegex(ValueError,'active target fence'):self.apply()
        self.assertEqual(self.events,[]);self.observe.assert_not_called()
        self.intent['active']=self.fixture.new
        state=self.fixture.state();managed_state.persist(self.root/'state.json',
            {**state,'pending':{'target':state['current'],'phase':'managed-rollback'}})
        with self.assertRaisesRegex(ValueError,'Another role deployment'):self.apply()
        self.assertEqual(self.events,[])

    def test_missing_core_or_wrong_edge_scope_rejected_before_operator_change(self):
        self.prepare('edge')
        for kwargs in ({},{'scope':'web'},{'scope':'full','core_manifest':self.fixture.core}):
            with self.assertRaises(ValueError):self.apply(**kwargs)
        self.assertEqual(self.events,[])

    def test_deploy_failure_does_not_manufacture_success_proof(self):
        self.prepare('core')
        with patch('core_deploy.deploy',side_effect=RuntimeError('Apply failed')):
            with self.assertRaisesRegex(RuntimeError,'Apply failed'):self.apply()
        self.observe.assert_not_called()
