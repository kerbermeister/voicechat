from copy import deepcopy
from contextlib import nullcontext, ExitStack
import json
import tempfile
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'infra'))
import managed_release
import core_deploy
import managed_state
import role_bootstrap
import role_prepare
import role_release
import topology
from test_node_inventory import fixture, key


def baseline_32(original):
    baseline = deepcopy(original)
    public, inventory = baseline['public'], baseline['inventory']
    public['edges'] = [{'id': 'e'+str(n), 'origin': 'https://edge'+str(n)+'.example.com',
                        'turn_host': 'turn'+str(n)+'.example.com'} for n in range(32)]
    inventory['edges'] = [{'id': 'e'+str(n), 'generation': 1, 'public_ip': '192.0.2.'+str(n+20),
                           'tunnel_ip': '10.88.0.'+str(n+2), 'ssh_host_key': key(n+2)} for n in range(32)]
    baseline['core'] = role_release.make(public,inventory,'core','a'*40,baseline['core']['images']['control'])
    image = lambda digit: 'ghcr.io/example/voicechat@sha256:'+digit*64
    baseline['edges'] = {item['id']: role_release.make(public,inventory,'edge',
        ('a' if n%2 else 'b')*40,image('2' if n%2 else '3'),item['id']) for n,item in enumerate(public['edges'])}
    return baseline


class ManagedReleaseTests(unittest.TestCase):
    def setUp(self):
        public=topology.load(ROOT/'infra/three-vps.example.json')
        inventory=fixture()
        self.image=lambda value:'ghcr.io/example/voicechat@sha256:'+value*64
        self.baseline={'schema':1,'backend':'f'*64,'public':public,'inventory':inventory,
            'subnet':'10.241.0.0/28',
            'core':role_release.make(public,inventory,'core','a'*40,self.image('1')),
            'edges':{item['id']:role_release.make(public,inventory,'edge','a'*40,self.image('2'),item['id']) for item in public['edges']}}
        self.candidate={'schema':1,'commit':'b'*40,'origin':public['canonical_origin'],
            'control':self.image('1'),'web':self.image('3')}

    def plan(self,scope='full',**kwargs):
        return managed_release.plan(self.baseline,self.candidate,self.baseline['backend'],scope=scope,**kwargs)

    def test_web_selection_preserves_core_and_unselected_edge_exactly(self):
        before=deepcopy(self.baseline)
        value=self.plan('web',edges=['c'])
        self.assertEqual(value['core'],before['core'])
        self.assertEqual(value['edges']['b'],before['edges']['b'])
        self.assertEqual(value['steps'],[{'role':'edge','edge_id':'c'}])
        self.assertEqual(value['edges']['c']['images']['web'],self.image('3'))
        role_release.require_web_only(before['edges']['c'],value['edges']['c'])
        self.assertEqual(self.baseline,before)
        self.assertEqual(value,self.plan('web',edges=['c']))

    def test_persisted_sorted_json_baseline_does_not_look_like_a_core_change(self):
        restored=json.loads(json.dumps(self.baseline,sort_keys=True))
        for scope in ('web','edge','core','full'):
            value=managed_release.plan(restored,self.candidate,restored['backend'],scope=scope)
            self.assertEqual(value,self.plan(scope))
        for role,identifier in (('core',None),('edge','b')):
            image=self.image('1' if role=='core' else '2')
            original=role_release.make(self.baseline['public'],self.baseline['inventory'],role,'a'*40,image,identifier)
            reordered=role_release.make(restored['public'],restored['inventory'],role,'a'*40,image,identifier)
            self.assertEqual(original,reordered)

    def test_core_reuses_every_mixed_web_revision_without_client_build(self):
        public,inventory=self.baseline['public'],self.baseline['inventory']
        self.baseline['edges']['c']=role_release.make(public,inventory,'edge','c'*40,self.image('4'),'c')
        self.candidate['control']=self.image('5')
        value=self.plan('core')
        self.assertEqual(value['edges'],self.baseline['edges'])
        self.assertEqual(value['core']['images']['control'],self.image('5'))
        self.assertEqual(value['steps'],[{'role':'core','edge_id':None}])

    def test_core_protected_source_change_requires_a_recorded_non_core_guard(self):
        with self.assertRaisesRegex(ValueError, 'full'):
            managed_release.plan(self.baseline, self.candidate, 'e' * 64, scope='core')

    def test_full_records_guard_before_allowing_core_app_only_changes(self):
        guard = '7' * 64
        value = managed_release.plan(self.baseline, self.candidate, 'e' * 64,
                                     scope='full', core_guard=guard)
        baseline = managed_release.next_baseline(self.baseline, value)
        self.assertEqual(baseline['schema'], 2)
        self.assertEqual(baseline['core_guard'], guard)
        core = managed_release.plan(baseline, self.candidate, 'd' * 64,
                                    scope='core', core_guard=guard)
        self.assertEqual(core['edges'], baseline['edges'])
        self.assertEqual(managed_release.next_baseline(baseline, core)['core_guard'], guard)
        for missing_or_changed in (None, '8' * 64):
            with self.subTest(guard=missing_or_changed), self.assertRaisesRegex(ValueError, 'full'):
                managed_release.plan(baseline, self.candidate, 'd' * 64,
                                     scope='core', core_guard=missing_or_changed)
        with self.assertRaisesRegex(ValueError, 'full'):
            managed_release.plan(self.baseline, self.candidate, 'd' * 64,
                                 scope='core', core_guard=guard)
        with self.assertRaisesRegex(ValueError, 'retain'):
            managed_release.plan(baseline, self.candidate, 'd' * 64, scope='full')

    def test_partial_releases_preserve_guard_and_same_tree_cannot_change_it(self):
        self.baseline.update(schema=2, core_guard='7' * 64)
        for scope in ('web', 'edge', 'core'):
            value = self.plan(scope)
            self.assertEqual(managed_release.next_baseline(self.baseline, value)['core_guard'], '7' * 64)
            with self.assertRaisesRegex(ValueError, 'conflicts'):
                managed_release.plan(self.baseline, self.candidate, self.baseline['backend'],
                                     scope=scope, core_guard='8' * 64)
        for malformed in (True, '', 'x' * 64):
            with self.assertRaises(ValueError):
                managed_release.plan(self.baseline, self.candidate, 'd' * 64,
                                     scope='core', core_guard=malformed)

    def test_full_updates_core_then_all_edges_in_declared_order(self):
        self.candidate['control']=self.image('5')
        value=self.plan()
        self.assertEqual(value['steps'],[{'role':'core','edge_id':None},
            {'role':'edge','edge_id':'b'},{'role':'edge','edge_id':'c'}])
        self.assertTrue(all(item['commit']=='b'*40 for item in [value['core'],*value['edges'].values()]))
        for scope in ('core','full'):
            with self.assertRaisesRegex(ValueError,'complete edge baseline'):self.plan(scope,edges=['b'])

    def test_arbitrary_edge_ids_are_data_and_not_hardcoded_servers(self):
        public,inventory=self.baseline['public'],self.baseline['inventory']
        for number,identifier in enumerate(('d','e','eu-central'),4):
            public['edges'].append({'id':identifier,'origin':'https://'+identifier+'.example.com',
                'turn_host':'turn-'+identifier+'.example.com'})
            inventory['edges'].append({'id':identifier,'generation':1,'public_ip':'192.0.2.'+str(number+20),
                'tunnel_ip':'10.88.0.'+str(number),'ssh_host_key':key(number)})
        self.baseline['core']=role_release.make(public,inventory,'core','a'*40,self.image('1'))
        self.baseline['edges']={item['id']:role_release.make(public,inventory,'edge','a'*40,self.image('2'),item['id']) for item in public['edges']}
        value=self.plan('edge',edges=['eu-central','d'])
        self.assertEqual([item['edge_id'] for item in value['steps']],['eu-central','d'])
        self.assertEqual(value['edges']['e'],self.baseline['edges']['e'])

    def test_protected_sources_or_new_control_cannot_enter_partial_edge_release(self):
        for scope in ('web','edge'):
            with self.assertRaisesRegex(ValueError,'Protected backend'):
                managed_release.plan(self.baseline,self.candidate,'e'*64,scope=scope)
            changed={**self.candidate,'control':self.image('7')}
            with self.assertRaisesRegex(ValueError,'reuse the deployed control'):
                managed_release.plan(self.baseline,changed,self.baseline['backend'],scope=scope)

    def test_core_scope_refuses_edge_source_changes_and_edge_scope_refuses_core_changes(self):
        original=role_release.make
        def changed(*args,**kwargs):
            value=original(*args,**kwargs)
            name='infra/Caddyfile' if value['role']=='edge' else 'prototype/client-policy.json'
            value['files'][name]='0'*64
            return value
        with patch.object(role_release,'make',side_effect=changed):
            for scope in ('core','edge','web'):
                with self.assertRaisesRegex(ValueError,'configuration changed'):self.plan(scope)

    def test_invalid_baselines_and_selections_fail_before_execution(self):
        for selection in ([],['b','b'],['missing']):
            with self.assertRaisesRegex(ValueError,'distinct known'):self.plan('web',edges=selection)
        changed=deepcopy(self.baseline);del changed['edges']['c']
        with self.assertRaisesRegex(ValueError,'Complete per-edge'):
            managed_release.plan(changed,self.candidate,'f'*64)
        changed=deepcopy(self.baseline);changed['inventory']['core']['generation']+=1
        with self.assertRaisesRegex(ValueError,'host assignment changed'):
            managed_release.plan(changed,self.candidate,'f'*64)
        for candidate in ({**self.candidate,'schema':True},{**self.candidate,'web':'latest'},
                          {**self.candidate,'origin':'https://other.example.com'}):
            with self.assertRaises(ValueError):managed_release.plan(self.baseline,candidate,'f'*64)

    def test_initial_pointer_is_explicitly_typed_and_not_a_legacy_release(self):
        public=topology.load(ROOT/'infra/single-vps.example.json')
        inventory=fixture();inventory['edges']=[{'id':'a','host':'core'}]
        target={'backend_sha256':'f'*64,'public':public,'inventory':inventory,'subnet':'10.241.0.0/28',
            'core':role_release.make(public,inventory,'core','a'*40,self.image('1')),
            'edge':role_release.make(public,inventory,'edge','a'*40,self.image('2'),'a')}
        current={'schema':1,'kind':'roles','target':target,'core_root':'/srv/managed/core',
                 'edge_root':'/srv/managed/edges/a','legacy_root':'/srv/legacy','data_identity':{}}
        value=managed_release.from_initial(current)
        self.assertEqual(value['edges'],{'a':target['edge']})
        self.assertEqual(value['backend'],'f'*64)
        with self.assertRaises(ValueError):managed_release.from_initial({'schema':1,'manifest':{}})


class ManagedBaselineStorageTests(unittest.TestCase):
    def setUp(self):
        ManagedReleaseTests.setUp(self)
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()

    def test_read_of_missing_storage_does_not_initialize_it(self):
        with self.assertRaisesRegex(ValueError,'Existing immutable baseline storage'):
            managed_release.load_baseline(self.root,'f'*64)
        self.assertEqual(list(self.root.iterdir()),[])

    def test_32_edges_roundtrip_without_increasing_managed_document_limit(self):
        self.baseline = baseline_32(self.baseline)
        self.assertGreater(len(json.dumps(self.baseline).encode()),65536)
        checksum = managed_release.store_baseline(self.root,self.baseline)
        self.assertEqual(managed_release.load_baseline(self.root,checksum),self.baseline)
        files = set((self.root/'baselines').iterdir())
        self.assertTrue(all(path.stat().st_size <= 65536 for path in files))
        self.assertEqual(managed_release.store_baseline(self.root,self.baseline),checksum)
        self.assertEqual(set((self.root/'baselines').iterdir()),files)
        self.assertFalse((self.root/'current.json').exists())

    def test_tampered_or_symlinked_object_and_path_reference_are_refused(self):
        checksum = managed_release.store_baseline(self.root,self.baseline)
        path = self.root/'baselines'/(checksum+'.json')
        original = managed_state.read(path)
        managed_state.persist(path,{**original,'backend':'0'*64})
        with self.assertRaisesRegex(ValueError,'object changed'):
            managed_release.load_baseline(self.root,checksum)
        with self.assertRaisesRegex(ValueError,'object changed'):
            managed_release.store_baseline(self.root,self.baseline)
        path.unlink(); other = self.root/'other.json'; managed_state.persist(other,original);path.symlink_to(other)
        with self.assertRaises(OSError):managed_release.load_baseline(self.root,checksum)
        for invalid in ('../other', 'A'*64, None):
            with self.assertRaises(ValueError):managed_release.load_baseline(self.root,invalid)


class ManagedBaselineInspectionTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        self.base=Path(temporary.name).resolve();self.root=self.base/'core';self.system=self.base/'system'
        self.public=topology.load(ROOT/'infra/three-vps.example.json');self.inventory=fixture()
        self.manifest=role_release.make(self.public,self.inventory,'core','a'*40,
            'ghcr.io/fixture/control@sha256:'+'1'*64)
        role_prepare.prepare(self.root,self.public,self.inventory,self.manifest)
        env=self.root/'runtime/stand.env';env.write_text('synthetic-private-do-not-return');env.chmod(0o600)
        self.record=core_deploy.record_for(self.root,self.inventory,self.manifest)
        self.identity={'postgres_system_identifier':'123456789','signing_sha256':'f'*64}
        self.state={'schema':1,'current':self.record,'previous':None,'pending':None,'data_identity':self.identity}
        managed_state.persist(self.root/'state.json',self.state)
        host=self.system/'etc/ssh/ssh_host_ed25519_key.pub'
        host.parent.mkdir(parents=True);host.write_text(self.inventory['core']['ssh_host_key'])
        role_bootstrap.install(self.root,'core',system_root=self.system,run=lambda *args:b'')
        self.calls=[]
        self.stack=ExitStack();self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(managed_release.role_deploy,'network_ready',return_value=nullcontext()))
        self.stack.enter_context(patch.object(core_deploy,'healthy'))
        self.stack.enter_context(patch.object(core_deploy,'data_identity',return_value=self.identity))

    def execute(self,args,**kwargs):
        self.calls.append(args)
        if 'ps' in args:return ('\n'.join(value*64 for value in ('1','2','3'))+'\n').encode()
        if args[:2]==['docker','inspect']:
            return ('\n'.join(value*64+' true 2026-10-29T00:00:00Z 0' for value in ('1','2','3'))+'\n').encode()
        raise AssertionError('Unexpected command: '+repr(args))

    def inspect(self, **kwargs):
        return managed_release.inspect_role(self.root,self.public,self.inventory,self.manifest,
            system_root=self.system,execute=self.execute,run=lambda *args:b'',**kwargs)

    def test_actual_private_state_bundle_and_boot_receipt_produce_public_facts_only(self):
        value=self.inspect()
        self.assertEqual(value['manifest'],self.manifest)
        self.assertEqual(value['data_identity'],self.identity)
        self.assertEqual(len(value['processes']),3)
        self.assertNotIn('synthetic-private-do-not-return',json.dumps(value))
        self.assertEqual(managed_state.read(self.root/'state.json'),self.state)
        self.assertFalse(any('up' in args or 'stop' in args for args in self.calls))

    def test_only_exact_maintenance_owner_can_observe_previous_committed_role(self):
        target=deepcopy(self.manifest);target['commit']='b'*40
        fence={'schema':1,'operation':'full-rollout','root':str(self.root),'attempt':'a'*64,
               'target':role_release.json_digest(target),
               'owner':role_release.json_digest(managed_state.read(self.root/'role.json'))}
        managed_state.persist(self.root/'runtime/full-rollout.json',fence)
        with self.assertRaisesRegex(ValueError,'Finish the full rollout'):self.inspect()
        value=self.inspect(rollout_attempt='a'*64,rollout_manifest=target)
        self.assertEqual(value['manifest'],self.manifest)
        self.assertEqual(value['data_identity'],self.identity)
        for options in ({'rollout_attempt':'b'*64,'rollout_manifest':target},
                        {'rollout_attempt':'a'*64,'rollout_manifest':self.manifest}):
            with self.assertRaisesRegex(ValueError,'Finish the full rollout'):self.inspect(**options)
        self.assertEqual(managed_state.read(self.root/'state.json'),self.state)
        self.assertEqual(managed_state.read(self.root/'runtime/full-rollout.json'),fence)
        self.assertFalse(any('up' in args or 'stop' in args for args in self.calls))

    def test_maintenance_parameters_are_paired_and_cannot_change_role_identity(self):
        for options in ({'rollout_attempt':'a'*64},{'rollout_manifest':self.manifest}):
            with self.assertRaisesRegex(ValueError,'both attempt and target'):self.inspect(**options)
        target=deepcopy(self.manifest);target['identity']['canonical_origin']='https://other.example.com'
        with self.assertRaises(ValueError):self.inspect(rollout_attempt='a'*64,rollout_manifest=target)
        self.assertFalse(self.calls)

    def test_wrong_host_pending_release_and_runtime_tamper_are_refused(self):
        host=self.system/'etc/ssh/ssh_host_ed25519_key.pub';original=host.read_text();host.write_text(key(12))
        with self.assertRaisesRegex(ValueError,'another SSH host'):self.inspect()
        self.assertFalse(self.calls);host.write_text(original)
        managed_state.persist(self.root/'state.json',{**self.state,'pending':{'target':self.record,'phase':'prepared'}})
        with self.assertRaisesRegex(ValueError,'without a pending'):self.inspect()
        self.assertFalse(self.calls)
        managed_state.persist(self.root/'state.json',self.state)
        (self.root/'runtime/stand.env').write_text('changed private runtime')
        with self.assertRaisesRegex(ValueError,'runtime differs'):self.inspect()

    def test_changed_boot_unit_extra_import_and_data_identity_are_refused(self):
        unit=self.system/'etc/systemd/system/voicechat-core.service';original=unit.read_bytes();unit.write_bytes(original+b'# changed')
        with self.assertRaisesRegex(ValueError,'boot unit changed'):self.inspect()
        self.assertFalse(self.calls);unit.write_bytes(original)
        release=self.root/'releases'/role_release.json_digest(self.manifest)
        extra=release/'infra/subprocess.py';extra.write_text('unreviewed')
        with self.assertRaisesRegex(ValueError,'Unexpected'):self.inspect()
        self.assertFalse(self.calls);extra.unlink()
        with patch.object(core_deploy,'data_identity',return_value={**self.identity,'signing_sha256':'0'*64}):
            with self.assertRaisesRegex(ValueError,'data identity changed'):self.inspect()

    def test_incomplete_boot_install_or_foreign_dropin_is_not_a_valid_baseline(self):
        pending=self.root/'runtime/boot/pending.json';managed_state.persist(pending,{'schema':1})
        with self.assertRaisesRegex(ValueError,'boot installation'):self.inspect()
        pending.unlink()
        dropin=self.system/'etc/systemd/system/voicechat-core.service.d';dropin.symlink_to(self.base/'missing')
        with self.assertRaisesRegex(ValueError,'drop-in'):self.inspect()
        self.assertFalse(self.calls)
