from copy import deepcopy
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import entry_peer
import entry_lifecycle
import test_entry_lifecycle


class EntryPeerTests(unittest.TestCase):
    def setUp(self):
        fixture = test_entry_lifecycle.EntryLifecycleTests(); fixture.setUp()
        plan = fixture.plan()
        self.value = {'schema': 1, 'action': 'stage', 'attempt': 'e' * 64, 'node': 'edge-c',
            'before_public': fixture.public, 'previous_inventory': fixture.inventory,
            'public': fixture.public, 'inventory': fixture.after, 'before': None,
            'target': plan['target']['edges']['c'], 'core': plan['target']['core'],
            'subnet': plan['target']['subnet'], 'extra': {}}

    def request(self): return entry_peer.request(json.dumps(self.value).encode())

    def test_request_is_bound_to_exact_new_generation_and_physical_role(self):
        self.assertEqual(self.request(), self.value)
        self.value['node'] = 'core'
        with self.assertRaisesRegex(ValueError, 'another physical'): self.request()

    def test_unknown_actions_extra_fields_and_oversized_payloads_are_rejected(self):
        original = deepcopy(self.value)
        for change in ({'action': 'shell'}, {'attempt': True}, {'extra': {'command': 'ignored'}}, {'schema': True}):
            self.value = {**original, **change}
            with self.assertRaises(ValueError): self.request()
        with self.assertRaises(ValueError): entry_peer.request(b'x' * (entry_peer.MAX_INPUT + 1))

    def test_surviving_claim_needs_original_manifest_not_the_replacement_host(self):
        self.value['action'] = 'claim'
        with self.assertRaisesRegex(ValueError, 'committed baseline'): self.request()

    def test_ambiguous_json_cannot_shadow_operation_or_trust_inputs(self):
        raw = json.dumps(self.value).encode()
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            entry_peer.request(b'{"schema":1,' + raw[1:])


if __name__ == '__main__': unittest.main()
