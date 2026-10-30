from copy import deepcopy
import json
import io
from pathlib import Path
import sys
import unittest
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import entry_peer
import entry_core
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

    def operate(self, root):
        target = self.value['target']; sha = 'f' * 64
        host = next(edge for edge in self.value['inventory']['edges'] if edge['id'] == 'c')['ssh_host_key']
        verified = SimpleNamespace(topology=self.value['public'], revision=2)
        with patch.object(entry_peer, '__file__', str(root / 'bundles' / sha / 'infra/entry_peer.py')), \
                patch.object(entry_peer.platform, 'system', return_value='Linux'), \
                patch.object(entry_peer, 'os', SimpleNamespace(geteuid=lambda: 0, environ={})), \
                patch.object(entry_peer.managed_journal, '_delivery', return_value={'manifest': {
                    'commit': target['commit'], 'web': target['images']['web']}}), \
                patch.object(entry_peer.network_bootstrap, 'existing', return_value=host.encode()), \
                patch.object(entry_peer.role_deploy, 'run', return_value=b'unix:///var/run/docker.sock'), \
                patch.object(entry_peer.role_bootstrap, 'install'), \
                patch.object(entry_peer.route_catalog, 'verify', return_value=verified), \
                patch.object(entry_peer.publish_catalog, 'publish', return_value=verified), \
                patch.object(entry_peer.tls_runtime, 'publish'):
            return entry_peer.operate(self.value, root, sha)

    def test_clean_host_stage_and_material_create_owned_edges_parent(self):
        for action in ('stage', 'material'):
            with self.subTest(action=action), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(); self.value['action'] = action
                self.value['extra'] = {} if action == 'stage' else {
                    'turn_secret': 'a' * 64, 'web_chain': 'synthetic', 'web_key': 'synthetic',
                    'turn_chain': 'synthetic', 'turn_key': 'synthetic', 'catalog': '{}', 'catalog_key': 'public'}
                self.operate(root)
                parent = root / 'edges'
                self.assertEqual(parent.stat().st_mode & 0o777, 0o700)
                self.assertTrue((parent / 'c/role.json').is_file())
                if action == 'material':
                    self.assertEqual((parent / 'c/runtime/turn-secret').read_text(), 'a' * 64)

    def test_new_host_does_not_follow_foreign_edges_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); foreign = root / 'foreign'; foreign.mkdir()
            (root / 'edges').symlink_to(foreign, target_is_directory=True)
            with self.assertRaises(ValueError): self.operate(root)
            self.assertEqual(list(foreign.iterdir()), [])

    def test_peer_and_coordinator_report_lock_contention_as_retryable(self):
        for module in (entry_peer, entry_core):
            with self.subTest(module=module.__name__), \
                    patch.object(module.sys, 'argv', ['entry', '--root', '/srv/test', '--source-sha', 'f' * 64]), \
                    patch.object(module.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(b'{}'))), \
                    patch.object(module.sys, 'stderr', io.StringIO()) as errors, \
                    patch.object(module, 'request', return_value={}), \
                    patch.object(module, 'operate', side_effect=BlockingIOError()):
                with self.assertRaises(SystemExit) as exit_result: module.main()
                self.assertEqual(exit_result.exception.code, 75)
                self.assertIn('busy', errors.getvalue())
                self.assertNotIn('Traceback', errors.getvalue())

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
