"""Transactional cap, retired tokens, expiry and crash recovery; no real secrets."""
import tempfile
import unittest
from call_control import CallStore, CallError


class CallControlTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.now = 1000.
        self.rooms = set()
        self.operations = []
        self.fail = False
        self.store = CallStore(self.directory.name + '/calls.sqlite', self.media, lambda: self.now)

    def media(self, method, body):
        self.operations.append((method, body.copy()))
        if self.fail: raise OSError('SFU unavailable')
        if method == 'DeleteRoom': self.rooms.discard(body['room'])
        else: self.rooms.add(body['name'])

    def admit(self, peer, **kwargs):
        return self.store.admission('!room:local', 'call', True,
            {'user_id': '@u'+str(peer)+':local', 'device_id': 'D'}, 'curve', 'ed', **kwargs)

    def join(self, peer):
        with self.assertRaisesRegex(CallError, 'generation_settling'): self.admit(peer)
        self.now += 1
        return self.admit(peer)

    def test_cap_expiry_released_slot_and_old_generation(self):
        admissions = [self.join(peer) for peer in range(10)]
        old = admissions[-1]['generation']
        with self.assertRaisesRegex(CallError, 'call_full'): self.admit(10)
        self.store.leave({'user_id': '@u0:local', 'device_id': 'D'}, admissions[0]['lease_id'])
        self.assertNotIn(old, self.rooms)
        replacement = self.join(10)
        self.assertNotEqual(old, replacement['generation'])
        self.assertEqual(len(replacement['roster']), 10)
        self.assertNotIn('@u0:local/D', [r['identity'] for r in replacement['roster']])
        with self.assertRaisesRegex(CallError, 'lease_expired'):
            self.admit(0, lease=admissions[0]['lease_id'])
        self.now += 31
        self.store.sweep()
        self.assertNotIn(replacement['generation'], self.rooms)
        with self.assertRaisesRegex(CallError, 'lease_expired'):
            self.admit(10, lease=replacement['lease_id'])

    def test_crash_recovery_and_failed_deletion_never_issue_admission(self):
        first = self.join(0)
        self.fail = True
        with self.assertRaises(OSError): self.admit(1)
        with self.store.db() as db:
            self.assertTrue(db.execute('SELECT name FROM retired WHERE name=?', (first['generation'],)).fetchone())
        self.fail = False
        recovered = CallStore(self.store.path, self.media, lambda: self.now)
        recovered.recover()
        self.assertNotIn(first['generation'], self.rooms)
        with recovered.db() as db: self.assertEqual(db.execute('SELECT COUNT(*) FROM leases').fetchone()[0], 0)
        with self.assertRaisesRegex(CallError, 'lease_expired'): self.admit(0, lease=first['lease_id'])

    def test_ownership_mode_key_change_and_reconnect_are_bound(self):
        first = self.join(0)
        with self.assertRaisesRegex(CallError, 'forbidden'):
            self.store.leave({'user_id': '@other:local', 'device_id': 'D'}, first['lease_id'])
        with self.assertRaisesRegex(CallError, 'device_key_changed'):
            self.store.admission('!room:local','call',True,{'user_id':'@u0:local','device_id':'D'},'changed','ed',first['lease_id'])
        with self.assertRaisesRegex(CallError, 'call_mode_changed'):
            self.store.admission('!room:local','call',False,{'user_id':'@u0:local','device_id':'D'},'curve','ed',first['lease_id'])
        with self.assertRaisesRegex(CallError, 'generation_settling'):
            self.admit(0, lease=first['lease_id'], reconnect=first['generation'])
        self.assertNotIn(first['generation'], self.rooms)
        self.now += 1
        current = self.admit(0, lease=first['lease_id'], reconnect=first['generation'])
        self.assertNotEqual(first['generation'], current['generation'])
        self.assertEqual(current['generation'], self.admit(0, lease=first['lease_id'], reconnect=first['generation'])['generation'])

    def test_member_leave_or_device_revocation_prunes_and_rotates(self):
        first = self.join(0)
        second = self.join(1)
        with self.assertRaisesRegex(CallError, 'generation_settling'):
            self.admit(0, lease=first['lease_id'], valid={'@u0:local/D': ('curve','ed')})
        self.assertNotIn(second['generation'], self.rooms)
        self.now += 1
        updated = self.admit(0, lease=first['lease_id'], valid={'@u0:local/D': ('curve','ed')})
        self.assertEqual([r['identity'] for r in updated['roster']], ['@u0:local/D'])
        with self.assertRaisesRegex(CallError, 'lease_expired'): self.admit(1, lease=second['lease_id'])

    def test_an_inflight_check_must_not_remove_a_concurrent_new_join(self):
        first = self.join(0)
        second = self.join(1)
        current = self.admit(0, lease=first['lease_id'], valid={'@u0:local/D': ('curve','ed')}, checked={first['lease_id']})
        self.assertEqual(len(current['roster']), 2)
        self.assertEqual(current['generation'], second['generation'])

    def test_audio_camera_capability_mixed_clients_and_upgrade(self):
        who = {'user_id': '@modern:local', 'device_id': 'D'}
        def admit(**kwargs):
            return self.store.admission('!audio:local', 'audio', False, who, 'curve', 'ed', camera_capable=True, **kwargs)
        with self.assertRaisesRegex(CallError, 'generation_settling'): admit()
        self.now += 1
        modern = admit()
        self.assertTrue(modern['camera_allowed'])
        legacy = {'user_id': '@legacy:local', 'device_id': 'OLD'}
        def old(**kwargs):
            return self.store.admission('!audio:local', 'audio', False, legacy, 'curve', 'ed', **kwargs)
        with self.assertRaisesRegex(CallError, 'generation_settling'): old()
        self.now += 1
        mixed = old()
        self.assertFalse(mixed['camera_allowed'])
        self.assertFalse(admit(lease=modern['lease_id'])['camera_allowed'])
        with self.assertRaisesRegex(CallError, 'generation_settling'):
            old(lease=mixed['lease_id'], camera_capable=True)
        self.now += 1
        upgraded = old(lease=mixed['lease_id'], camera_capable=True)
        self.assertTrue(upgraded['camera_allowed'])
        self.assertNotEqual(upgraded['generation'], mixed['generation'])
        self.store.leave(legacy, upgraded['lease_id'])
        with self.store.db() as db:
            self.assertIsNone(db.execute('SELECT 1 FROM call_camera WHERE lease_id=?', (upgraded['lease_id'],)).fetchone())
            self.assertEqual(len(db.execute('PRAGMA table_info(leases)').fetchall()), 7)


if __name__ == '__main__': unittest.main()
