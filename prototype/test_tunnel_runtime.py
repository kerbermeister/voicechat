import base64
from copy import deepcopy
import fcntl
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import tunnel_config
import tunnel_runtime
from test_node_inventory import fixture, key


def state():
    inventory = fixture()
    private = {name: base64.b64encode(bytes([number]) * 32).decode()
               for number, name in enumerate(tunnel_config.physical_nodes(inventory), 1)}
    registry = {'schema': 1, 'service_id': inventory['service_id'], 'nodes': {
        name: {'generation': 1, 'public_key': tunnel_config.public_key(value)} for name, value in private.items()}}
    return {'schema': 1, 'inventory': inventory, 'public_keys': registry,
            'node': 'core', 'private_key': private['core']}


class Network:
    def __init__(self):
        self.links = []
        self.addresses = []
        self.routes = [{'dst': 'default', 'gateway': '192.0.2.1', 'dev': 'eth0'}]
        self.public = '(none)'
        self.peers = []
        self.calls = []
        self.fail_route = False

    def run(self, *args):
        self.calls.append(args)
        if args[:4] == ('ip', '-j', '-d', 'link'): return json.dumps(self.links)
        if args[:4] == ('ip', '-j', '-4', 'address'): return json.dumps(self.addresses)
        if args[:4] == ('ip', '-j', '-4', 'route'): return json.dumps(self.routes)
        if args == ('wg', 'show', 'wg-vc', 'public-key'): return self.public
        if args[:3] == ('ip', 'link', 'add'):
            self.links = [{'ifname': 'wg-vc', 'linkinfo': {'info_kind': 'wireguard'}}]
        elif args[:2] == ('wg', 'syncconf'):
            lines = Path(args[3]).read_text().splitlines()
            self.public = tunnel_config.public_key(next(line.split(' = ')[1] for line in lines if line.startswith('PrivateKey')))
            self.peers = [line.split(' = ')[1] for line in lines if line.startswith('PublicKey')]
        elif args[:3] == ('ip', 'address', 'replace'):
            self.addresses = [{'ifname': 'wg-vc', 'addr_info': [{'family': 'inet', 'local': args[3].split('/')[0]}]}]
        elif args[:3] == ('ip', 'link', 'set'): pass
        elif args[:3] == ('ip', 'route', 'add'):
            if self.fail_route: raise RuntimeError('Injected route failure')
            self.routes.append({'dst': args[3], 'dev': 'wg-vc'})
        elif args[:3] == ('ip', 'route', 'del'):
            self.routes = [route for route in self.routes if route['dst'] != args[3]]
        else:
            raise AssertionError('Unexpected network operation: ' + str(args))
        return ''


class TunnelRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'managed'
        self.value = state()
        self.network = Network()

    def apply(self, value):
        tunnel_runtime.reconcile(self.root, value, run=self.network.run)

    def test_repeat_preserves_identity_then_retires_peer_routes(self):
        self.apply(self.value)
        before = (self.root / 'desired.json').read_bytes()
        stamp = (self.root / 'desired.json').stat().st_mtime_ns
        self.apply(self.value)
        self.assertEqual((self.root / 'desired.json').read_bytes(), before)
        self.assertEqual((self.root / 'desired.json').stat().st_mtime_ns, stamp)
        self.assertEqual(sum(call[:3] == ('ip', 'link', 'add') for call in self.network.calls), 1)
        self.assertEqual(sum(call[:3] == ('ip', 'route', 'add') for call in self.network.calls), 2)
        single = deepcopy(self.value)
        single['inventory']['edges'] = [{'id': 'a', 'host': 'core'}]
        single['public_keys']['nodes'] = {'core': single['public_keys']['nodes']['core']}
        self.apply(single)
        self.assertEqual(self.network.peers, [])
        self.assertEqual(self.network.routes, [{'dst': 'default', 'gateway': '192.0.2.1', 'dev': 'eth0'}])
        self.assertEqual(self.network.addresses[0]['addr_info'][0]['local'], '10.88.0.1')
        self.assertEqual((self.root / 'desired.json').stat().st_mode & 0o777, 0o600)
        self.assertFalse(list(self.root.glob('.wg-*')))

    def test_interrupted_apply_resumes_committed_intent_and_recreates_interface(self):
        self.network.fail_route = True
        with self.assertRaisesRegex(RuntimeError, 'Injected'): self.apply(self.value)
        self.assertEqual(tunnel_runtime.read_state(self.root / 'desired.json'), self.value)
        self.network.fail_route = False
        self.apply(None)
        self.assertEqual(len(self.network.routes), 3)
        self.network = Network()  # Reboot/network namespace replacement, saved disk remains.
        self.apply(None)
        self.assertEqual(len(self.network.routes), 3)
        self.assertEqual(self.network.public, self.value['public_keys']['nodes']['core']['public_key'])

    def test_collisions_fail_before_intent_or_network_mutation(self):
        for changes in (
            {'links': [{'ifname': 'wg-vc', 'linkinfo': {'info_kind': 'wireguard'}}]},
            {'addresses': [{'ifname': 'eth1', 'addr_info': [{'family': 'inet', 'local': '10.88.0.1'}]}]},
            {'routes': [{'dst': '10.88.0.0/24', 'dev': 'eth1'}]},
        ):
            self.network = Network()
            for name, value in changes.items(): setattr(self.network, name, value)
            with self.subTest(changes=changes), self.assertRaises(ValueError): self.apply(self.value)
            self.assertFalse((self.root / 'desired.json').exists())
            self.assertFalse(any(call[:3] == ('ip', 'link', 'add') for call in self.network.calls))

    def test_peer_replacement_requires_generation_and_cannot_repurpose_local_host(self):
        self.apply(self.value)
        changed = deepcopy(self.value)
        changed['public_keys']['nodes']['edge-b']['public_key'] = tunnel_config.public_key(base64.b64encode(bytes([9]) * 32).decode())
        with self.assertRaises(ValueError): self.apply(changed)
        changed['public_keys']['nodes']['edge-b']['generation'] = 2
        changed['inventory']['edges'][0].update(generation=2, ssh_host_key=key(9))
        self.apply(changed)
        self.assertNotIn(self.value['public_keys']['nodes']['edge-b']['public_key'], self.network.peers)
        with self.assertRaises(ValueError): self.apply(self.value)
        changed['inventory']['core'].update(generation=2, ssh_host_key=key(8))
        changed['public_keys']['nodes']['core']['generation'] = 2
        with self.assertRaises(ValueError): self.apply(changed)

    def test_foreign_live_key_and_unsafe_state_never_regenerate_identity(self):
        self.apply(self.value)
        self.network.public = 'foreign'
        with self.assertRaises(ValueError): self.apply(None)
        self.network.public = self.value['public_keys']['nodes']['core']['public_key']
        saved = self.root / 'desired.json'
        saved.chmod(0o644)
        with self.assertRaises(ValueError): self.apply(None)
        saved.chmod(0o600)
        saved.write_text('broken')
        with self.assertRaises(ValueError): self.apply(None)
        saved.unlink()
        saved.symlink_to(self.root / 'missing')
        with self.assertRaises(OSError): self.apply(None)

    def test_concurrent_apply_is_rejected_before_changes(self):
        self.apply(self.value)
        count = len(self.network.calls)
        with (self.root / 'apply.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError): self.apply(None)
        self.assertEqual(len(self.network.calls), count)
