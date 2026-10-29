from contextlib import nullcontext
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import core_deploy
import managed_state
import test_core_deploy


class CoreBackupCurrentTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_core_deploy.CoreDeployTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.deploy(self.fixture.old)
        self.root = self.fixture.root
        self.before = (self.root / 'state.json').read_bytes()
        self.path = self.root / 'runtime/backup.json'
        self.events = []
        self.interrupt = None
        self.failed_backup = False
        self.failed_restart = False
        self.fixture.calls.clear()

    def execute(self, args, *, env=None):
        if 'stop' in args:
            self.events.append('stop')
        if 'up' in args:
            self.events.append('resume')
            self.assertEqual(args[-3:], ['postgres', 'synapse', 'control'])
            self.assertIn('--no-deps', args)
            self.assertNotIn('configure', args)
            if self.failed_restart: raise RuntimeError('restart failed')
            self.fixture.running = True
            self.fixture.calls.append(args)
            return b''
        return self.fixture.execute(args, env=env)

    def backup(self, root, record):
        self.events.append('backup')
        self.assertFalse(self.fixture.running)
        self.assertEqual(managed_state.read(self.path)['phase'], 'stopping')
        with self.assertRaises(BlockingIOError):
            with managed_state.locked(self.root): pass
        with self.assertRaisesRegex(ValueError, 'pending core backup'):
            core_deploy.require_no_backup(self.root)
        if self.interrupt == 'backup':
            self.interrupt = None
            raise KeyboardInterrupt('backup process killed')
        if self.failed_backup: raise RuntimeError('backup failed')

    def healthy(self, *args, **kwargs):
        self.fixture.healthy(*args, **kwargs)
        if self.interrupt == 'resuming' and self.events:
            self.interrupt = None
            raise KeyboardInterrupt('recovery process killed')

    def run_backup(self):
        return core_deploy.backup_current(self.root, self.fixture.public, self.fixture.inventory,
            execute=self.execute, check_network=lambda *a, **kw: nullcontext(),
            check_health=self.healthy, create_backup=self.backup,
            check_boot=lambda *a: None, identify_data=lambda *a, **kw: self.fixture.data_identity.copy(),
            activate_monitor=lambda *a: self.events.append('monitor'))

    def test_stopped_writers_backup_resumes_exact_current_without_pointer_changes(self):
        self.run_backup()
        self.assertEqual(self.events, ['stop', 'backup', 'resume', 'monitor'])
        self.assertFalse(self.path.exists())
        self.assertEqual((self.root / 'state.json').read_bytes(), self.before)
        self.assertFalse(any('pg_restore' in args or 'down' in args for args in self.fixture.calls))

    def test_registry_failure_before_maintenance_does_not_stop_writers(self):
        execute = self.execute
        def unavailable(args, **kwargs):
            if args[:2] == ['docker', 'pull']: raise RuntimeError('registry unavailable')
            return execute(args, **kwargs)
        self.execute = unavailable
        with self.assertRaisesRegex(RuntimeError, 'registry unavailable'): self.run_backup()
        self.assertEqual(self.events, ['monitor'])
        self.assertTrue(self.fixture.running)
        self.assertFalse(self.path.exists())
        self.assertEqual((self.root / 'state.json').read_bytes(), self.before)

    def test_backup_failure_resumes_availability_and_reports_failure(self):
        self.failed_backup = True
        with self.assertRaisesRegex(RuntimeError, 'backup failed'): self.run_backup()
        self.assertEqual(self.events, ['stop', 'backup', 'resume', 'monitor'])
        self.assertTrue(self.fixture.running)
        self.assertFalse(self.path.exists())
        self.assertEqual((self.root / 'state.json').read_bytes(), self.before)

    def test_process_death_repeats_incomplete_backup_but_only_resumes_completed_backup(self):
        self.interrupt = 'backup'
        with self.assertRaises(KeyboardInterrupt): self.run_backup()
        self.assertEqual(self.events, ['stop', 'backup'])
        self.assertFalse(self.fixture.running)
        self.assertEqual(managed_state.read(self.path)['phase'], 'stopping')
        self.events.clear()
        self.interrupt = 'resuming'
        with self.assertRaises(KeyboardInterrupt): self.run_backup()
        self.assertEqual(self.events, ['stop', 'backup', 'resume'])
        self.assertTrue(managed_state.read(self.path)['succeeded'])
        self.events.clear()
        self.run_backup()
        self.assertEqual(self.events, ['resume', 'monitor'])
        self.assertEqual((self.root / 'state.json').read_bytes(), self.before)

    def test_failed_backup_and_restart_remain_fenced_until_recovery(self):
        self.failed_backup = self.failed_restart = True
        with self.assertRaisesRegex(RuntimeError, 'restart failed'): self.run_backup()
        self.assertFalse(managed_state.read(self.path)['succeeded'])
        self.assertNotIn('monitor', self.events)
        self.failed_restart = False
        self.events.clear()
        with self.assertRaisesRegex(RuntimeError, 'Interrupted failed backup recovered'): self.run_backup()
        self.assertEqual(self.events, ['resume', 'monitor'])
        self.assertFalse(self.path.exists())

    def test_pending_deploy_or_changed_runtime_cannot_stop_writers(self):
        state = core_deploy.read_state(self.root)
        managed_state.persist(self.root / 'state.json', {**state,
            'pending': {'target': state['current'], 'phase': 'prepared'}})
        with self.assertRaisesRegex(ValueError, 'without pending deployment'): self.run_backup()
        self.assertNotIn('stop', self.events)
        managed_state.persist(self.root / 'state.json', state)
        (self.root / 'runtime/stand.env').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'runtime changed'): self.run_backup()
        self.assertNotIn('stop', self.events)

    def test_changed_data_after_snapshot_cannot_resume_writers(self):
        backup = self.backup
        def replace_data(root, record):
            backup(root, record)
            self.fixture.data_identity['postgres_system_identifier'] = '987654321'
        self.backup = replace_data
        with self.assertRaisesRegex(ValueError, 'identity changed during backup'): self.run_backup()
        self.assertEqual(self.events, ['stop', 'backup'])
        self.assertFalse(self.fixture.running)
        self.assertTrue(managed_state.read(self.path)['succeeded'])
        self.assertEqual((self.root / 'state.json').read_bytes(), self.before)

    def test_backup_intent_cannot_be_adopted_by_changed_data_or_release(self):
        self.interrupt = 'backup'
        with self.assertRaises(KeyboardInterrupt): self.run_backup()
        intent = managed_state.read(self.path)
        managed_state.persist(self.path, {**intent, 'core_sha256': '0' * 64})
        self.events.clear()
        with self.assertRaisesRegex(ValueError, 'same valid core backup'): self.run_backup()
        self.assertEqual(self.events, [])
        self.assertTrue(self.path.exists())
        with self.assertRaisesRegex(ValueError, 'pending core backup'): self.fixture.deploy(self.fixture.new)
        self.assertEqual((self.root / 'state.json').read_bytes(), self.before)


if __name__ == '__main__': unittest.main()
