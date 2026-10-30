from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import legacy_backup
import managed_state


class LegacyBackupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.system = self.base / 'system'; self.units = self.system / 'etc/systemd/system'
        self.units.mkdir(parents=True)
        self.root = self.base / 'legacy'; self.root.mkdir(mode=0o700)
        self.directory = self.base / 'attempt'
        for name, content in legacy_backup._templates(self.root, 'root').items():
            (self.units / name).write_bytes(content)
        self.drop = self.units / (legacy_backup.SERVICE + '.d') / legacy_backup.DROP_IN
        self.enabled, self.active, self.backup = True, True, 'inactive'
        self.calls = []; self.interrupt = None; self.in_flight = False

    def command(self, *args):
        self.calls.append(args)
        if args[:2] == ('systemctl', 'show'):
            service = args[2] == legacy_backup.SERVICE
            value = {'FragmentPath': str(self.units / args[2]),
                'DropInPaths': str(self.drop) if service and self.drop.exists() else '',
                'ActiveState': self.backup if service else ('active' if self.active else 'inactive'),
                'UnitFileState': 'static' if service else ('enabled' if self.enabled else 'disabled')}
            if service: value.update(User='root', Type='oneshot')
            return '\n'.join(key + '=' + item for key, item in value.items())
        if args[:3] == ('systemctl', 'disable', '--now'):
            self.enabled = self.active = False
            if self.in_flight: self.backup = 'activating'
        elif args[:2] == ('systemctl', 'enable'): self.enabled = True
        elif args[:2] == ('systemctl', 'disable'): self.enabled = False
        elif args[:2] == ('systemctl', 'start'): self.active = True
        elif args[:2] == ('systemctl', 'stop'): self.active = False
        if args == self.interrupt: raise SystemExit('Lost systemctl response')
        return ''

    def retire(self):
        return legacy_backup.retire(self.directory, self.root, system_root=self.system, run=self.command)

    def restore(self):
        return legacy_backup.restore(self.directory, self.root, system_root=self.system, run=self.command)

    def test_fence_and_timer_retire_without_stopping_service_or_changing_unit(self):
        before = (self.units / legacy_backup.SERVICE).read_bytes()
        self.assertEqual(self.retire()['phase'], 'retired')
        self.assertEqual(self.retire()['phase'], 'retired')
        self.assertIn('ConditionPathExists=!' + str(self.directory / 'current.json'), self.drop.read_text())
        self.assertFalse(self.enabled or self.active)
        self.assertEqual((self.units / legacy_backup.SERVICE).read_bytes(), before)
        self.assertFalse(any(args[:2] == ('systemctl', 'stop') or legacy_backup.SERVICE in args[1:3] for args in self.calls if args[:2] != ('systemctl', 'show')))
        self.assertEqual(self.restore()['phase'], 'restored')
        self.assertTrue(self.enabled and self.active)
        self.assertFalse(self.drop.exists())
        self.assertEqual(self.restore()['phase'], 'restored')
        with self.assertRaisesRegex(ValueError, 'fresh migration'): self.retire()

    def test_initially_disabled_inactive_timer_is_not_enabled_on_rollback(self):
        self.enabled = self.active = False
        self.retire(); self.restore()
        self.assertFalse(self.enabled or self.active)

    def test_active_backup_is_never_killed_or_claimed_as_retired(self):
        self.backup = 'activating'
        with self.assertRaisesRegex(ValueError, 'Finish the active'): self.retire()
        self.assertFalse((self.directory / 'current.json').exists() or self.drop.exists())
        self.assertFalse(any('disable' in args or 'stop' in args for args in self.calls))

    def test_racing_backup_leaves_fence_for_retry_without_killing_it(self):
        self.in_flight = True
        with self.assertRaisesRegex(ValueError, 'in flight'): self.retire()
        self.assertEqual(managed_state.read(self.directory / 'current.json')['phase'], 'retiring')
        self.assertTrue(self.drop.exists())
        self.assertFalse(self.enabled or self.active)
        self.assertFalse(any('stop' in args for args in self.calls))
        self.in_flight = False; self.backup = 'inactive'
        self.retire(); self.restore()
        self.assertTrue(self.enabled and self.active)

    def test_lost_disable_and_restore_responses_resume_original_timer_state(self):
        self.interrupt = ('systemctl', 'disable', '--now', legacy_backup.TIMER)
        with self.assertRaises(SystemExit): self.retire()
        self.interrupt = None; self.retire()
        self.interrupt = ('systemctl', 'start', legacy_backup.TIMER)
        with self.assertRaises(SystemExit): self.restore()
        self.assertEqual(managed_state.read(self.directory / 'current.json')['phase'], 'restoring')
        self.interrupt = None; self.restore()
        self.assertTrue(self.enabled and self.active)

    def test_unknown_units_dropins_or_journal_are_preserved(self):
        unit = self.units / legacy_backup.SERVICE; before = unit.read_bytes()
        unit.write_bytes(before + b'# foreign\n')
        with self.assertRaisesRegex(ValueError, 'Unknown legacy backup unit'): self.retire()
        self.assertTrue(self.enabled and self.active)
        unit.write_bytes(before)
        self.drop.parent.mkdir(); self.drop.write_text('foreign')
        with self.assertRaisesRegex(ValueError, 'Unknown legacy backup drop-in'): self.retire()
        self.assertEqual(self.drop.read_text(), 'foreign')
        self.drop.unlink(); self.retire()
        journal = managed_state.read(self.directory / 'current.json'); journal['root'] = '/foreign'
        managed_state.persist(self.directory / 'current.json', journal)
        with self.assertRaisesRegex(ValueError, 'same valid'): self.restore()
        self.assertTrue(self.drop.exists())


if __name__ == '__main__': unittest.main()
