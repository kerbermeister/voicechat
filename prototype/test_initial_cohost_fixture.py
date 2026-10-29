from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from check_initial_cohost import remove_units


class MigrationFixtureCleanupTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        self.units=Path(temporary.name)
        self.expected={'voicechat-core-backup.service':b'owned backup unit',
                       'voicechat-core-backup.timer':b'owned backup timer'}
        for name,raw in self.expected.items():(self.units/name).write_bytes(raw)

    def test_cleanup_disables_timer_but_never_kills_inflight_backup_on_timeout(self):
        calls=[]
        def run(args):
            calls.append(args)
            return b'activating' if args[:2]==['systemctl','show'] else b''
        with patch('check_initial_cohost.Path',return_value=self.units), \
                patch('check_initial_cohost.time.monotonic',side_effect=[0,301]):
            with self.assertRaisesRegex(TimeoutError,'backup still active'):
                remove_units(self.expected,('voicechat-core-backup.timer',),run=run)
        self.assertEqual(calls[0],['systemctl','disable','--now','voicechat-core-backup.timer'])
        self.assertFalse(any(args[:3]==['systemctl','disable','--now'] and
                             args[-1]=='voicechat-core-backup.service' for args in calls))
        for name,raw in self.expected.items():self.assertEqual((self.units/name).read_bytes(),raw)

    def test_foreign_unit_is_refused_before_any_timer_or_service_is_stopped(self):
        name='voicechat-core-backup.timer';(self.units/name).write_bytes(b'foreign timer')
        calls=[]
        with patch('check_initial_cohost.Path',return_value=self.units):
            with self.assertRaisesRegex(ValueError,'Modified fixture unit'):
                remove_units(self.expected,(name,),run=lambda args:calls.append(args))
        self.assertEqual(calls,[])
        self.assertEqual((self.units/name).read_bytes(),b'foreign timer')
        self.assertTrue((self.units/'voicechat-core-backup.service').exists())


if __name__=='__main__':unittest.main()
