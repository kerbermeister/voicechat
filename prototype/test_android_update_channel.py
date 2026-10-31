from copy import deepcopy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'infra'), str(ROOT/'prototype')]
import android_update_channel as channel
import android_update_delivery as delivery
import managed_state
import role_release
import topology
from test_node_inventory import fixture


class AndroidUpdateChannelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()/'managed'; self.root.mkdir(mode=0o700)
        public = topology.load(ROOT/'infra/single-vps.example.json')
        inventory = fixture(); inventory['edges'] = [{'id':'a', 'host':'core'}]
        self.manifest = role_release.make(public, inventory, 'edge', 'a'*40,
            'ghcr.io/example/web@sha256:'+'b'*64, 'a')
        self.baseline = {'public':public, 'inventory':inventory, 'edges':{'a':self.manifest}}
        with patch.object(channel.managed_journal, 'current', return_value=(None,self.baseline,None)):
            self.plan = channel.plan(self.root, public['canonical_origin'])
        self.target = self.plan['edges'][0]
        self.edge = Path(self.target['root']); self.edge.mkdir(parents=True, mode=0o700)
        managed_state.persist(self.edge/'role.json', self.target['owner'])
        managed_state.persist(self.edge/'state.json', {'schema':1,'current':{
            'manifest':self.manifest, 'identity':public, 'address':'192.0.2.10'},'previous':None,'pending':None})
        (self.edge/'runtime/android-updates').mkdir(parents=True, mode=0o755)
        self.container = {'State':{'Running':True},'Mounts':[{'Type':'bind',
            'Source':str(self.edge/'runtime/android-updates'),'Destination':'/updates/android','RW':False}]}

    def execute(self, args):
        return b'container-id\n' if args[1] == 'ps' else json.dumps([self.container]).encode()

    def test_cohost_root_is_edge_not_core_or_legacy_and_readonly_mount_is_required(self):
        self.assertEqual(self.target['node'], 'core')
        expected = self.edge/'runtime/android-updates'
        self.assertEqual(channel.channel(self.target, execute=self.execute), expected)
        self.container['Mounts'][0]['RW'] = True
        with self.assertRaisesRegex(ValueError,'read-only'):
            channel.channel(self.target, execute=self.execute)
        self.container['Mounts'][0].update(RW=False,Source=str(self.root/'runtime/android-updates'))
        with self.assertRaisesRegex(ValueError,'read-only'):
            channel.channel(self.target, execute=self.execute)

    def test_immutable_release_mount_resolves_to_same_runtime(self):
        release = self.edge/'releases'/'release'/'infra'; release.mkdir(parents=True)
        (release/'runtime').symlink_to(self.edge/'runtime', target_is_directory=True)
        self.container['Mounts'][0]['Source'] = str(release/'runtime/android-updates')
        self.assertEqual(channel.channel(self.target,execute=self.execute), self.edge/'runtime/android-updates')

    def test_changed_role_and_runtime_symlink_are_rejected(self):
        changed = deepcopy(self.target); changed['manifest']='f'*64
        with self.assertRaisesRegex(ValueError,'changed'):
            channel.channel(changed,execute=self.execute)
        path=self.edge/'runtime/android-updates'; path.rmdir()
        other=self.root/'other';other.mkdir();path.symlink_to(other,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'directory'):
            channel.channel(self.target,execute=self.execute)

    def test_foreign_origin_and_pending_rollout_are_rejected(self):
        with patch.object(channel.managed_journal,'current',return_value=(None,self.baseline,None)):
            with self.assertRaisesRegex(ValueError,'origin'):
                channel.plan(self.root,'https://foreign.example')
            managed_state.persist(self.root/'rollout.json', {'phase':'applying'})
            with self.assertRaisesRegex(ValueError,'Finish'):
                channel.plan(self.root,self.baseline['public']['canonical_origin'])

    def test_completed_entry_journal_is_allowed_but_in_progress_is_not(self):
        directory=self.root/'entry-lifecycle';directory.mkdir()
        managed_state.persist(directory/'current.json', {})
        with patch.object(channel.managed_journal,'current',return_value=(None,self.baseline,None)), \
             patch.object(channel.entry_journal,'load',return_value={'position':1,'steps':['done']}):
            channel.plan(self.root,self.baseline['public']['canonical_origin'])
        with patch.object(channel.managed_journal,'current',return_value=(None,self.baseline,None)), \
             patch.object(channel.entry_journal,'load',return_value={'position':0,'steps':['pending']}):
            with self.assertRaisesRegex(ValueError,'entry lifecycle'):
                channel.plan(self.root,self.baseline['public']['canonical_origin'])

    def test_dedicated_edges_use_their_own_pinned_nodes_and_runtime(self):
        public = topology.load(ROOT/'infra/three-vps.example.json'); inventory = fixture()
        baseline={'public':public,'inventory':inventory,'edges':{edge['id']:role_release.make(
            public,inventory,'edge','a'*40,'ghcr.io/example/web@sha256:'+'b'*64,edge['id']) for edge in public['edges']}}
        with patch.object(channel.managed_journal,'current',return_value=(None,baseline,None)):
            targets=channel.plan(self.root,public['canonical_origin'])['edges']
        self.assertEqual([v['node'] for v in targets], ['edge-b','edge-c'])
        self.assertEqual([v['root'] for v in targets], [str(self.root/'edges/b'),str(self.root/'edges/c')])

    def test_remote_promotion_still_requires_exact_physical_acceptance(self):
        target=Path(self.temp.name)/'target.json';target.write_text(json.dumps(self.target))
        with patch.object(sys,'argv',['channel','publish','--target',str(target),'--candidate',self.temp.name]), \
             patch.object(channel,'channel',return_value=self.edge/'runtime/android-updates'), \
             patch.object(channel.android_release,'load_manifest',return_value={'versionCode':31,'sha256':'a'*64}), \
             patch.dict(os.environ,{'ANDROID_ACCEPTED_BUILD':'31','ANDROID_ACCEPTED_SHA256':'b'*64}), \
             patch.object(channel.android_release,'publish') as publish:
            with self.assertRaisesRegex(ValueError,'Physical acceptance'):
                channel.main()
            publish.assert_not_called()

class AndroidDeliveryTests(unittest.TestCase):
    def test_cli_checks_config_without_apk_or_acceptance(self):
        import base64
        import publish_android_ssh
        from client_config import build_config
        public=topology.load(ROOT/'infra/single-vps.example.json')
        with tempfile.TemporaryDirectory() as temporary:
            config=Path(temporary)/'client.json'
            value=build_config(public['canonical_origin'],json.dumps(public),base64.b64encode(bytes(range(32))).decode())
            config.write_text(json.dumps(value))
            with patch.object(sys,'argv',['publisher','--check','--config',str(config)]), \
                 patch.dict(os.environ,{'PUBLIC_URL':public['canonical_origin']}), \
                 patch.object(delivery,'deliver',return_value=[]) as deliver, \
                 patch.object(publish_android_ssh,'load_manifest') as manifest:
                publish_android_ssh.main()
            deliver.assert_called_once_with(None,check=True,config=value)
            manifest.assert_not_called()

    def test_check_stages_no_apk_and_never_promotes(self):
        from contextlib import contextmanager
        inventory=fixture(); public=topology.load(ROOT/'infra/three-vps.example.json')
        targets=[{'id':v['id'],'node':'core','origin':v['origin']} for v in public['edges']]
        staged_candidates=[];actions=[]
        @contextmanager
        def stage(ssh,candidate=None,target=None):
            staged_candidates.append(candidate);yield '/tmp/test'
        def invoke(ssh,directory,action,*args):
            actions.append(action)
            return {'inventory':inventory,'public':public,'edges':targets} if action=='plan' else {'ok':True}
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
        candidate=Path(temp.name);(candidate/'client-config.json').write_text(json.dumps({
            'ROUTE_CATALOG_KEY':'unused-in-test','ROUTE_CONFIG':json.dumps(public)}))
        from types import SimpleNamespace
        with patch.object(delivery,'connection',return_value=(['ssh'],'host','/managed')), \
             patch.object(delivery,'staged',side_effect=stage), \
             patch.object(delivery,'invoke',side_effect=invoke), \
             patch.dict(os.environ,{'PUBLIC_URL':public['canonical_origin']}), \
             patch('urllib.request.build_opener') as opener, \
             patch('route_catalog.verify',return_value=SimpleNamespace(topology=public)):
            delivery.deliver(candidate,check=True)
        self.assertEqual(actions,['plan','check','check'])
        self.assertTrue(all(v is None for v in staged_candidates))


if __name__ == '__main__': unittest.main()
