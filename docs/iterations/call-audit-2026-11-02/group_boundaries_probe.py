"""Compound group call boundaries; real SQLite, synthetic SFU, no accounts."""
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'prototype'))
from call_control import CallStore, CallError
class GroupBoundaries(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.now = 1000.0; self.deleted = []
        self.store = CallStore(Path(temp.name)/'calls.sqlite', lambda method, body: self.deleted.append(body['room']) if method == 'DeleteRoom' else None, lambda: self.now)
    def who(self, user, device='A'): return {'user_id': '@'+user+':qa', 'device_id': device}
    def admit(self, user, room='one', device='A', **kw):
        return self.store.admission('!'+room+':qa', 'session', False, self.who(user,device), 'curve', 'ed', **kw)
    def stable(self, user, **kw):
        for _ in range(4):
            try: return self.admit(user, **kw)
            except CallError as error:
                if str(error) != 'generation_settling': raise
                self.now += .7
        self.fail('generation never settled')
    def test_two_rooms_expiry_rotates_only_affected_room(self):
        a = self.stable('a'); b = self.stable('b',room='two')
        self.now += 20; b = self.stable('b',room='two',lease=b['lease_id'])
        self.now += 11; self.store.sweep()
        self.assertEqual(self.store.active('!one:qa'), [])
        new_b = self.stable('b',room='two',lease=b['lease_id'])
        self.assertEqual(b['generation'], new_b['generation'])
        self.assertNotIn(b['generation'], self.deleted)
    def test_second_device_denied_then_can_join_after_explicit_leave(self):
        a = self.stable('a')
        with self.assertRaisesRegex(CallError,'answered_elsewhere'): self.admit('a',device='B')
        self.store.leave(self.who('a'),a['lease_id'])
        b = self.stable('a',device='B')
        self.assertEqual(b['identity'],'@a:qa/B'); self.assertNotEqual(a['lease_id'],b['lease_id'])
        with self.assertRaisesRegex(CallError,'lease_expired'): self.admit('a',lease=a['lease_id'])
    def test_lost_leave_retry_does_not_close_new_device_call(self):
        a = self.stable('a'); self.store.leave(self.who('a'),a['lease_id'])
        b = self.stable('a',device='B')
        self.store.leave(self.who('a'),a['lease_id'])
        again = self.stable('a',device='B',lease=b['lease_id'])
        self.assertEqual(b['generation'],again['generation'])
        self.assertEqual(self.store.active('!one:qa')[0]['participants'],1)
    def test_foreign_leave_and_cross_room_lease_cannot_remove_owner(self):
        a = self.stable('a'); self.stable('b',room='two')
        with self.assertRaisesRegex(CallError,'forbidden'): self.store.leave(self.who('b'),a['lease_id'])
        with self.assertRaisesRegex(CallError,'lease_expired'): self.admit('a',room='two',lease=a['lease_id'])
        self.assertEqual(self.store.active('!one:qa')[0]['participants'],1)
        self.assertEqual(self.store.active('!two:qa')[0]['participants'],1)
    def test_old_client_leaves_camera_capability_recovers_without_new_session(self):
        a = self.stable('a',camera_capable=True)
        self.assertTrue(a['camera_allowed'])
        b = self.stable('b',camera_capable=False)
        a = self.stable('a',lease=a['lease_id'],camera_capable=True)
        self.assertFalse(a['camera_allowed'])
        self.store.leave(self.who('b'),b['lease_id'])
        final = self.stable('a',lease=a['lease_id'],camera_capable=True)
        self.assertTrue(final['camera_allowed']); self.assertEqual(final['lease_id'],a['lease_id'])
if __name__ == '__main__': unittest.main(verbosity=2)
