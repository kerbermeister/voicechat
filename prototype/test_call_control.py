"""Transactional cap, retired tokens, expiry and crash recovery; no real secrets."""
import tempfile
import threading
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
        elif method == 'ListRooms': return {'rooms': [{'name': name} for name in self.rooms & set(body['names'])]}
        else: self.rooms.add(body['name'])

    def admit(self, peer, **kwargs):
        return self.store.admission('!room:local', 'call', True,
            {'user_id': '@u'+str(peer)+':local', 'device_id': 'D'}, 'curve', 'ed', **kwargs)

    def join(self, peer):
        with self.assertRaisesRegex(CallError, 'generation_settling'): self.admit(peer)
        self.now += 1
        return self.admit(peer)

    def test_new_room_bounds_native_video_playout_and_preserves_admission_limits(self):
        first = self.join(0)
        self.assertEqual(self.operations[-1], ('CreateRoom', {
            'name': first['generation'], 'max_participants': self.store.limit,
            'empty_timeout': 60, 'departure_timeout': 30,
            'min_playout_delay': 130, 'max_playout_delay': 130,
        }))

    def test_heartbeat_does_not_provision_but_background_repairs_missing_room(self):
        first = self.join(0)
        self.operations.clear()
        for _ in range(10): self.admit(0, lease=first['lease_id'])
        self.assertEqual(self.operations, [])
        # The cache cannot let a foreign device renew someone else's lease.
        with self.assertRaisesRegex(CallError, 'lease_expired'):
            self.admit(1, lease=first['lease_id'])
        self.rooms.clear()
        self.now += 3
        self.store.reconcile()
        self.admit(0, lease=first['lease_id'])
        self.assertIn(first['generation'], self.rooms)
        self.assertEqual([op for op, _ in self.operations], ['ListRooms', 'CreateRoom'])
        second = self.join(1)
        self.assertNotEqual(second['generation'], first['generation'])
        self.assertNotIn(first['generation'], self.rooms)
        self.assertIn(second['generation'], self.rooms)

    def test_read_outage_does_not_break_heartbeat_and_backward_clock_rechecks(self):
        first = self.join(0)
        self.now += 3
        self.fail = True
        self.store.reconcile()
        self.assertEqual(self.admit(0, lease=first['lease_id'])['generation'], first['generation'])
        self.fail = False
        self.rooms.clear()
        self.operations.clear()
        self.now -= 1
        self.store.reconcile()
        self.admit(0, lease=first['lease_id'])
        self.assertEqual([op for op, _ in self.operations], ['ListRooms', 'CreateRoom'])

    def test_failed_provision_is_retried_and_never_cached(self):
        with self.assertRaisesRegex(CallError, 'generation_settling'): self.admit(0)
        self.now += 1
        self.fail = True
        with self.assertRaises(OSError): self.admit(0)
        self.fail = False
        first = self.admit(0)
        self.assertIn(first['generation'], self.rooms)
        self.operations.clear()
        self.admit(0, lease=first['lease_id'])
        self.assertEqual(self.operations, [])

    def test_presence_reads_are_batched_and_expired_leases_are_not_recreated(self):
        first = self.join(0)
        other = {'user_id': '@other:local', 'device_id': 'D'}
        with self.assertRaisesRegex(CallError, 'generation_settling'):
            self.store.admission('!other:local', 'other', False, other, 'curve', 'ed')
        self.now += 1
        second = self.store.admission('!other:local', 'other', False, other, 'curve', 'ed')
        self.operations.clear()
        self.store.reconcile()
        self.store.reconcile()
        self.assertEqual(self.operations, [('ListRooms', {'names': sorted([first['generation'], second['generation']])})])
        self.now += 31
        self.rooms.clear()
        self.operations.clear()
        self.store.reconcile()
        self.assertEqual(self.operations, [])

    def test_inflight_presence_read_cannot_resurrect_retired_generation(self):
        first = self.join(0)
        original = self.store.media_api
        entered, release = threading.Event(), threading.Event()
        def response(method, body):
            if method == 'ListRooms':
                entered.set()
                if not release.wait(3): raise AssertionError('Blocked presence probe')
                return {}
            return original(method, body)
        self.store.media_api = response
        self.operations.clear()
        failures = []
        def reconcile():
            try: self.store.reconcile()
            except Exception as error: failures.append(error)
        worker = threading.Thread(target=reconcile)
        worker.start()
        try:
            self.assertTrue(entered.wait(2))
            # A slow SFU presence read holds neither the lease lock nor expiry worker.
            self.admit(0, lease=first['lease_id'])
            self.store.leave({'user_id': '@u0:local', 'device_id': 'D'}, first['lease_id'])
        finally:
            release.set()
            worker.join(3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(failures, [])
        self.assertNotIn(first['generation'], self.rooms)
        self.assertEqual([op for op, _ in self.operations], ['DeleteRoom'])

    def test_malformed_presence_is_not_missing_room_and_failed_repair_retries(self):
        first = self.join(0)
        original = self.store.media_api
        for invalid in [None, [], {'rooms': {}}, {'rooms': [{'name': []}]},
                        {'rooms': [{'name': 'unknown'}]}, {'rooms': [{}, {}]}]:
            self.store.media_api = lambda *_: invalid
            self.store.reconcile()
            self.now += 3
            self.assertEqual(self.admit(0, lease=first['lease_id'])['generation'], first['generation'])
        def failed_repair(method, body):
            if method == 'ListRooms': return {}
            raise OSError('CreateRoom unavailable')
        self.store.media_api = failed_repair
        self.store.reconcile()
        with self.assertRaises(OSError): self.admit(0, lease=first['lease_id'])
        self.store.media_api = original
        self.rooms.clear()
        self.admit(0, lease=first['lease_id'])
        self.assertIn(first['generation'], self.rooms)

    def test_missing_room_with_pending_expired_member_is_not_recreated(self):
        first = self.join(0)
        second = self.join(1)
        with self.store.db() as db:
            db.execute('UPDATE leases SET expires=? WHERE id=?', (self.now - 1, first['lease_id']))
        self.rooms.clear()
        self.operations.clear()
        self.store.reconcile()
        self.assertEqual([op for op, _ in self.operations], ['ListRooms'])
        self.assertNotIn(second['generation'], self.rooms)
        self.store.sweep()
        self.now += 1
        current = self.admit(1, lease=second['lease_id'])
        self.assertNotEqual(current['generation'], second['generation'])
        self.assertIn(current['generation'], self.rooms)

    def test_discovery_survives_one_departure_and_rejoins_the_same_session(self):
        grants = [self.join(peer) for peer in range(3)]
        self.store.leave({'user_id': '@u0:local', 'device_id': 'D'}, grants[0]['lease_id'])
        expires = [row['expires'] for row in self.store.roster('!room:local', 'call')]
        reopened = CallStore(self.store.path, self.media, lambda: self.now)
        self.assertEqual(reopened.active('!room:local'), [{'session': 'call', 'video': True, 'participants': 2}])
        self.assertEqual(reopened.active('!other:local'), [])
        self.assertEqual([row['expires'] for row in reopened.roster('!room:local', 'call')], expires)
        joined = self.join(0)
        self.assertNotEqual(joined['lease_id'], grants[0]['lease_id'])
        self.assertEqual(self.store.active('!room:local')[0]['participants'], 3)
        self.now += 31
        self.assertEqual(self.store.active('!room:local'), [])

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

    def test_last_departure_between_discovery_and_join_cannot_restart_a_call(self):
        with self.assertRaisesRegex(CallError, 'call_ended'):
            self.admit(1, join_existing=True)
        owner = self.join(0)
        self.assertTrue(self.store.active('!room:local'))
        with self.assertRaisesRegex(CallError, 'generation_settling'):
            self.admit(1, join_existing=True)
        self.now += 1
        peer = self.admit(1, join_existing=True)
        for number, grant in [(0, owner), (1, peer)]:
            self.store.leave({'user_id': '@u'+str(number)+':local', 'device_id': 'D'}, grant['lease_id'])
        with self.assertRaisesRegex(CallError, 'call_ended'):
            self.admit(2, join_existing=True)
        self.assertEqual(self.store.active('!room:local'), [])

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
