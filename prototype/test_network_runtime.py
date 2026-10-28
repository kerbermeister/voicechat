from copy import deepcopy
import fcntl
from pathlib import Path
import sys
import tempfile
import shutil
from unittest.mock import patch
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import network_runtime
from test_firewall_runtime import Firewall
from test_tunnel_runtime import Network, state


class NetworkRuntimeTests(unittest.TestCase):
    def test_unreadable_future_state_never_replaces_recoverable_intent(self):
        with managed_state.locked(self.root):
            path = self.root / 'desired.json'
            managed_state.persist(path, self.value)
            for value in ({'too_large': 'я' * 65536}, {'not_json': float('nan')}):
                with self.assertRaises(ValueError): managed_state.persist(path, value)
                self.assertEqual(managed_state.read(path), self.value)
            self.assertFalse(list(self.root.glob('.intent-*')))

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'network'
        self.value = {**state(), 'edge_subnet': '10.241.0.0/28'}
        self.firewall = Firewall(self.value)
        self.tunnel = Network()
        self.calls = []
        self.fail_tunnel = False

    def command(self, *args):
        self.calls.append(args)
        if args[:2] == ('wg', 'syncconf') and self.fail_tunnel:
            raise RuntimeError('Interrupted between firewall and tunnel')
        return self.firewall.run(*args) if args[0] == 'nft' else self.tunnel.run(*args)

    def apply(self, value):
        network_runtime.reconcile(self.root, value, run=self.command)

    def test_interruption_resumes_shared_revocation_instead_of_old_tunnel_snapshot(self):
        self.apply(self.value)
        changed = deepcopy(self.value)
        changed['inventory']['edges'].pop()
        retired = changed['public_keys']['nodes'].pop('edge-c')['public_key']
        self.fail_tunnel = True
        with self.assertRaisesRegex(RuntimeError, 'between'): self.apply(changed)
        self.assertEqual(managed_state.read(self.root / 'applied.json')['phase'], 'applying')
        self.assertEqual(managed_state.read(self.root / 'desired.json'), changed)
        self.assertNotIn('192.0.2.12', self.firewall.applied[-1])
        self.assertIn(retired, self.tunnel.peers)
        self.fail_tunnel = False
        self.apply(None)
        self.assertEqual(managed_state.read(self.root / 'applied.json'), {
            'schema': 1, 'sha256': network_runtime.fingerprint(changed), 'phase': 'complete'})
        self.assertNotIn(retired, self.tunnel.peers)
        self.assertEqual(len(self.tunnel.routes), 2)
        self.assertEqual(managed_state.read(self.root / 'tunnel/desired.json')['inventory'], changed['inventory'])
        self.assertEqual(managed_state.read(self.root / 'firewall/desired.json')['inventory'], changed['inventory'])
        first_filter = next(index for index, call in enumerate(self.calls) if call[:2] == ('nft', '--file'))
        first_tunnel = next(index for index, call in enumerate(self.calls) if call[:2] == ('wg', 'syncconf'))
        self.assertLess(first_filter, first_tunnel)

    def test_receipt_covers_policy_sources_even_when_inventory_does_not_change(self):
        self.apply(self.value)
        original = managed_state.read(self.root / 'applied.json')['sha256']
        source = self.root / 'updated-source'
        source.mkdir()
        for name in network_runtime.SOURCES:
            shutil.copyfile(ROOT / 'infra' / name, source / name)
        with patch.object(network_runtime, '__file__', str(source / 'network_runtime.py')):
            self.assertEqual(network_runtime.fingerprint(self.value), original)
            policy = source / 'firewall_config.py'
            policy.write_bytes(policy.read_bytes() + b'\n# changed policy code\n')
            self.assertNotEqual(network_runtime.fingerprint(self.value), original)
            self.apply(None)
            self.assertEqual(managed_state.read(self.root / 'applied.json')['sha256'],
                             network_runtime.fingerprint(self.value))

    def test_reboot_restores_both_components_from_common_state(self):
        self.apply(self.value)
        self.firewall = Firewall(self.value)
        self.tunnel = Network()
        self.apply(None)
        self.assertEqual(len(self.firewall.applied), 1)
        self.assertEqual(len(self.tunnel.peers), 2)
        self.assertEqual((self.root / 'desired.json').stat().st_mode & 0o777, 0o600)

    def test_foreign_collision_and_unclaimed_child_fail_before_parent_commit(self):
        self.tunnel.links = [{'ifname': 'wg-vc', 'linkinfo': {'info_kind': 'wireguard'}}]
        with self.assertRaises(ValueError): self.apply(self.value)
        self.assertFalse((self.root / 'desired.json').exists())
        self.assertFalse(self.firewall.applied)
        self.tunnel = Network()
        firewall, _ = network_runtime.components(self.value)
        managed_state.persist(self.root / 'firewall/desired.json', firewall)
        with self.assertRaisesRegex(ValueError, 'Unclaimed'): self.apply(self.value)
        self.assertFalse((self.root / 'desired.json').exists())

    def test_invalid_identity_and_concurrent_apply_do_not_mutate_components(self):
        self.apply(self.value)
        changed = {**self.value, 'edge_subnet': '10.242.0.0/28'}
        with self.assertRaises(ValueError): self.apply(changed)
        count = len(self.calls)
        with (self.root / 'apply.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError): self.apply(None)
        self.assertEqual(len(self.calls), count)
