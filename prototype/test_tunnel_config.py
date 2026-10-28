import base64
from copy import deepcopy
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import tunnel_config as tunnel
from test_node_inventory import fixture


class TunnelTests(unittest.TestCase):
    def setUp(self):
        self.inventory = fixture()
        # Synthetic fixture keys; production key generation uses OpenSSL CSPRNG.
        self.private = {name: base64.b64encode(bytes([n]) * 32).decode()
                        for n, name in enumerate(('core', 'edge-b', 'edge-c'), 1)}
        self.registry = {'schema': 1, 'service_id': self.inventory['service_id'], 'nodes': {
            name: {'generation': 1, 'public_key': tunnel.public_key(value)}
            for name, value in self.private.items()}}

    def test_star_topology_and_host_only_routes(self):
        for name in self.private:
            value = tunnel.render(self.inventory, self.registry, name, self.private[name])
            self.assertNotIn('0.0.0.0/0', value)
            self.assertNotIn('PostUp', value)
            self.assertNotIn('SaveConfig', value)
            self.assertEqual(value.count('[Peer]'), 2 if name == 'core' else 1)
            self.assertEqual(value.count('PersistentKeepalive = 25'), value.count('[Peer]'))
            for other, private in self.private.items():
                if other != name: self.assertNotIn(private, value)
            if name != 'core':
                self.assertIn('AllowedIPs = 10.88.0.1/32', value)
                self.assertIn('Endpoint = 192.0.2.10:51820', value)
                other = 'edge-b' if name == 'edge-c' else 'edge-c'
                self.assertNotIn(self.registry['nodes'][other]['public_key'], value)
        wrong = self.private['edge-b']
        with self.assertRaises(ValueError): tunnel.render(self.inventory, self.registry, 'core', wrong)

    def test_one_host_has_address_but_no_remote_peer(self):
        inventory = {**self.inventory, 'edges': [{'id': 'a', 'host': 'core'}]}
        registry = {**self.registry, 'nodes': {'core': self.registry['nodes']['core']}}
        value = tunnel.render(inventory, registry, 'core', self.private['core'])
        self.assertIn('Address = 10.88.0.1/32', value)
        self.assertNotIn('[Peer]', value)
        with self.assertRaises(ValueError): tunnel.render(inventory, registry, 'edge-a', self.private['core'])

    def test_replacement_revokes_old_key_and_rejects_stale_registry(self):
        inventory = deepcopy(self.inventory)
        inventory['edges'][1]['generation'] = 2
        with self.assertRaises(ValueError): tunnel.validate_keys(self.registry, inventory)
        registry = deepcopy(self.registry)
        replacement = tunnel.public_key(base64.b64encode(bytes([4]) * 32).decode())
        registry['nodes']['edge-c'] = {'generation': 2, 'public_key': replacement}
        value = tunnel.render(inventory, registry, 'core', self.private['core'])
        self.assertIn(replacement, value)
        self.assertNotIn(self.registry['nodes']['edge-c']['public_key'], value)
        inventory['edges'].pop()
        registry['nodes'].pop('edge-c')
        self.assertEqual(tunnel.render(inventory, registry, 'core', self.private['core']).count('[Peer]'), 1)

    def test_duplicate_missing_injected_keys_and_wrong_installation_rejected(self):
        changes = [lambda r: r.update(schema=True), lambda r: r.update(service_id='other'),
            lambda r: r['nodes'].pop('edge-c'),
            lambda r: r['nodes']['edge-c'].update(generation=True),
            lambda r: r['nodes']['edge-c'].update(public_key=r['nodes']['core']['public_key']),
            lambda r: r['nodes']['edge-c'].update(public_key='x\nPostUp = bad'),
            lambda r: r['nodes']['edge-c'].update(private_key=self.private['edge-c'])]
        for change in changes:
            value = deepcopy(self.registry); change(value)
            with self.assertRaises(ValueError): tunnel.validate_keys(value, self.inventory)

    def test_node_local_key_is_unique_private_and_retained_on_repeat(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'node.key'
            first = tunnel.ensure_key(path)
            content = path.read_bytes()
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(tunnel.ensure_key(path), first)
            self.assertEqual(path.read_bytes(), content)
            self.assertNotEqual(tunnel.ensure_key(Path(temporary) / 'other.key'), first)
            path.chmod(0o644)
            with self.assertRaises(ValueError): tunnel.ensure_key(path)
            path.chmod(0o600)
            link = Path(temporary) / 'link.key'; link.symlink_to(path)
            with self.assertRaises(OSError): tunnel.ensure_key(link)
            path.write_text('damaged\n')
            with self.assertRaises(ValueError): tunnel.ensure_key(path)
            self.assertEqual(path.read_text(), 'damaged\n')


if __name__ == '__main__': unittest.main()
