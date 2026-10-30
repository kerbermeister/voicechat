from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import host_identity
import host_packages
import managed_state
from test_node_inventory import fixture


class HostIdentityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.state = Path(temporary.name) / 'state'
        self.state.mkdir(mode=0o700)
        self.inventory = fixture()
        managed_state.persist(self.state / 'current.json', host_packages.binding(self.inventory, 'edge-b'))
        self.enterContext(patch.object(host_packages, 'inspect_identity'))

    def initialize(self):
        return host_identity.initialize(self.state, self.inventory, 'edge-b')

    def test_repeat_keeps_private_key_and_only_returns_public_fragment(self):
        first = self.initialize()
        private = (self.state / 'network.key').read_bytes()
        self.assertEqual(first, self.initialize())
        self.assertEqual(private, (self.state / 'network.key').read_bytes())
        self.assertEqual(set(first), {'schema', 'service_id', 'node', 'generation', 'public_key'})
        self.assertNotIn(private.decode().strip(), str(first))
        self.assertEqual((self.state / 'network.key').stat().st_mode & 0o777, 0o600)

    def test_lost_commit_resumes_same_key_without_regeneration(self):
        persist = managed_state.persist
        def fail_receipt(path, value):
            if path.name == 'identity.json': raise RuntimeError('Interrupted identity commit')
            persist(path, value)
        with patch.object(managed_state, 'persist', side_effect=fail_receipt):
            with self.assertRaises(RuntimeError): self.initialize()
        private = (self.state / 'network.key').read_bytes()
        self.initialize()
        self.assertEqual(private, (self.state / 'network.key').read_bytes())

    def test_missing_committed_key_is_not_regenerated(self):
        self.initialize()
        key = self.state / 'network.key'
        key.unlink()
        with self.assertRaises(FileNotFoundError): self.initialize()
        self.assertFalse(key.exists())

    def test_rejects_unclaimed_key_incomplete_packages_and_changed_assignment(self):
        (self.state / 'network.key').write_text('preserve unclaimed fixture')
        with self.assertRaisesRegex(ValueError, 'unclaimed'): self.initialize()
        (self.state / 'network.key').unlink()
        managed_state.persist(self.state / 'pending.json', {})
        with self.assertRaisesRegex(ValueError, 'preparation'): self.initialize()
        (self.state / 'pending.json').unlink()
        self.initialize()
        self.inventory['edges'][0]['generation'] += 1
        with self.assertRaisesRegex(ValueError, 'preparation'): self.initialize()

    def test_changed_receipt_and_private_file_symlink_are_refused(self):
        self.initialize()
        receipt = managed_state.read(self.state / 'identity.json')
        managed_state.persist(self.state / 'identity.json', {**receipt, 'public_key': 'foreign'})
        with self.assertRaisesRegex(ValueError, 'changed'): self.initialize()
        key = self.state / 'network.key';key.rename(self.state / 'preserved.key')
        key.symlink_to('preserved.key')
        with self.assertRaises(OSError): self.initialize()


if __name__ == '__main__':
    unittest.main()
