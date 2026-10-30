import base64
from copy import deepcopy
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import host_registration
from test_node_inventory import fixture, key


def public(number):
    return base64.b64encode(bytes([number]) * 32).decode()


class HostRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.before = fixture()
        self.keys = {'schema': 1, 'service_id': self.before['service_id'], 'nodes': {
            'core': {'generation': 1, 'public_key': public(1)},
            'edge-b': {'generation': 1, 'public_key': public(2)},
            'edge-c': {'generation': 1, 'public_key': public(3)}}}
        self.after = deepcopy(self.before)
        self.after['edges'].append({'id': 'd', 'generation': 1, 'public_ip': '192.0.2.14',
                                   'tunnel_ip': '10.88.0.4', 'ssh_host_key': key(4)})
        self.identity = {'schema': 1, 'service_id': self.before['service_id'], 'node': 'edge-d',
                         'generation': 1, 'public_key': public(4)}

    def register(self):
        return host_registration.registry(self.before, self.after, self.keys, self.identity)

    def test_add_preserves_existing_keys_and_inputs_without_contacting_any_host(self):
        saved = deepcopy((self.before, self.after, self.keys, self.identity))
        result = self.register()
        self.assertEqual(result['nodes']['edge-d'], {'generation': 1, 'public_key': public(4)})
        for name, value in self.keys['nodes'].items(): self.assertEqual(result['nodes'][name], value)
        self.assertEqual((self.before, self.after, self.keys, self.identity), saved)

    def test_replacement_needs_new_host_generation_and_both_fresh_ssh_and_tunnel_keys(self):
        self.after = deepcopy(self.before)
        self.after['edges'][0].update(public_ip='192.0.2.20', ssh_host_key=key(4), generation=2)
        self.identity.update(node='edge-b', generation=2)
        result = self.register()
        self.assertEqual(result['nodes']['edge-b']['generation'], 2)
        self.identity['public_key'] = public(2)
        with self.assertRaisesRegex(ValueError, 'fresh'): self.register()
        self.identity['public_key'] = public(4)
        self.after['edges'][0]['generation'] = 1
        with self.assertRaises(ValueError): self.register()

    def test_foreign_or_stale_ssh_returned_identity_cannot_enter_registry(self):
        for change in ({'node': 'edge-c'}, {'generation': True}, {'generation': 2},
                       {'service_id': 'other'}, {'public_key': public(1)}, {'public_key': 'invalid'}):
            original = self.identity
            self.identity = {**original, **change}
            with self.subTest(change=change), self.assertRaises(ValueError): self.register()
            self.identity = original

    def test_no_bulk_core_retirement_or_unrelated_logical_change(self):
        candidate = deepcopy(self.after)
        for change in ('core', 'two', 'remove', 'none'):
            self.after = deepcopy(candidate)
            if change == 'core': self.after['core']['generation'] = 2
            elif change == 'two': self.after['edges'][0].update(generation=2, ssh_host_key=key(5))
            elif change == 'remove': self.after['edges'].pop(0)
            else: self.after = deepcopy(self.before)
            with self.subTest(change=change), self.assertRaises(ValueError): self.register()

    def test_shared_core_expands_with_a_dedicated_entry_without_rotating_core_key(self):
        self.before['edges'] = [{'id': 'a', 'host': 'core'}]
        self.keys['nodes'] = {'core': self.keys['nodes']['core']}
        self.after = deepcopy(self.before)
        self.after['edges'].append({'id': 'd', 'generation': 1, 'public_ip': '192.0.2.14',
                                   'tunnel_ip': '10.88.0.4', 'ssh_host_key': key(4)})
        self.assertEqual(self.register()['nodes']['core'], self.keys['nodes']['core'])

    def test_unrelated_cohost_options_cannot_change_during_registration(self):
        self.before['edges'] = [{'id': 'a', 'host': 'core'}]
        self.keys['nodes'] = {'core': self.keys['nodes']['core']}
        dedicated = deepcopy(self.after['edges'][-1])
        self.after = deepcopy(self.before)
        self.after['edges'][0]['legacy_turn'] = True
        self.after['edges'].append(dedicated)
        with self.assertRaisesRegex(ValueError, 'Unrelated'):
            self.register()


if __name__ == '__main__':
    unittest.main()
