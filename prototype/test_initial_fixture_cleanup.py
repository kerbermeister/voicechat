from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import check_initial_cohost


class InitialFixtureCleanupTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        self.units=Path(temporary.name);self.calls=[]
        self.name='voicechat-core.service';self.raw=b'owned synthetic unit\n'
        (self.units/self.name).write_bytes(self.raw)
        actual=Path
        self.enterContext(patch.object(check_initial_cohost,'Path',side_effect=lambda name:
            self.units if str(name)=='/etc/systemd/system' else actual(name)))

    def run_command(self,arguments):
        self.calls.append(arguments)
        return self.state if arguments[:2]==['systemctl','show'] else b''

    def test_inactive_or_unloaded_unit_is_removed_without_failing_reset(self):
        self.state=b'inactive\n'
        check_initial_cohost.remove_units({self.name:self.raw},(),run=self.run_command)
        self.assertFalse((self.units/self.name).exists())
        self.assertFalse(any('reset-failed' in call for call in self.calls))

    def test_only_an_owned_failed_unit_has_its_failure_reset(self):
        self.state=b'failed\n'
        check_initial_cohost.remove_units({self.name:self.raw},(),run=self.run_command)
        self.assertIn(['systemctl','reset-failed',self.name],self.calls)
        self.assertFalse((self.units/self.name).exists())

    def test_modified_unit_is_preserved_before_any_stop(self):
        self.state=b'inactive\n';(self.units/self.name).write_bytes(b'unowned change')
        with self.assertRaisesRegex(ValueError,'Modified fixture unit'):
            check_initial_cohost.remove_units({self.name:self.raw},(),run=self.run_command)
        self.assertTrue((self.units/self.name).exists());self.assertEqual(self.calls,[])
