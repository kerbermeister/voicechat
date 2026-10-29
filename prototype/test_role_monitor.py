from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import role_boot
import role_bootstrap


class RoleMonitorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.start = self.enterContext(patch.object(role_boot, 'start', return_value={'manifest': {}}))
        self.compose = self.enterContext(patch.object(role_boot.core_deploy, 'compose', return_value=b'pg\nsynapse\ncontrol\n'))
        self.notify = self.enterContext(patch.object(role_boot, 'notify_ready'))
        self.waiter = Mock()
        self.waiter.poll.return_value = 0
        self.process = self.enterContext(patch.object(role_boot.subprocess, 'Popen', return_value=self.waiter))
        self.state = self.enterContext(patch.object(role_boot.core_deploy, 'read_state', return_value={'pending': None}))

    def test_unexpected_container_exit_requests_restart_and_notifies_only_after_start(self):
        self.assertEqual(role_boot.watch(self.root, 'core'), 1)
        self.start.assert_called_once()
        self.notify.assert_called_once()
        self.assertEqual(self.process.call_count, 3)
        self.assertTrue(all(call.args[0][:2] == ['docker', 'wait'] for call in self.process.call_args_list))

    def test_maintenance_exit_does_not_restart_or_race_backup(self):
        for phase in ('stopping', 'backed-up', 'applying', 'rollback'):
            self.state.return_value = {'pending': {'phase': phase}}
            self.assertEqual(role_boot.watch(self.root, 'core'), 0)
        self.state.return_value = {'pending': {'phase': 'prepared'}}
        self.assertEqual(role_boot.watch(self.root, 'core'), 1)

    def test_core_backup_is_planned_maintenance_without_deployment_pointer_changes(self):
        (self.root / 'runtime').mkdir(mode=0o700)
        managed_state.persist(self.root / 'runtime/backup.json', {'phase': 'stopping'})
        self.assertEqual(role_boot.watch(self.root, 'core'), 0)
        self.state.assert_not_called()
        self.assertEqual(self.process.call_count, 3)
        self.waiter.terminate.assert_not_called()

    def test_shared_edge_monitor_does_not_control_the_shared_listener(self):
        record = {'manifest': {'images': dict.fromkeys(('configure', 'web', 'turn', 'route-health'))}}
        self.start.return_value = record
        with patch.object(role_boot.edge_deploy, 'compose', return_value=b'health\nweb\nturn\n') as compose, \
                patch.object(role_boot.edge_deploy, 'read_state', return_value={'pending': None}):
            self.assertEqual(role_boot.watch(self.root, 'edge', 'a'), 1)
        self.assertEqual(compose.call_args.args[2:], ('ps', '-q', 'route-health', 'web', 'turn'))
        self.assertEqual(self.process.call_count, 3)

    def test_monitor_is_reactivated_after_locks_are_released_and_skips_partial_apply(self):
        managed_state.persist(self.root / 'state.json', {'current': {}, 'pending': None})
        calls = []
        def activate(*args):
            with managed_state.locked(self.root): calls.append('active')
        with role_bootstrap.monitor_after(self.root, 'core', activate=activate), managed_state.locked(self.root):
            pass
        self.assertEqual(calls, ['active'])
        managed_state.persist(self.root / 'state.json', {'current': {}, 'pending': {'phase': 'applying'}})
        with role_bootstrap.monitor_after(self.root, 'core', activate=activate): pass
        self.assertEqual(calls, ['active'])

    def test_activation_failure_preserves_original_deployment_error(self):
        managed_state.persist(self.root / 'state.json', {'current': {}, 'pending': None})
        def failure(*args): raise RuntimeError('monitor failure')
        with self.assertRaisesRegex(ValueError, 'original') as caught:
            with role_bootstrap.monitor_after(self.root, 'core', activate=failure):
                raise ValueError('original deployment failure')
        self.assertTrue(any('monitor' in note for note in caught.exception.__notes__))


if __name__ == '__main__': unittest.main()
