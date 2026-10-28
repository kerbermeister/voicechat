from copy import deepcopy
from contextlib import nullcontext
import base64
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import edge_deploy
import managed_state
import network_runtime
import role_release
from render_roles import bundle, write_bundle
from test_node_inventory import fixture
from test_tunnel_runtime import state as tunnel_state
from topology import load


class EdgeDeployTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        (self.root / 'releases').mkdir()
        (self.root / 'runtime').mkdir(mode=0o700)
        (self.root / 'runtime/tls').mkdir(mode=0o700)
        self.public = load(ROOT / 'infra/three-vps.example.json')
        self.inventory = fixture()
        self.image = 'ghcr.io/fixture/web@sha256:' + '1' * 64
        self.core = role_release.make(self.public, self.inventory, 'core', 'a' * 40, self.image)
        self.old = self.release('a', self.image)
        self.new = self.release('b', self.image.replace('1' * 64, '2' * 64))
        self.calls = []
        self.running = False
        self.fail_up = None
        self.fail_pull = False
        self.fail_health = None
        self.other_restarted = False
        self.interrupt = False
        self.certificates = self.enterContext(patch.object(edge_deploy, 'certificate', return_value=b'fixture'))

    def release(self, revision, image):
        manifest = role_release.make(self.public, self.inventory, 'edge', revision * 40, image, 'b')
        path = self.root / 'releases' / role_release.json_digest(manifest)
        files, runtime = bundle(self.public, self.inventory, 'edge', 'b')
        write_bundle(path, files, runtime)
        shutil.rmtree(path / 'infra/runtime')  # Only empty disposable renderer directories.
        (path / 'infra/runtime').symlink_to(self.root / 'runtime', target_is_directory=True)
        managed_state.persist(path / 'release.json', manifest)
        return manifest

    def execute(self, args, *, env=None):
        self.calls.append(args)
        if args[:2] == ['docker', 'inspect']:
            restart = '1' if self.other_restarted else '0'
            return ('\n'.join(f'{name} true same-start {restart}' for name in ('turn', 'ingress', 'health'))).encode()
        self.assertEqual(args[:2], ['docker', 'compose'])
        self.assertEqual(args[args.index('--project-name') + 1], 'voicechat-edge-b')
        self.assertNotIn('control', args)
        self.assertNotIn('synapse', args)
        revision = role_release.load(Path(args[args.index('-f') + 1]).parent.parent / 'release.json')['commit']
        if 'pull' in args and self.fail_pull: raise RuntimeError('pull failed')
        if 'up' in args:
            with self.assertRaises(BlockingIOError):
                with managed_state.locked(self.root / 'runtime/tls'): pass
            if self.fail_up == revision: raise RuntimeError('up failed')
            self.running = True
            if self.interrupt: raise KeyboardInterrupt('process terminated')
        if 'stop' in args: self.running = False
        if 'ps' in args:
            return b'turn\ningress\nhealth\n' if self.running else b''
        return b''

    def health(self, root, record, **kwargs):
        if record['manifest']['commit'] == self.fail_health: raise RuntimeError('not healthy')

    def deploy(self, manifest, scope='edge'):
        return edge_deploy.deploy(self.root, self.public, self.inventory, manifest, self.core,
            scope=scope, execute=self.execute, check_network=lambda *a, **k: nullcontext(), check_health=self.health)

    def state(self): return edge_deploy.read_state(self.root, 'b')

    def test_initial_then_web_keeps_other_services_and_atomic_previous(self):
        self.deploy(self.old)
        self.calls.clear()
        self.deploy(self.new, 'web')
        state = self.state()
        self.assertEqual(state['current']['manifest'], self.new)
        self.assertEqual(state['previous']['manifest'], self.old)
        self.assertIsNone(state['pending'])
        self.assertEqual([args[-2:] for args in self.calls if 'up' in args], [['--no-deps', 'web']])
        self.assertEqual([args[-2:] for args in self.calls if 'pull' in args], [['pull', 'web']])
        self.deploy(self.new, 'web')
        self.assertEqual(self.state()['previous']['manifest'], self.old)

    def test_config_only_release_at_same_commit_keeps_distinct_rollback_bundle(self):
        self.deploy(self.old)
        old_path = edge_deploy.release_path(self.root, self.state()['current'])
        old_caddy = (old_path / 'infra/Caddyfile').read_bytes()
        self.public['web_origins'].append('https://fallback.example.com')
        changed = self.release('a', self.image)
        self.assertEqual(changed['commit'], self.old['commit'])
        self.assertNotEqual(role_release.json_digest(changed), role_release.json_digest(self.old))
        self.deploy(changed)
        self.assertEqual(self.state()['previous']['manifest'], self.old)
        self.assertEqual((old_path / 'infra/Caddyfile').read_bytes(), old_caddy)
        current_path = edge_deploy.release_path(self.root, self.state()['current'])
        self.assertNotEqual(current_path, old_path)
        self.assertIn('https://fallback.example.com', (current_path / 'infra/Caddyfile').read_text())

    def test_pull_failure_changes_no_services_and_blocks_different_pending_target(self):
        self.deploy(self.old)
        self.calls.clear()
        self.fail_pull = True
        with self.assertRaisesRegex(RuntimeError, 'pull'): self.deploy(self.new, 'web')
        self.assertFalse(any('up' in args for args in self.calls))
        self.assertEqual(self.state()['pending']['phase'], 'prepared')
        with self.assertRaisesRegex(ValueError, 'Resume'): self.deploy(self.old, 'web')
        self.fail_pull = False
        self.deploy(self.new, 'web')

    def test_failed_candidate_rolls_back_only_web_and_keeps_current(self):
        self.deploy(self.old)
        self.calls.clear()
        self.fail_health = self.new['commit']
        with self.assertRaisesRegex(RuntimeError, 'healthy'): self.deploy(self.new, 'web')
        self.assertEqual(self.state()['current']['manifest'], self.old)
        self.assertIsNone(self.state()['pending'])
        self.assertEqual(len([args for args in self.calls if 'up' in args]), 2)
        self.assertTrue(all(args[-2:] == ['--no-deps', 'web'] for args in self.calls if 'up' in args))

    def test_interrupted_apply_resumes_same_candidate_and_failed_rollback_stays_pending(self):
        self.deploy(self.old)
        self.interrupt = True
        with self.assertRaises(KeyboardInterrupt): self.deploy(self.new)
        self.assertEqual(self.state()['pending']['phase'], 'applying')
        self.interrupt = False
        self.fail_health = self.new['commit']
        self.fail_up = self.old['commit']
        with self.assertRaisesRegex(RuntimeError, 'up failed'): self.deploy(self.new)
        self.assertEqual(self.state()['pending']['phase'], 'rollback')
        self.fail_up = None
        with self.assertRaisesRegex(RuntimeError, 'rollback completed'): self.deploy(self.new)
        self.assertEqual(self.state()['current']['manifest'], self.old)
        self.assertIsNone(self.state()['pending'])

    def test_initial_failure_stops_owned_services_without_deleting_any_volumes(self):
        self.fail_health = self.old['commit']
        with self.assertRaises(RuntimeError): self.deploy(self.old)
        self.assertFalse(self.running)
        self.assertIsNone(self.state()['current'])
        self.assertTrue(any('stop' in args for args in self.calls))
        self.assertFalse(any('down' in args or '--volumes' in args for args in self.calls))

    def test_foreign_containers_and_missing_web_baseline_are_never_adopted(self):
        with self.assertRaises(ValueError): self.deploy(self.old, 'web')
        self.running = True
        with self.assertRaisesRegex(ValueError, 'adoption'): self.deploy(self.old)
        self.assertFalse(any('up' in args or 'pull' in args for args in self.calls))
        self.assertFalse((self.root / 'state.json').exists())

    def test_source_tampering_and_changed_host_fail_before_commands(self):
        path = self.root / 'releases' / role_release.json_digest(self.old) / 'infra/Caddyfile'
        path.write_text(path.read_text() + '\n# unreviewed')
        with self.assertRaises(ValueError): self.deploy(self.old)
        self.assertEqual(self.calls, [])

    def test_tls_failure_prevents_up_and_unexpected_service_restart_prevents_commit(self):
        self.deploy(self.old)
        self.calls.clear()
        self.certificates.side_effect = ValueError('invalid certificate')
        with self.assertRaisesRegex(ValueError, 'certificate'): self.deploy(self.new, 'web')
        self.assertFalse(any('up' in args for args in self.calls))
        self.assertEqual(self.state()['current']['manifest'], self.old)
        self.certificates.side_effect = None
        original = self.health
        def restarted(root, record, **kwargs):
            original(root, record, **kwargs)
            if record['manifest'] == self.new: self.other_restarted = True
        self.health = restarted
        with self.assertRaisesRegex(RuntimeError, 'another edge service'): self.deploy(self.new, 'web')
        self.assertEqual(self.state()['current']['manifest'], self.old)

    def test_tampered_rollback_bundle_is_rejected_before_updating_current(self):
        self.deploy(self.old)
        self.calls.clear()
        path = self.root / 'releases' / role_release.json_digest(self.old) / 'infra/Caddyfile'
        path.write_text('modified baseline')
        with self.assertRaises(ValueError): self.deploy(self.new)
        self.assertEqual(self.calls, [])

    def test_concurrent_role_or_tls_operation_cannot_mutate_containers(self):
        with managed_state.locked(self.root):
            with self.assertRaises(BlockingIOError): self.deploy(self.old)
        self.assertEqual(self.calls, [])
        with managed_state.locked(self.root / 'runtime/tls'):
            with self.assertRaises(BlockingIOError): self.deploy(self.old)
        self.assertFalse(any('up' in args for args in self.calls))

    def test_network_gate_requires_completed_matching_intent_and_holds_host_lock(self):
        directory = self.root / 'network'
        directory.mkdir(mode=0o700)
        desired = {**tunnel_state(), 'node': 'edge-b',
                   'private_key': base64.b64encode(bytes([2]) * 32).decode(), 'edge_subnet': '10.241.0.0/28'}
        firewall, tunnel = network_runtime.components(desired)
        managed_state.persist(directory / 'desired.json', desired)
        for name, value in [('firewall', firewall), ('tunnel', tunnel)]:
            (directory / name).mkdir(mode=0o700)
            managed_state.persist(directory / name / 'desired.json', value)
        status = {'schema': 1, 'sha256': network_runtime.fingerprint(desired), 'phase': 'complete'}
        managed_state.persist(directory / 'applied.json', status)
        def guard(active=b'active'):
            return edge_deploy.network_ready(self.inventory, 'b', '10.241.0.0/28',
                execute=lambda *a: active, directory=directory)
        with guard():
            with self.assertRaises(BlockingIOError):
                with managed_state.locked(directory): pass
        with self.assertRaisesRegex(ValueError, 'not active'):
            with guard(b'inactive'): pass
        managed_state.persist(directory / 'applied.json', {**status, 'phase': 'applying'})
        with self.assertRaisesRegex(ValueError, 'interrupted'):
            with guard(): pass
        managed_state.persist(directory / 'applied.json', status)
        managed_state.persist(directory / 'firewall/desired.json', {**firewall, 'edge_subnet': '10.242.0.0/28'})
        with self.assertRaisesRegex(ValueError, 'interrupted'):
            with guard(): pass
