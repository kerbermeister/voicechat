from copy import deepcopy
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import entry_lifecycle
import role_release
import topology
from test_node_inventory import fixture, key


class EntryLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.public = topology.load(ROOT / 'infra/three-vps.example.json')
        self.inventory = fixture()
        self.image = 'ghcr.io/example/web@sha256:' + 'b' * 64
        self.baseline = {'schema': 2, 'backend': 'a' * 64, 'core_guard': 'c' * 64,
            'public': self.public, 'inventory': self.inventory, 'subnet': '10.241.0.0/28',
            'core': role_release.make(self.public, self.inventory, 'core', '1' * 40,
                                      'ghcr.io/example/control@sha256:' + 'a' * 64),
            'edges': {edge['id']: role_release.make(self.public, self.inventory, 'edge',
                '1' * 40, self.image, edge['id']) for edge in self.public['edges']}}
        self.after = deepcopy(self.inventory)
        self.after['edges'][1].update(generation=2, public_ip='192.0.2.20', ssh_host_key=key(4))

    def plan(self, public=None):
        return entry_lifecycle.plan(self.baseline, public or self.public, self.after, '2' * 40, self.image)

    def test_replacement_preserves_unaffected_manifests_and_requires_global_turn_rotation(self):
        saved = deepcopy(self.baseline)
        value = self.plan()
        self.assertEqual(value['operation'], 'replace')
        self.assertEqual(value['node'], 'edge-c')
        self.assertEqual(value['surviving_edges'], ['b'])
        self.assertEqual(value['reconfigure'], [])
        self.assertTrue(value['rotate_turn_secret'])
        self.assertEqual(value['target']['core'], self.baseline['core'])
        self.assertEqual(value['target']['edges']['b'], self.baseline['edges']['b'])
        self.assertNotEqual(value['target']['edges']['c'], self.baseline['edges']['c'])
        self.assertEqual(self.baseline, saved)

    def test_addition_reconfigures_only_roles_whose_public_inputs_changed(self):
        self.after = deepcopy(self.inventory)
        self.after['edges'].append({'id': 'd', 'generation': 1, 'public_ip': '192.0.2.14',
                                   'tunnel_ip': '10.88.0.4', 'ssh_host_key': key(4)})
        public = deepcopy(self.public)
        public['edges'].append({'id': 'd', 'origin': 'https://d.example.com', 'turn_host': 'turn-d.example.com'})
        value = self.plan(public)
        self.assertEqual(value['operation'], 'add')
        self.assertFalse(value['rotate_turn_secret'])
        self.assertEqual(value['reconfigure'], ['core', 'edge-b', 'edge-c'])
        self.assertEqual(value['target']['edges']['d']['images']['web'], self.image)

    def test_rejects_unrelated_changes_before_any_execution(self):
        for kind in ('core', 'other', 'key', 'address', 'image', 'public'):
            with self.subTest(kind=kind):
                after, image, public = deepcopy(self.after), self.image, deepcopy(self.public)
                if kind == 'core': self.after['core']['public_ip'] = '192.0.2.30'
                if kind == 'other': self.after['edges'][0].update(generation=2, ssh_host_key=key(5))
                if kind == 'key': self.after['edges'][1]['ssh_host_key'] = self.inventory['edges'][1]['ssh_host_key']
                if kind == 'address': self.after['edges'][1]['tunnel_ip'] = '10.88.0.30'
                if kind == 'image': self.image = 'ghcr.io/example/web@sha256:' + 'f' * 64
                if kind == 'public': public['edges'][0]['origin'] = 'https://other.example.com'
                with self.assertRaises(ValueError): self.plan(public)
                self.after, self.image = after, image


if __name__ == '__main__':
    unittest.main()
