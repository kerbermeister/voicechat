from contextlib import nullcontext
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import core_deploy
import managed_state
import role_boot
import role_prepare
import role_release
from test_node_inventory import fixture
from test_tunnel_runtime import state as tunnel_state
from topology import load


class RoleBootTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        directory = Path(self.temporary.name).resolve()
        self.root, self.network = directory / 'core', directory / 'network'
        public = load(ROOT / 'infra/three-vps.example.json')
        manifest = role_release.make(public, fixture(), 'core', 'a' * 40, 'ghcr.io/fixture/control@sha256:' + 'a' * 64)
        role_prepare.prepare(self.root, public, fixture(), manifest)
        (self.root / 'runtime/stand.env').write_text('synthetic-only')
        (self.root / 'runtime/stand.env').chmod(0o600)
        self.record = core_deploy.record_for(self.root, fixture(), manifest)
        self.identity = {'postgres_system_identifier': '123456789', 'signing_sha256': 'f' * 64}
        managed_state.persist(self.root / 'state.json', {'schema': 1, 'current': self.record,
            'previous': None, 'pending': None, 'data_identity': self.identity})
        self.network.mkdir(mode=0o700)
        managed_state.persist(self.network / 'desired.json', {**tunnel_state(), 'edge_subnet': '10.241.0.0/28'})
        self.enterContext(patch.object(role_boot.role_bootstrap, 'ready'))
        self.enterContext(patch.object(role_boot.role_deploy, 'network_ready', return_value=nullcontext()))
        self.data = self.enterContext(patch.object(core_deploy, 'data_identity', return_value=self.identity))
        self.health = self.enterContext(patch.object(core_deploy, 'healthy'))
        self.compose = self.enterContext(patch.object(core_deploy, 'compose'))

    def start(self): return role_boot.start(self.root, 'core', network_directory=self.network)

    def test_healthy_committed_role_is_not_restarted_and_state_is_unchanged(self):
        before = (self.root / 'state.json').read_bytes()
        self.assertEqual(self.start(), self.record)
        self.compose.assert_not_called()
        self.assertEqual((self.root / 'state.json').read_bytes(), before)

    def test_stopped_role_starts_only_after_data_identity_and_network_checks(self):
        self.health.side_effect = [ValueError('stopped'), None]
        self.start()
        self.data.assert_called_once()
        self.assertEqual(self.compose.call_count, 2)
        self.assertTrue(all('up' in call.args and '--no-deps' in call.args for call in self.compose.call_args_list))
        self.assertEqual(self.health.call_count, 2)

    def test_pending_release_missing_or_replaced_data_refuses_any_start(self):
        state = core_deploy.read_state(self.root)
        managed_state.persist(self.root / 'state.json', {**state, 'pending': {'target': self.record, 'phase': 'applying'}})
        with self.assertRaisesRegex(ValueError, 'pending deployment'): self.start()
        self.compose.assert_not_called()
        self.data.assert_not_called()
        managed_state.persist(self.root / 'state.json', state)
        self.data.return_value = {**self.identity, 'postgres_system_identifier': '987654321'}
        with self.assertRaisesRegex(ValueError, 'data identity changed'): self.start()
        self.compose.assert_not_called()
        self.data.side_effect = ValueError('volume is missing')
        with self.assertRaisesRegex(ValueError, 'volume is missing'): self.start()
        self.compose.assert_not_called()

    def test_prepared_image_pull_does_not_prevent_recovery_of_the_committed_role(self):
        state = core_deploy.read_state(self.root)
        managed_state.persist(self.root / 'state.json', {**state, 'pending': {'target': self.record, 'phase': 'prepared'}})
        self.assertEqual(self.start(), self.record)
        self.compose.assert_not_called()
        self.assertEqual(core_deploy.read_state(self.root)['pending']['phase'], 'prepared')

    def test_interrupted_core_backup_refuses_boot_recovery_before_any_start(self):
        managed_state.persist(self.root / 'runtime/backup.json', {'schema': 1, 'phase': 'stopping'})
        with self.assertRaisesRegex(ValueError, 'pending core backup'): self.start()
        self.compose.assert_not_called()
        self.data.assert_not_called()
        self.health.assert_not_called()

    def test_runtime_secret_change_refuses_any_start(self):
        (self.root / 'runtime/stand.env').write_text('changed-secret')
        with self.assertRaisesRegex(ValueError, 'runtime changed'): self.start()
        self.compose.assert_not_called()
        self.data.assert_not_called()


if __name__ == '__main__': unittest.main()
