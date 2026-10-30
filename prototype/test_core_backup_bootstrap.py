from contextlib import nullcontext
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import core_backup_bootstrap
import core_deploy
import managed_state
import role_bootstrap
import test_core_deploy


class CoreBackupInstallationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_core_deploy.CoreDeployTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.deploy(self.fixture.old)
        self.root = self.fixture.root
        self.system = self.root.parent / 'host'
        self.system.mkdir()
        self.calls = []
        self.legacy_active = False
        self.interrupt = False
        role_bootstrap.install(self.root, 'core', system_root=self.system, run=self.command)
        self.calls.clear()
        self.directory = self.root / 'runtime/backup-boot'

    def command(self, *args):
        self.calls.append(args)
        if args[:2] == ('systemctl', 'show'):
            return 'active' if self.legacy_active else 'inactive'
        if self.interrupt and args[:3] == ('systemctl', 'enable', '--now'):
            raise RuntimeError('Interrupted timer enable')
        return ''

    def install(self, **kwargs):
        return core_backup_bootstrap.install(self.root, self.fixture.public, self.fixture.inventory,
            system_root=self.system, run=self.command, **kwargs)

    def test_owned_timer_uses_committed_operator_and_never_calls_legacy_deploy(self):
        before = (self.root / 'state.json').read_bytes()
        target = self.install()
        service = (self.system / 'etc/systemd/system' / core_backup_bootstrap.SERVICE).read_text()
        self.assertIn('--backup-only', service)
        self.assertIn(target['operator']['operator_sha256'], service)
        self.assertIn('Restart=on-failure', service)
        self.assertNotIn('/deploy.py', service)
        self.assertNotIn('Requires=voicechat-core.service', service)
        self.assertEqual((self.root / 'state.json').read_bytes(), before)
        self.assertEqual(self.install(), target)
        self.assertFalse((self.directory / 'pending.json').exists())
        self.assertEqual(managed_state.read(self.directory / 'topology.json'), self.fixture.public)
        self.assertFalse(any('restart' in args or 'stop' in args for args in self.calls))

    def test_active_legacy_scheduler_is_not_changed_or_adopted(self):
        self.legacy_active = True
        with self.assertRaisesRegex(ValueError, 'Retire the legacy'): self.install()
        self.assertFalse(self.directory.exists())
        self.assertFalse(any('disable' in args or 'stop' in args for args in self.calls))

    def test_interrupted_timer_install_blocks_backup_and_resumes_same_target(self):
        self.interrupt = True
        with self.assertRaisesRegex(RuntimeError, 'Interrupted timer'): self.install()
        self.assertTrue((self.directory / 'pending.json').exists())
        with self.assertRaisesRegex(ValueError, 'pending core backup timer'):
            core_deploy.backup_current(self.root, self.fixture.public, self.fixture.inventory,
                check_network=lambda *a, **kw: nullcontext(), check_boot=lambda *a: None,
                activate_monitor=lambda *a: None)
        self.interrupt = False
        self.install()
        self.assertFalse((self.directory / 'pending.json').exists())

    def test_foreign_unit_and_modified_config_are_never_overwritten(self):
        service = self.system / 'etc/systemd/system' / core_backup_bootstrap.SERVICE
        service.write_text('foreign')
        with self.assertRaisesRegex(ValueError, 'unclaimed'): self.install()
        self.assertEqual(service.read_text(), 'foreign')
        service.unlink()
        self.install()
        config = self.directory / 'topology.json'
        managed_state.persist(config, {'foreign': True})
        with self.assertRaisesRegex(ValueError, 'Unknown core backup configuration'): self.install()
        self.assertEqual(managed_state.read(config), {'foreign': True})

    def test_post_commit_crash_finishes_same_installation(self):
        persist = managed_state.persist
        def interrupted(path, value):
            persist(path, value)
            if path == self.directory / 'current.json': raise SystemExit('Lost commit response')
        with patch.object(managed_state, 'persist', side_effect=interrupted):
            with self.assertRaises(SystemExit): self.install()
        target = managed_state.read(self.directory / 'current.json')
        self.assertEqual(self.install(), target)
        self.assertFalse((self.directory / 'pending.json').exists())

    def test_systemd_subnet_injection_is_rejected_before_installing_units(self):
        with self.assertRaises(ValueError): self.install(subnet='10.241.0.0/28\nExecStart=/bin/false')
        self.assertFalse((self.system / 'etc/systemd/system' / core_backup_bootstrap.SERVICE).exists())


if __name__ == '__main__': unittest.main()
