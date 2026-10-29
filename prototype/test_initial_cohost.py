from copy import deepcopy
import hashlib
import json
import os
from types import SimpleNamespace
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import initial_cohost
import legacy_core
import managed_state
import network_runtime
import role_release
import role_bootstrap
import topology
from test_node_inventory import fixture
import test_legacy_core


class InitialCohostPlanningTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.public = topology.load(ROOT / 'infra/single-vps.example.json')
        self.inventory = fixture()
        self.inventory['edges'] = [{'id':'a','host':'core','legacy_turn':True,'shared_tls':{
            'network':'voicechat-shared-ingress','subnet':'172.29.0.0/29',
            'legacy_ip':'172.29.0.2','ingress_ip':'172.29.0.3'}}]
        self.candidate = {'schema':1,'commit':'a'*40,'origin':self.public['canonical_origin'],
            'control':'ghcr.io/fixture/control@sha256:'+'1'*64,'web':'ghcr.io/fixture/web@sha256:'+'2'*64}

    def target(self):
        return initial_cohost.target_for(self.base/'managed',self.base/'legacy',self.base/'shared',
            self.public,self.inventory,self.candidate,'public-fixture-key',subnet='10.241.0.0/28',backend_sha256='b'*64)

    def test_target_binds_source_roles_legacy_identity_and_compatibility_port(self):
        result = self.target()
        self.assertEqual(result, self.target())
        self.assertEqual(result['core']['role'], 'core')
        self.assertEqual(result['edge']['edge_id'], 'a')
        self.assertEqual(result['backend_sha256'], 'b'*64)
        self.assertIn('infra/initial_cohost.py', result['source_files'])
        self.assertEqual(result['source_files']['infra/initial_cohost.py'],
                         hashlib.sha256((ROOT/'infra/initial_cohost.py').read_bytes()).hexdigest())
        before = role_release.json_digest(result)
        self.candidate['control'] = self.candidate['control'].replace('1'*64,'3'*64)
        self.assertNotEqual(role_release.json_digest(self.target()),before)

    def test_initial_migration_rejects_missing_legacy_turn_or_separate_edge(self):
        self.inventory['edges'][0]['legacy_turn'] = False
        with self.assertRaisesRegex(ValueError,'legacy TURN'):self.target()
        self.inventory['edges'][0]['legacy_turn'] = True
        self.public['edges'].append({'id':'b','origin':'https://b.example.com','turn_host':'turn-b.example.com'})
        with self.assertRaises(ValueError):self.target()

    def test_public_artifacts_are_copied_without_overwriting_unknown_files_or_symlinks(self):
        source, target = self.base/'public', self.base/'target'
        source.mkdir(mode=0o700); target.mkdir(mode=0o755)
        (source/'23').mkdir(mode=0o755)
        (source/'23/VoiceChat.zip').write_bytes(b'public signed archive fixture')
        (source/'appcast.xml').write_bytes(b'public feed fixture')
        (source/'.publish.lock').touch(mode=0o600)
        initial_cohost.copy_public(source,target)
        initial_cohost.copy_public(source,target)
        self.assertEqual((target/'23/VoiceChat.zip').read_bytes(),(source/'23/VoiceChat.zip').read_bytes())
        self.assertFalse((target/'.publish.lock').exists())
        (target/'appcast.xml').write_bytes(b'foreign')
        with self.assertRaisesRegex(ValueError,'differs'):initial_cohost.copy_public(source,target)
        self.assertEqual((target/'appcast.xml').read_bytes(),b'foreign')
        (target/'appcast.xml').write_bytes((source/'appcast.xml').read_bytes())
        (source/'unexpected').symlink_to(self.base/'private')
        with self.assertRaises(ValueError):initial_cohost.copy_public(source,target)

    def test_invalid_catalog_is_rejected_before_any_migration_directory_is_created(self):
        root = self.base / 'new-managed'
        with self.assertRaises(ValueError):
            initial_cohost.migrate(root,self.base/'legacy',self.base/'shared',self.public,self.inventory,
                self.candidate,b'not a signed catalog','invalid',backend_sha256='b'*64)
        self.assertFalse(root.exists())

    def test_wrong_host_or_remote_docker_is_rejected_before_migration_writes(self):
        system = self.base/'system'; host = system/'etc/ssh/ssh_host_ed25519_key.pub'
        host.parent.mkdir(parents=True); host.write_text(self.inventory['core']['ssh_host_key'])
        root = self.base/'new-managed'; calls=[]
        def execute(args, **kwargs):
            calls.append(args); return b'tcp://remote.invalid:2375'
        def migrate():
            return initial_cohost.migrate(root,self.base/'legacy',self.base/'shared',self.public,
                self.inventory,self.candidate,b'fixture-envelope','fixture-public-key',
                backend_sha256='b'*64,system_root=system,execute=execute)
        with patch.object(initial_cohost.route_catalog,'verify',return_value=SimpleNamespace(topology=self.public)):
            with patch.dict(os.environ,{'DOCKER_HOST':'tcp://remote.invalid:2375'}):
                with self.assertRaisesRegex(ValueError,'local rootful Docker'):migrate()
                self.assertFalse(root.exists());self.assertFalse(calls)
            with patch.dict(os.environ,{'DOCKER_HOST':''}):
                with self.assertRaisesRegex(ValueError,'local rootful Docker'):migrate()
                self.assertFalse(root.exists());self.assertEqual(len(calls),1)
                host.write_text(fixture()['edges'][0]['ssh_host_key'])
                with self.assertRaisesRegex(ValueError,'SSH host'):migrate()
                self.assertFalse(root.exists());self.assertEqual(len(calls),1)

    def test_policy_uses_data_owner_and_private_stdin_without_recreating_networks(self):
        snapshot = self.base/'prior.json'; calls=[]
        value = {'screen_share':{'enabled':False},'synthetic':'never-in-command-arguments'}
        def execute(args, **kwargs):
            calls.append((args,kwargs))
            return json.dumps(value).encode()
        baseline = {'images':{'configure':'python@sha256:'+'1'*64}}
        initial_cohost.policy(baseline,snapshot,restore=False,execute=execute)
        initial_cohost.policy(baseline,snapshot,restore=True,execute=execute)
        self.assertEqual(managed_state.read(snapshot),value)
        self.assertEqual(len(calls),2)
        self.assertEqual(json.loads(calls[1][1]['input']),value)
        for args,_ in calls:
            self.assertIn('10001:10001',args)
            self.assertEqual(args[args.index('--network')+1],'none')
            self.assertNotIn('never-in-command-arguments',json.dumps(args))
        self.assertIn('--interactive',calls[1][0])
        managed_state.persist(snapshot,[])
        with self.assertRaisesRegex(ValueError,'Invalid saved'):initial_cohost.policy(baseline,snapshot,restore=True,execute=execute)

    def test_initial_network_uses_generation_bound_registry_and_retains_same_private_key(self):
        root = self.base/'local-host'; root.mkdir(mode=0o700)
        value = initial_cohost.initial_network(root,self.inventory,'10.241.0.0/28')
        self.assertEqual(initial_cohost.initial_network(root,self.inventory,'10.241.0.0/28'),value)
        self.assertEqual(set(value['public_keys']['nodes']),{'core'})
        self.assertEqual(value['public_keys']['nodes']['core']['generation'],self.inventory['core']['generation'])
        self.assertEqual((root/'network.key').stat().st_mode & 0o077,0)
        foreign = fixture()
        with self.assertRaisesRegex(ValueError,'only this data host'):
            initial_cohost.initial_network(root,foreign,'10.241.0.0/28')
        self.assertEqual(initial_cohost.initial_network(root,self.inventory,'10.241.0.0/28'),value)

    def test_existing_network_requires_completed_live_intent_before_initial_adoption(self):
        from test_tunnel_runtime import state
        value = {**state(), 'edge_subnet':'10.241.0.0/28'}
        directory = self.base/'network'; directory.mkdir(mode=0o700)
        managed_state.persist(directory/'desired.json', value)
        inventory = value['inventory']; subnet = value['edge_subnet']
        with patch.object(initial_cohost.role_deploy, 'network_ready') as ready:
            ready.side_effect = ValueError('interrupted network operation')
            with self.assertRaisesRegex(ValueError,'interrupted'):
                initial_cohost.existing_network(directory,inventory,subnet,None,execute=lambda *_:b'')
            ready.assert_called_once()
        with patch.object(initial_cohost.role_deploy, 'network_ready') as ready:
            self.assertEqual(initial_cohost.existing_network(directory,inventory,subnet,None,
                execute=lambda *_:b''),value)
            ready.assert_called_once()
        previous = {'network_preexisting':False,'network_fingerprint':network_runtime.fingerprint(value)}
        with patch.object(initial_cohost.role_deploy, 'network_ready') as ready:
            self.assertEqual(initial_cohost.existing_network(directory,inventory,subnet,previous,
                execute=lambda *_:b''),value)
            ready.assert_not_called()
            previous['network_fingerprint']='0'*64
            with self.assertRaisesRegex(ValueError,'differs'):
                initial_cohost.existing_network(directory,inventory,subnet,previous,execute=lambda *_:b'')

    def test_scheduler_preflight_refuses_foreign_units_before_any_migration(self):
        system=self.base/'system';units=system/'etc/systemd/system';units.mkdir(parents=True)
        calls=[]
        def run(*args):calls.append(args);return 'not-found\n'
        initial_cohost.check_scheduler_slots(system,run=run)
        self.assertEqual(len(calls),4)
        (units/initial_cohost.cohost_tls_bootstrap.SERVICE).write_text('foreign unit')
        calls.clear()
        with self.assertRaisesRegex(ValueError,'Existing scheduler'):
            initial_cohost.check_scheduler_slots(system,run=run)
        self.assertFalse(calls)
        self.assertEqual((units/initial_cohost.cohost_tls_bootstrap.SERVICE).read_text(),'foreign unit')

    def test_boot_preflight_rejects_unclaimed_slots_without_installing_anything(self):
        root=self.base/'role';root.mkdir(mode=0o700)
        system=self.base/'system';units=system/'etc/systemd/system';units.mkdir(parents=True)
        initial_cohost.check_role_boot(root,'core',None,system_root=system)
        self.assertFalse((root/'runtime').exists())
        name,_,_,unit,target=role_bootstrap.plan(root,'core',None)
        (units/name).write_bytes(unit)
        with self.assertRaisesRegex(ValueError,'Unclaimed'):
            initial_cohost.check_role_boot(root,'core',None,system_root=system)
        self.assertEqual((units/name).read_bytes(),unit)
        boot=root/'runtime/boot';boot.mkdir(parents=True,mode=0o700)
        managed_state.persist(boot/'pending.json',{'target':target,'previous':None})
        initial_cohost.check_role_boot(root,'core',None,system_root=system)
        self.assertFalse((boot/'current.json').exists())
        (units/(name+'.d')).mkdir()
        with self.assertRaisesRegex(ValueError,'drop-in'):
            initial_cohost.check_role_boot(root,'core',None,system_root=system)

    def test_rollback_before_boot_install_or_after_partial_owned_install(self):
        root=self.base/'role';root.mkdir(mode=0o700)
        system=self.base/'system';units=system/'etc/systemd/system';units.mkdir(parents=True)
        calls=[]
        def run(*args):calls.append(args)
        initial_cohost.disable_role(root,'core',None,system_root=system,run=run)
        self.assertEqual(calls,[])
        name,_,_,unit,target=role_bootstrap.plan(root,'core',None)
        boot=root/'runtime/boot';boot.mkdir(parents=True,mode=0o700)
        managed_state.persist(boot/'pending.json',{'target':target,'previous':None})
        (units/name).write_bytes(unit)
        initial_cohost.disable_role(root,'core',None,system_root=system,run=run)
        self.assertEqual(calls,[('systemctl','disable','--now',name)])
        calls.clear();(units/name).write_bytes(unit+b'# foreign change')
        with self.assertRaisesRegex(ValueError,'Modified pending'):
            initial_cohost.disable_role(root,'core',None,system_root=system,run=run)
        self.assertFalse(calls)
        (boot/'pending.json').unlink()
        with self.assertRaisesRegex(ValueError,'Unclaimed'):
            initial_cohost.disable_role(root,'core',None,system_root=system,run=run)
        self.assertFalse(calls)

    def test_namespace_cleanup_requires_exact_compose_source_and_preserves_every_volume(self):
        case = test_legacy_core.LegacyCorePreflightTests();case.setUp();self.addCleanup(case.doCleanups)
        expected = (case.release/'infra/compose.yaml',)
        for value in case.containers.values():
            value['labels']['com.docker.compose.project.config_files'] = ','.join(map(str,expected))
        mutations=[]
        def execute(args,**kwargs):
            if args[:2] in (['docker','stop'],['docker','rm']):
                mutations.append(args);return b''
            return case.execute(args,**kwargs)
        models=[(expected,case.model)]
        self.assertEqual(len(initial_cohost.namespace('voicechat',models,execute=execute)),6)
        # Failed Compose startup may leave fully owned containers never started.
        case.containers['control']['state']['Status']='created'
        case.containers['control']['state']['Running']=False
        with self.assertRaisesRegex(ValueError,'lifecycle'):
            legacy_core._container(case.model['services']['control'],case.containers['control'],
                                   case.model,running=False)
        initial_cohost.remove_namespace('voicechat',models,execute=execute)
        self.assertEqual([args[1] for args in mutations],['stop','rm'])
        self.assertFalse(any('-v' in args or '--volumes' in args for args in mutations))
        case.containers['control']['labels']['com.docker.compose.project.config_files']='/foreign/compose.json'
        mutations.clear()
        with self.assertRaisesRegex(ValueError,'Unknown or duplicate'):
            initial_cohost.remove_namespace('voicechat',models,execute=execute)
        self.assertEqual(mutations,[])


if __name__ == '__main__':unittest.main()
