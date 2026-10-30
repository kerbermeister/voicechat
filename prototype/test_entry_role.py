from contextlib import nullcontext
from copy import deepcopy
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import core_deploy
import entry_role
import managed_state
import role_deploy
import test_entry_network


class EntryRoleTests(unittest.TestCase):
    def setUp(self):
        test_entry_network.EntryNetworkTests.setUp(self)
        self.role = self.root / 'core'
        self.environment = b'FIXTURE_ONLY=true\nTURN_SECRET=' + b'3' * 64 + b'\nOTHER_SECRET=unchanged\n'
        (self.role / 'runtime/stand.env').write_bytes(self.environment)
        state = core_deploy.read_state(self.role)
        self.manifest = state['current']['manifest']
        state['current']['runtime_sha256'] = core_deploy.runtime_digest(self.role)
        managed_state.persist(self.role / 'state.json', state)
        self.secret = 'f' * 64
        self.health, self.start, self.backup = Mock(), Mock(), Mock()
        for obj, name, value in ((role_deploy, 'network_ready', lambda *a, **k: nullcontext()),
            (core_deploy, 'healthy', self.health), (core_deploy, 'start_configured', self.start),
            (core_deploy, 'backup', self.backup),
            (core_deploy, 'data_identity', lambda *a, **k: state['data_identity'])):
            item = patch.object(obj, name, value); item.start(); self.addCleanup(item.stop)
        self.execute = Mock(return_value=b'')

    run_command = test_entry_network.EntryNetworkTests.run_command

    def apply(self):
        return entry_role.apply(self.role, self.public, self.before['inventory'], self.public,
            self.after, self.manifest, self.manifest, self.attempt, turn_secret=self.secret,
            execute=self.execute)

    def test_rotation_is_forward_only_and_completed_retry_does_not_reconfigure(self):
        result = self.apply()
        self.assertEqual(result['phase'], 'complete')
        self.assertEqual(self.apply(), result)
        self.start.assert_called_once()
        self.backup.assert_called_once()
        self.assertEqual((self.role / 'runtime/stand.env').read_bytes(),
                         self.environment.replace(b'3' * 64, self.secret.encode()))
        state = core_deploy.read_state(self.role)
        self.assertIsNone(state['pending'])
        self.assertEqual(state['current']['runtime_sha256'], core_deploy.runtime_digest(self.role))
        self.assertTrue(role_deploy.in_maintenance(self.role))

    def test_lost_commit_reply_never_replays_successful_configuration(self):
        persist = managed_state.persist
        def lost(path, value):
            if path.name == self.attempt + '.json' and value.get('phase') == 'complete':
                raise InterruptedError('lost final commit reply')
            persist(path, value)
        with patch.object(managed_state, 'persist', side_effect=lost):
            with self.assertRaises(InterruptedError): self.apply()
        self.assertEqual(self.apply()['phase'], 'complete')
        self.start.assert_called_once()
        self.backup.assert_called_once()

    def test_failed_configure_keeps_new_secret_and_owned_pending_fence_for_resume(self):
        self.start.side_effect = RuntimeError('configure failed')
        with self.assertRaises(RuntimeError): self.apply()
        self.assertIn(self.secret.encode(), (self.role / 'runtime/stand.env').read_bytes())
        self.assertEqual(core_deploy.read_state(self.role)['pending']['phase'], 'applying')
        self.assertTrue(role_deploy.in_maintenance(self.role))
        self.start.side_effect = None
        self.assertEqual(self.apply()['phase'], 'complete')
        self.backup.assert_called_once()

    def test_secret_edit_preserves_all_other_bytes_and_rejects_ambiguous_input(self):
        self.assertEqual(entry_role.turn_environment(self.environment, self.secret),
                         self.environment.replace(b'3' * 64, self.secret.encode()))
        for value in (self.environment + b'TURN_SECRET=' + b'4' * 64,
                      self.environment.replace(b'TURN_SECRET=', b'TURN_SECRET ='), b'OTHER=true\n'):
            with self.assertRaises(ValueError): entry_role.turn_environment(value, self.secret)


if __name__ == '__main__': unittest.main()
