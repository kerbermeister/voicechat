import base64
from copy import deepcopy
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import node_inventory
from render_edge import render
from topology import client_defines, load


def key(number):
    wire = struct.pack('!I', 11) + b'ssh-ed25519' + struct.pack('!I', 32) + bytes([number]) * 32
    return 'ssh-ed25519 ' + base64.b64encode(wire).decode()


def fixture():
    value = json.loads((ROOT / 'infra/node-inventory.example.json').read_text())
    for number, node in enumerate([value['core'], *value['edges']], 1):
        node['ssh_host_key'] = key(number)
    return value


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.public = load(ROOT / 'infra/three-vps.example.json')
        self.inventory = fixture()

    def test_replacement_changes_host_files_without_rebuilding_public_config(self):
        before = render(self.public, self.inventory, 'c', '10.241.0.2')
        defines = client_defines(self.public)
        replacement = deepcopy(self.inventory)
        replacement['edges'][1].update(public_ip='192.0.2.20', generation=2, ssh_host_key=key(4))
        node_inventory.validate(replacement, self.public)
        node_inventory.check_replacement(self.inventory, replacement)
        after = render(self.public, replacement, 'c', '10.241.0.2')
        self.assertEqual(before['Caddyfile'], after['Caddyfile'])
        self.assertEqual(before['haproxy.cfg'], after['haproxy.cfg'])
        self.assertNotEqual(before['known_hosts'], after['known_hosts'])
        self.assertEqual(defines, client_defines(self.public))
        self.assertNotIn(self.inventory['core']['ssh_host_key'], after['node.json'])

    def test_add_and_remove_edge_with_stable_existing_host_assignments(self):
        expanded = deepcopy(self.public)
        expanded['edges'].append({'id':'d', 'origin':'https://d.example.com', 'turn_host':'turn-d.example.com'})
        inventory = deepcopy(self.inventory)
        inventory['edges'].append({'id':'d', 'generation':1, 'public_ip':'192.0.2.13',
                                  'tunnel_ip':'10.88.0.4', 'ssh_host_key':key(4)})
        node_inventory.validate(inventory, expanded)
        node_inventory.check_replacement(self.inventory, inventory)
        files = render(expanded, inventory, 'd', '10.241.0.2')
        self.assertIn('turn-d.example.com', files['haproxy.cfg'])
        node_inventory.check_replacement(inventory, self.inventory)

    def test_one_shared_host_expands_then_moves_edge_without_changing_client_identity(self):
        public = load(ROOT / 'infra/single-vps.example.json')
        inventory = json.loads((ROOT / 'infra/single-node-inventory.example.json').read_text())
        inventory['core']['ssh_host_key'] = key(1)
        node_inventory.validate(inventory, public)
        shared = node_inventory.edge_assignment(inventory, 'a')
        self.assertEqual(shared, {'id':'a', **inventory['core']})
        before = render(public, inventory, 'a', '10.241.0.2')
        expanded = deepcopy(public)
        expanded['edges'].append(self.public['edges'][0])
        physical = deepcopy(inventory)
        physical['edges'].append(self.inventory['edges'][0])
        node_inventory.validate(physical, expanded)
        node_inventory.check_replacement(inventory, physical)
        # Move the existing edge identity to a new machine; core stays put.
        moved = deepcopy(inventory)
        moved['edges'][0] = {**self.inventory['edges'][0], 'id':'a', 'generation':2}
        node_inventory.validate(moved, public)
        node_inventory.check_replacement(inventory, moved)
        after = render(public, moved, 'a', '10.241.0.2')
        self.assertEqual(before['Caddyfile'], after['Caddyfile'])
        self.assertEqual(before['haproxy.cfg'], after['haproxy.cfg'])
        self.assertNotEqual(before['known_hosts'], after['known_hosts'])
        self.assertEqual(moved['core'], inventory['core'])
        with self.assertRaises(ValueError): node_inventory.check_replacement(moved, inventory)
        for bad in ([{'id':'a','host':'other'}],
                    [{'id':'a','host':'core','public_ip':'192.0.2.10'}],
                    [{'id':'a','host':'core'}, {'id':'b','host':'core'}],
                    [{'id':'a', **inventory['core']}], []):
            with self.subTest(edges=bad), self.assertRaises(ValueError):
                node_inventory.validate({**inventory, 'edges':bad})

    def test_invalid_inventory_and_replayed_host_identity_are_rejected(self):
        for field, bad in [('generation', True), ('generation', 0), ('public_ip', '127.0.0.1'),
                           ('public_ip', '10.88.0.5'), ('public_ip', '::1'),
                           ('tunnel_ip', '192.0.2.4'), ('ssh_host_key', key(2) + '\n'),
                           ('ssh_host_key', 'ssh-ed25519 AAAA'), ('admin_secret', 'secret')]:
            value = deepcopy(self.inventory)
            value['edges'][1][field] = bad
            with self.subTest(field=field, bad=bad), self.assertRaises(ValueError):
                node_inventory.validate(value, self.public)
        for field in ('public_ip', 'tunnel_ip', 'ssh_host_key', 'id'):
            value = deepcopy(self.inventory)
            value['edges'][1][field] = value['edges'][0][field]
            with self.assertRaises(ValueError): node_inventory.validate(value, self.public)
        value = deepcopy(self.inventory)
        value['edges'][1]['public_ip'] = '192.0.2.20'
        with self.assertRaises(ValueError): node_inventory.check_replacement(self.inventory, value)
        value['edges'][1]['generation'] = 2
        with self.assertRaises(ValueError): node_inventory.check_replacement(self.inventory, value)
        value['edges'][1]['ssh_host_key'] = key(4)
        with self.assertRaises(ValueError): node_inventory.check_replacement(value, self.inventory)

    def test_cli_fails_before_output_and_never_overwrites_an_existing_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inventory = root / 'inventory.json'
            inventory.write_text(json.dumps(self.inventory))
            output = root / 'edge-c'
            command = [sys.executable, str(ROOT / 'infra/render_edge.py'), '--topology',
                       str(ROOT / 'infra/three-vps.example.json'), '--inventory', str(inventory),
                       '--edge', 'c', '--ingress-ip', '10.241.0.2', '--output', str(output)]
            subprocess.run(command, check=True, capture_output=True)
            original = {path.name:path.read_bytes() for path in output.iterdir()}
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600 for path in output.iterdir()))
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(original, {path.name:path.read_bytes() for path in output.iterdir()})
            self.inventory['edges'][1]['ssh_host_key'] = 'UNVERIFIED'
            inventory.write_text(json.dumps(self.inventory))
            command[-1] = str(root / 'invalid')
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertFalse((root / 'invalid').exists())
        self.inventory['ssh_port'] = 2222
        self.assertTrue(node_inventory.known_host(self.inventory, self.inventory['core']).startswith('[192.0.2.10]:2222 '))
