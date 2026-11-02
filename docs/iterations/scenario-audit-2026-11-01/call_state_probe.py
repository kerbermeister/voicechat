"""Deterministic server state audit; temporary SQLite and synthetic SFU only."""
import concurrent.futures
from pathlib import Path
import random
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'prototype'))
from call_control import CallStore, CallError


class CallStateAudit(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.now = 1000.0
        self.media_rooms = set()
        self.store = CallStore(Path(directory.name) / 'calls.sqlite', self.media, lambda: self.now)

    def media(self, method, body):
        if method == 'DeleteRoom':
            self.media_rooms.discard(body['room'])
        else:
            self.media_rooms.add(body['name'])

    def admit(self, user, room=0, **options):
        return self.store.admission(f'!room{room}:local', 'audit', False,
            {'user_id': f'@qa{user}:local', 'device_id': 'QA'}, 'curve', 'ed', **options)

    def assert_invariants(self):
        with self.store.db() as db:
            leases = db.execute('SELECT * FROM leases').fetchall()
            self.assertEqual(len({r['user_id'] for r in leases}), len(leases))
            self.assertEqual(len({r['identity'] for r in leases}), len(leases))
            for row in db.execute('SELECT call_id,COUNT(*) AS n FROM leases GROUP BY call_id'):
                self.assertLessEqual(row['n'], 10)
            self.assertTrue(all(r['expires'] > self.now for r in leases))
            self.assertEqual(db.execute('SELECT COUNT(*) FROM retired').fetchone()[0], 0)
            generations = {r['generation'] for r in db.execute('SELECT * FROM calls')}
            self.assertTrue(self.media_rooms <= generations)
            cameras = {r['lease_id'] for r in db.execute('SELECT * FROM call_camera')}
            self.assertTrue(cameras <= {r['id'] for r in leases})

    def test_seeded_1000_join_leave_expiry_recovery_transitions(self):
        rng = random.Random(20261101)
        saved = {}
        observed = set()
        for step in range(1000):
            user, room, action = rng.randrange(15), rng.randrange(3), rng.randrange(6)
            observed.add(action)
            try:
                if action in (0, 1):
                    grant = self.admit(user, room, camera_capable=bool(step % 2))
                    saved[user] = (room, grant['lease_id'])
                    self.assertIn(f'@qa{user}:local/QA', [p['identity'] for p in grant['roster']])
                elif action == 2 and user in saved:
                    old_room, lease = saved[user]
                    self.admit(user, old_room, lease=lease, camera_capable=True)
                elif action == 3 and user in saved:
                    self.store.leave({'user_id': f'@qa{user}:local', 'device_id': 'QA'}, saved[user][1])
                elif action == 4:
                    self.now += rng.choice((0.6, 1, 15, 31))
                    self.store.sweep()
                elif action == 5 and step % 23 == 0:
                    self.store.recover()
                    self.assertEqual(self.media_rooms, set())
            except CallError as error:
                self.assertIn(str(error), {'generation_settling', 'answered_elsewhere', 'lease_expired', 'call_full'})
            self.assert_invariants()
        self.assertEqual(observed, set(range(6)))

    def test_twelve_concurrent_admissions_reserve_exactly_ten_slots(self):
        def join(user):
            try:
                self.admit(user)
                return 'admitted'
            except CallError as error:
                return str(error)
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
            outcomes = list(executor.map(join, range(12)))
        self.assertEqual(outcomes.count('generation_settling'), 10)
        self.assertEqual(outcomes.count('call_full'), 2)
        self.now += 1
        self.assertEqual(self.store.active('!room0:local')[0]['participants'], 10)
        self.assert_invariants()
        self.now += 31
        self.assertEqual(self.store.active('!room0:local'), [])
        self.assert_invariants()


if __name__ == '__main__':
    unittest.main(verbosity=2)
