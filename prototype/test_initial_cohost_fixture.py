import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from check_initial_cohost import remove_units, retain_turn_volumes, inspect_committed_role


class CommittedRoleInspectionTests(unittest.TestCase):
    def test_transient_lock_contention_retries_without_replaying_migration(self):
        with patch('check_initial_cohost.managed_release.inspect_role',
                   side_effect=[BlockingIOError(), {'committed': True}]) as inspect, \
                patch('check_initial_cohost.time.sleep') as sleep:
            self.assertEqual(inspect_committed_role('root', execute='runner'), {'committed': True})
            self.assertEqual(inspect.call_count, 2)
            inspect.assert_called_with('root', execute='runner')
            sleep.assert_called_once_with(.5)

    def test_validation_failure_and_expired_lock_are_preserved(self):
        with patch('check_initial_cohost.managed_release.inspect_role', side_effect=ValueError('invalid')):
            with self.assertRaisesRegex(ValueError, 'invalid'):
                inspect_committed_role('root')
        with patch('check_initial_cohost.managed_release.inspect_role', side_effect=BlockingIOError()), \
                patch('check_initial_cohost.time.monotonic', side_effect=[0, 301]), \
                patch('check_initial_cohost.time.sleep') as sleep:
            with self.assertRaises(BlockingIOError): inspect_committed_role('root')
            sleep.assert_not_called()


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


class ImplicitTurnVolumeCaptureTests(unittest.TestCase):
    def test_capture_before_recreation_deduplicates_only_owned_coturn_mount(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);retained=['a'*64]
            record={'manifest':{'role':'edge'}};model={'name':'voicechat-edge-a'}
            owned={'turn':{'mounts':[{'Destination':'/var/lib/coturn','Name':'b'*64},
                                     {'Destination':'/config','Name':'named-config'}]}}
            with patch('check_initial_cohost.ROOT',root), \
                    patch('check_initial_cohost.edge_deploy.read_state',return_value={'current':record}), \
                    patch('check_initial_cohost.role_deploy.release_path',return_value=root/'release'), \
                    patch('check_initial_cohost.edge_deploy.compose',return_value=json.dumps(model).encode()), \
                    patch('check_initial_cohost.initial_cohost.namespace',return_value=owned) as namespace:
                retain_turn_volumes(root/'edge',retained,run=lambda _:None)
                retain_turn_volumes(root/'edge',retained,run=lambda _:None)
            self.assertEqual(retained,['a'*64,'b'*64])
            self.assertEqual(json.loads((root/'.prototype/initial-cohost-implicit-volumes.json').read_text()),
                             {'schema':1,'volumes':retained})
            self.assertEqual(namespace.call_args.args[:2],('voicechat-edge-a',
                [((root/'release/infra/compose.edge.json',),model)]))

    def test_unknown_named_volume_is_never_registered_for_fixture_removal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);retained=[]
            with patch('check_initial_cohost.ROOT',root), \
                    patch('check_initial_cohost.edge_deploy.read_state',return_value={'current':{'manifest':{}}}), \
                    patch('check_initial_cohost.role_deploy.release_path',return_value=root/'release'), \
                    patch('check_initial_cohost.edge_deploy.compose',return_value=b'{}'), \
                    patch('check_initial_cohost.initial_cohost.namespace',return_value={
                        'turn':{'mounts':[{'Destination':'/var/lib/coturn','Name':'foreign-user-data'}]}}):
                with self.assertRaisesRegex(ValueError,'must be preserved'):
                    retain_turn_volumes(root/'edge',retained,run=lambda _:None)
            self.assertEqual(retained,[])
            self.assertFalse((root/'.prototype/initial-cohost-implicit-volumes.json').exists())


if __name__=='__main__':unittest.main()
