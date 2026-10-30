from copy import deepcopy
import json
from pathlib import Path
from types import SimpleNamespace
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'infra'))
import managed_peer
import managed_state
import release_delivery
import role_release
import topology
import test_release_delivery
from test_node_inventory import fixture


class ManagedPeerTests(unittest.TestCase):
    def setUp(self):
        self.delivery=test_release_delivery.ImmutableSourceDeliveryTests();self.delivery.setUp()
        self.addCleanup(self.delivery.doCleanups)
        self.root=self.delivery.root
        public=topology.load(ROOT/'infra/three-vps.example.json');inventory=fixture()
        self.delivery.manifest['origin']=public['canonical_origin']
        self.source,self.sha=self.install()
        self.value={'schema':1,'operation':'claim','public':public,'inventory':inventory,'subnet':'10.241.0.0/28',
            'before':role_release.make(public,inventory,'core','b'*40,'ghcr.io/fixture/control@sha256:'+'3'*64),
            'target':role_release.make(public,inventory,'core',self.delivery.commit,self.delivery.manifest['control']),
            'attempt':'f'*64,'scope':None,'core':None,'manifest':None,
            'data_identity':{'postgres_system_identifier':'123456789','signing_sha256':'e'*64}}
        self.role_root=self.root/'core';self.role_root.mkdir(mode=0o700)
        (self.role_root/'runtime').mkdir(mode=0o700)
        self.enterContext(patch.object(managed_peer.platform,'system',return_value='Linux'))
        self.enterContext(patch.object(managed_peer,'os',SimpleNamespace(geteuid=lambda:0,environ={})))
        self.run=self.enterContext(patch('role_deploy.run',return_value=b'unix:///var/run/docker.sock\n'))
        self.enterContext(patch('managed_fence._parameters',return_value=self.role_root))
        self.claim=self.enterContext(patch('managed_fence.claim',return_value={'real_operation_mock':True}))

    def install(self):
        self.delivery.files['release.json']=json.dumps(self.delivery.manifest).encode()
        raw,sha=self.delivery.archive()
        return release_delivery.install(raw,self.root,sha,self.delivery.commit),sha

    def operate(self):
        return managed_peer.operate(managed_peer.request(json.dumps(self.value).encode()),
            self.root,self.sha,source=self.source)

    def test_request_bounds_unique_fields_and_core_contract(self):
        self.assertEqual(managed_peer.request(json.dumps(self.value).encode()),self.value)
        for changes in ({'private_key':'secret'},{'schema':True},{'scope':'web'},{'attempt':'bad'},
                        {'subnet':'10.88.0.0/28'},{'manifest':self.value['before']}):
            with self.subTest(changes=changes),self.assertRaises(ValueError):
                managed_peer.request(json.dumps({**self.value,**changes}).encode())
        with self.assertRaises(ValueError):managed_peer.request(b' '*65537)
        raw=json.dumps(self.value).encode().replace(b'"schema": 1',b'"schema": 1,"schema": 1',1)
        with self.assertRaises(ValueError):managed_peer.request(raw)

    def test_claim_is_bound_to_exact_delivery_and_role_path(self):
        self.assertEqual(self.operate(),{'real_operation_mock':True})
        self.assertEqual(self.claim.call_args.args[0],self.role_root)
        self.assertEqual(self.claim.call_args.args[-1],self.value['attempt'])
        receipt=managed_state.read(self.role_root/'runtime/managed-peer/current.json')
        self.assertEqual(receipt['source'],self.sha)
        self.operate();self.assertEqual(self.claim.call_count,2)

    def test_changed_source_cannot_resume_the_same_attempt(self):
        self.operate();self.delivery.files['infra/core_deploy.py']=b'# changed public source\n'
        self.source,self.sha=self.install()
        with self.assertRaisesRegex(ValueError,'same frozen peer source'):self.operate()
        self.assertEqual(self.claim.call_count,1)

    def test_next_released_attempt_recovers_lost_archive_write(self):
        self.operate();old_attempt=self.value['attempt']
        self.value['attempt']='d'*64;persist=managed_state.persist
        def crash(path,value):
            persist(path,value)
            if path.name==old_attempt+'.json':raise KeyboardInterrupt('Lost archive write reply')
        with patch('role_deploy.managed_operation',return_value={'phase':'released','attempt':old_attempt}), \
             patch.object(managed_state,'persist',side_effect=crash):
            with self.assertRaises(KeyboardInterrupt):self.operate()
        with patch('role_deploy.managed_operation',return_value={'phase':'released','attempt':old_attempt}):
            self.operate()
        self.assertEqual(self.claim.call_count,2)
        self.assertEqual(managed_state.read(self.role_root/'runtime/managed-peer/current.json')['attempt'],'d'*64)

    def test_held_receipt_foreign_docker_and_tampered_source_fail_closed(self):
        self.operate();self.value['attempt']='d'*64
        with patch('role_deploy.managed_operation',return_value={'phase':'held','attempt':'f'*64}):
            with self.assertRaisesRegex(ValueError,'same frozen peer source'):self.operate()
        self.run.return_value=b'tcp://remote:2375\n'
        with self.assertRaisesRegex(ValueError,'Local rootful Docker'):self.operate()
        self.run.return_value=b'unix:///var/run/docker.sock\n'
        (self.source/'infra/core_deploy.py').write_text('tampered')
        with self.assertRaisesRegex(ValueError,'source file changed'):self.operate()
        self.assertEqual(self.claim.call_count,1)

    def test_candidate_target_cannot_be_replaced_with_another_image(self):
        self.value['target']=deepcopy(self.value['target'])
        self.value['target']['images']['control']='ghcr.io/fixture/control@sha256:'+'4'*64
        with self.assertRaisesRegex(ValueError,'frozen source delivery'):self.operate()
        self.claim.assert_not_called()

    def test_repeated_operation_is_serialized(self):
        with managed_state.locked(self.role_root/'runtime/managed-peer'):
            with self.assertRaises(BlockingIOError):self.operate()
        self.claim.assert_not_called()

    def test_rollback_retargets_before_restoring_core_and_returns_observed_facts(self):
        self.value['operation']='rollback';events=[]
        with patch('managed_fence.retarget',side_effect=lambda *a,**kw:events.append('retarget')), \
             patch('role_bootstrap.install',side_effect=lambda *a,**kw:events.append('install')), \
             patch('managed_core_rollback.rollback',side_effect=lambda *a,**kw:events.append('restore')) as restore, \
             patch('managed_fence.observe',side_effect=lambda *a,**kw:events.append('observe') or {'observed':True}) as observe:
            self.assertEqual(self.operate(),{'observed':True})
        self.assertEqual(events,['retarget','install','restore','observe'])
        self.assertEqual(restore.call_args.args[-2],self.value['data_identity'])
        self.assertEqual(observe.call_args.args[-2],self.value['before'])

    def test_apply_and_release_use_real_operation_results_and_failures_propagate(self):
        self.value['operation']='apply'
        with patch('managed_apply.apply',return_value={'applied':True}) as apply:
            self.assertEqual(self.operate(),{'applied':True})
            self.assertEqual(apply.call_args.args[-1],self.value['attempt'])
        self.value.update(operation='release',manifest=self.value['target'])
        with patch('managed_fence.release',side_effect=RuntimeError('Release failed')):
            with self.assertRaisesRegex(RuntimeError,'Release failed'):self.operate()

    def test_preflight_reads_actual_baseline_without_source_intent_or_fence(self):
        self.value['operation']='preflight'
        with patch('managed_release.inspect_role',return_value={'manifest':self.value['before']}) as inspect, \
             patch('role_prepare.prepare') as prepare, \
             patch('core_deploy.record_for',return_value={'manifest':self.value['target']}), \
             patch('core_deploy.compose') as pull:
            self.assertEqual(self.operate(),{'facts':{'manifest':self.value['before']},'fence':None})
            self.assertEqual(inspect.call_args.args[-1],self.value['before'])
            prepare.assert_called_once();self.assertEqual(pull.call_args.args[-3:],('pull','--policy','missing'))
        self.assertFalse((self.role_root/'runtime/managed-peer').exists())
        self.claim.assert_not_called()

    def test_failed_preflight_image_download_creates_no_operation_binding(self):
        self.value['operation']='preflight'
        with patch('managed_release.inspect_role',return_value={'manifest':self.value['before']}), \
             patch('role_prepare.prepare'), \
             patch('core_deploy.record_for',return_value={'manifest':self.value['target']}), \
             patch('core_deploy.compose',side_effect=RuntimeError('Image unavailable')):
            with self.assertRaisesRegex(RuntimeError,'Image unavailable'):self.operate()
        self.assertFalse((self.role_root/'runtime/managed-peer').exists())
        self.claim.assert_not_called()
