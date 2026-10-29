from contextlib import nullcontext
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import core_deploy
import managed_state
import role_prepare
import role_release
from test_node_inventory import fixture
from topology import load


class CoreDeployTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / 'core'
        self.public = load(ROOT / 'infra/three-vps.example.json')
        self.inventory = fixture()
        self.old = self.release('a')
        self.new = self.release('b')
        (self.root / 'runtime/stand.env').write_text('synthetic-private-runtime\n')
        (self.root / 'runtime/stand.env').chmod(0o600)
        self.data_identity = {'postgres_system_identifier': '123456789', 'signing_sha256': 'f' * 64}
        self.running = False
        self.volumes = False
        self.networks = False
        self.calls = []
        self.backups = 0
        self.fail_backup = False
        self.fail_health = None
        self.fail_up = None
        self.interrupt_phase = None
        self.policy = {'version': 1, 'text_max_length': 8000}

    def release(self, revision):
        manifest = role_release.make(self.public, self.inventory, 'core', revision * 40,
            'ghcr.io/fixture/control@sha256:' + revision * 64)
        role_prepare.prepare(self.root, self.public, self.inventory, manifest)
        return manifest

    def execute(self, arguments, *, env=None):
        self.calls.append(arguments)
        if arguments[:3] == ['docker', 'network', 'ls']: return b'existing' if self.networks else b''
        if arguments[:3] == ['docker', 'volume', 'ls']: return b'existing' if self.volumes else b''
        if arguments[:2] == ['docker', 'pull']: return b''
        self.assertEqual(env['COMPOSE_PROJECT_NAME'], 'voicechat')
        manifest = role_release.load(Path(arguments[arguments.index('-f') + 1]).parent.parent / 'release.json')
        if 'config' in arguments:
            services = {name: {'image': image, 'restart': 'no'} for name, image in manifest['images'].items()}
            services['configure']['environment'] = {'PUBLIC_URL': self.public['canonical_origin'],
                'MATRIX_SERVER_NAME': self.public['matrix_server_name']}
            return json.dumps({'services': services, 'volumes': {name: {'name': 'voicechat_' + name}
                for name in ('postgres', 'synapse', 'control', 'media-config', 'turn-config')}}).encode()
        if 'ps' in arguments: return b'services' if self.running else b''
        if 'stop' in arguments: self.running = False
        if 'cat' in arguments: return json.dumps(self.policy).encode()
        if 'up' in arguments:
            if manifest['commit'] == self.fail_up: raise RuntimeError('Injected startup failure')
            phase = core_deploy.read_state(self.root)['pending']['phase']
            if phase == self.interrupt_phase:
                self.interrupt_phase = None
                raise KeyboardInterrupt('Injected termination')
            if arguments[-1] != 'configure': self.running = True
        return b''

    def backup(self, root, record):
        self.assertFalse(self.running, 'Writers must stop before backup')
        self.assertEqual(core_deploy.read_state(root)['pending']['phase'], 'stopping')
        self.backups += 1
        if self.fail_backup: raise RuntimeError('Injected backup failure')

    def healthy(self, root, record, **kwargs):
        self.assertTrue(self.running)
        if record['manifest']['commit'] == self.fail_health: raise RuntimeError('Injected readiness failure')

    def deploy(self, manifest):
        return core_deploy.deploy(self.root, self.public, self.inventory, manifest,
            execute=self.execute, check_network=lambda *a, **kw: nullcontext(),
            check_health=self.healthy, create_backup=self.backup, check_boot=lambda *a: None, identify_data=lambda *a, **k: self.data_identity.copy(), activate_monitor=lambda *a: None)

    def state(self): return core_deploy.read_state(self.root)

    def test_initial_then_upgrade_stops_writers_before_backup_and_preserves_previous(self):
        self.deploy(self.old)
        self.assertEqual(self.backups, 0)
        self.calls.clear()
        self.deploy(self.new)
        self.assertEqual(self.backups, 1)
        state = self.state()
        self.assertEqual(state['current']['manifest'], self.new)
        self.assertEqual(state['previous']['manifest'], self.old)
        self.assertIsNone(state['pending'])
        self.assertTrue(any('stop' in arguments for arguments in self.calls))
        self.assertTrue(all('web' not in arguments and 'turn' not in arguments for arguments in self.calls))
        self.calls.clear()
        self.deploy(self.new)
        self.assertEqual(self.backups, 1)
        self.assertFalse(any('up' in arguments for arguments in self.calls))

    def test_failure_rolls_back_code_and_policy_without_restoring_database(self):
        self.deploy(self.old)
        self.fail_health = self.new['commit']
        with self.assertRaisesRegex(RuntimeError, 'readiness'): self.deploy(self.new)
        self.assertEqual(self.state()['current']['manifest'], self.old)
        self.assertIsNone(self.state()['pending'])
        self.assertTrue(self.running)
        self.assertTrue(any('--volume' in arguments and ':/prior-policy.json:ro' in ' '.join(arguments) for arguments in self.calls))
        self.assertFalse(any('pg_restore' in arguments or 'down' in arguments for arguments in self.calls))

    def test_backup_failure_resumes_old_and_never_applies_candidate(self):
        self.deploy(self.old)
        self.calls.clear()
        self.fail_backup = True
        with self.assertRaisesRegex(RuntimeError, 'backup'): self.deploy(self.new)
        self.assertEqual(self.state()['current']['manifest'], self.old)
        self.assertTrue(self.running)
        for arguments in self.calls:
            if 'up' in arguments:
                manifest = role_release.load(Path(arguments[arguments.index('-f') + 1]).parent.parent / 'release.json')
                self.assertEqual(manifest, self.old)

    def test_interrupted_apply_resumes_without_backing_up_new_data_as_old(self):
        self.deploy(self.old)
        self.interrupt_phase = 'applying'
        with self.assertRaises(KeyboardInterrupt): self.deploy(self.new)
        self.assertEqual(self.state()['pending']['phase'], 'applying')
        self.assertEqual(self.backups, 1)
        with self.assertRaisesRegex(ValueError, 'same pending'): self.deploy(self.old)
        self.deploy(self.new)
        self.assertEqual(self.backups, 1)
        self.assertEqual(self.state()['current']['manifest'], self.new)

    def test_failed_rollback_remains_pending_and_resumes(self):
        self.deploy(self.old)
        self.fail_health = self.new['commit']
        self.fail_up = self.old['commit']
        with self.assertRaisesRegex(RuntimeError, 'startup'): self.deploy(self.new)
        self.assertEqual(self.state()['pending']['phase'], 'rollback')
        self.fail_up = None
        with self.assertRaisesRegex(RuntimeError, 'rollback completed'): self.deploy(self.new)
        self.assertIsNone(self.state()['pending'])
        self.assertEqual(self.state()['current']['manifest'], self.old)

    def test_rollback_never_commits_success_with_replaced_data_identity(self):
        self.deploy(self.old)
        original = self.healthy
        def unhealthy(root, record, **kwargs):
            if record['manifest'] == self.new:
                self.data_identity['postgres_system_identifier'] = '987654321'
                raise RuntimeError('Injected identity replacement')
            original(root, record, **kwargs)
        self.healthy = unhealthy
        with self.assertRaisesRegex(ValueError, 'Rollback data identity changed'): self.deploy(self.new)
        self.assertEqual(self.state()['pending']['phase'], 'rollback')
        self.assertEqual(self.state()['current']['manifest'], self.old)

    def test_new_attempt_captures_policy_after_previous_completed_rollback(self):
        self.deploy(self.old)
        self.fail_health = self.new['commit']
        with self.assertRaises(RuntimeError): self.deploy(self.new)
        self.policy['text_max_length'] = 12000
        with self.assertRaises(RuntimeError): self.deploy(self.new)
        target = core_deploy.record_for(self.root, self.inventory, self.new)
        self.assertEqual(managed_state.read(core_deploy.policy_path(self.root, target)), self.policy)

    def test_initial_interruption_keeps_owned_data_for_same_candidate_retry(self):
        self.interrupt_phase = 'applying'
        with self.assertRaises(KeyboardInterrupt): self.deploy(self.old)
        self.volumes = True
        self.assertIsNone(self.state()['current'])
        self.deploy(self.old)
        self.assertEqual(self.state()['current']['manifest'], self.old)

    def test_fast_successful_configure_is_waited_for_before_starting_writers(self):
        original=self.execute;finished=False
        def execute(arguments,**kwargs):
            nonlocal finished
            if 'up' in arguments and arguments[-1]=='configure':
                if '--wait' in arguments:raise RuntimeError('Compose reports fast exited(0) as failure')
            elif 'wait' in arguments and arguments[-1]=='configure':finished=True
            elif 'up' in arguments:self.assertTrue(finished,'Writers started before configure completion')
            return original(arguments,**kwargs)
        self.execute=execute
        self.deploy(self.old)
        self.assertTrue(finished)
        self.assertEqual(self.state()['current']['manifest'],self.old)

    def test_configure_nonzero_exit_restores_previous_code_without_restoring_database(self):
        self.deploy(self.old);original=self.execute
        identity=self.data_identity.copy()
        def execute(arguments,**kwargs):
            if 'wait' in arguments and arguments[-1]=='configure':
                manifest=role_release.load(Path(arguments[arguments.index('-f')+1]).parent.parent/'release.json')
                if manifest==self.new:raise RuntimeError('Configure exited with code 7')
            return original(arguments,**kwargs)
        self.execute=execute;self.calls.clear()
        with self.assertRaisesRegex(RuntimeError,'code 7'):self.deploy(self.new)
        self.assertEqual(self.state()['current']['manifest'],self.old)
        self.assertIsNone(self.state()['pending']);self.assertTrue(self.running)
        self.assertEqual(self.data_identity,identity)
        self.assertFalse(any('pg_restore' in arguments or 'rm' in arguments for arguments in self.calls))

    def test_replaced_database_is_rejected_before_stopping_or_reinitializing_services(self):
        self.deploy(self.old)
        self.data_identity['postgres_system_identifier'] = '987654321'
        self.calls.clear()
        with self.assertRaisesRegex(ValueError, 'data identity changed'): self.deploy(self.new)
        self.assertFalse(any('up' in arguments or 'stop' in arguments for arguments in self.calls))
        self.assertTrue(self.running)

    def test_identity_probes_are_offline_read_only_and_missing_volume_never_initializes(self):
        record = core_deploy.record_for(self.root, self.inventory, self.old)
        missing = None
        probes = []
        def execute(arguments, **kwargs):
            if arguments[:3] == ['docker', 'volume', 'ls']:
                name = arguments[-1].removeprefix('name=^').removesuffix('$')
                return b'' if name == missing else name.encode()
            if arguments[:2] == ['docker', 'run']:
                probes.append(arguments)
                self.assertEqual(arguments[arguments.index('--network') + 1], 'none')
                self.assertIn('--read-only', arguments)
                self.assertIn('ALL', arguments)
                mount = arguments[arguments.index('--mount') + 1]
                self.assertIn('readonly,volume-nocopy', mount)
                if 'pg_controldata' in arguments:
                    self.assertEqual(arguments[arguments.index('--user') + 1], 'postgres')
                    return b'Database system identifier: 123456789\n'
                self.assertEqual(arguments[arguments.index('--user') + 1], '991:991')
                return json.dumps({'server_name': self.public['matrix_server_name'], 'sha256': 'f' * 64}).encode()
            return self.execute(arguments, **kwargs)
        self.assertEqual(core_deploy.data_identity(self.root, record, execute=execute), self.data_identity)
        self.assertEqual(len(probes), 2)
        probes.clear()
        missing = 'voicechat_postgres'
        with self.assertRaisesRegex(ValueError, 'volume is missing'):
            core_deploy.data_identity(self.root, record, execute=execute)
        self.assertEqual(probes, [])

    def test_unknown_volumes_runtime_changes_and_tampering_refuse_changes(self):
        self.networks = True
        with self.assertRaisesRegex(ValueError, 'network requires explicit adoption'): self.deploy(self.old)
        self.networks = False
        self.volumes = True
        with self.assertRaisesRegex(ValueError, 'adoption'): self.deploy(self.old)
        self.volumes = False
        self.deploy(self.old)
        (self.root / 'runtime/stand.env').write_text('changed-secret')
        self.calls.clear()
        with self.assertRaisesRegex(ValueError, 'runtime secrets'): self.deploy(self.new)
        self.assertEqual(self.calls, [])
        (self.root / 'runtime/stand.env').write_text('synthetic-private-runtime\n')
        source = self.root / 'releases' / role_release.json_digest(self.new) / 'infra/configure.py'
        source.write_text('modified')
        with self.assertRaises(ValueError): self.deploy(self.new)
        self.assertEqual(self.calls, [])


if __name__ == '__main__': unittest.main()
