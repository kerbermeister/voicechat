import tempfile
import base64
from pathlib import Path
import unittest
from scheduled_messages import ScheduledStore, ScheduleError, audience_digest, scheduled_audience, validate_envelope
from client_policy import load_policy


class ScheduledTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.now = 1000
        self.events = {}
        self.calls = []
        self.path = Path(self.root.name) / 'scheduled.sqlite'
        self.store = ScheduledStore(self.path, self.publish, lambda: self.now)

    def publish(self, job):
        self.calls.append(job['id'])
        return self.events.setdefault(job['id'], '$event-' + str(len(self.events)))

    def put(self, transaction='first', due=None, user='@alice:local', device='PHONE'):
        return self.store.put(user, device, transaction, '!room:local',
            int(self.now * 1000) + 10000 if due is None else due,
            {'ciphertext':'opaque'}, 'a' * 64, 48 * 3600)

    def test_cancellation_before_lost_create_reply_is_a_durable_tombstone(self):
        self.store.withdraw('@alice:local', 'PHONE', 'first', '!room:local')
        identifier = self.put()
        self.now += 11
        self.assertFalse(self.store.advance())
        self.assertEqual(self.store.get('@alice:local', identifier)['state'], 'cancelled')
        self.assertEqual(self.events, {})
        with self.assertRaises(ScheduleError):
            self.store.withdraw('@alice:local', 'PHONE', 'first', '!other:local')

    def test_deadline_idempotence_and_ciphertext_cleanup(self):
        identifier = self.put()
        self.assertFalse(self.store.advance())
        self.now += 10
        self.assertTrue(self.store.advance())
        self.assertFalse(self.store.advance())
        row = self.store.get('@alice:local', identifier)
        self.assertEqual(row['state'], 'sent')
        self.assertIsNone(row['payload'])
        self.assertEqual(self.put(due=0), identifier)
        self.assertEqual(len(self.events), 1)
        self.assertNotIn('payload', self.store.list('@alice:local')[0])
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_temporary_failure_retries_without_losing_the_encrypted_draft(self):
        identifier = self.put()
        self.now += 10
        self.store.publish = lambda _: (_ for _ in ()).throw(OSError('upstream offline'))
        self.store.advance()
        row = self.store.get('@alice:local', identifier)
        self.assertEqual(row['state'], 'retry')
        self.assertEqual(row['payload'], {'ciphertext':'opaque'})
        with self.assertRaises(ScheduleError): self.store.cancel('@alice:local', identifier)
        self.assertFalse(self.store.advance())
        self.now += 1
        self.store.publish = self.publish
        self.assertTrue(self.store.advance())
        self.assertEqual(self.store.get('@alice:local', identifier)['state'], 'sent')

    def test_crash_after_publication_reuses_the_same_matrix_transaction(self):
        identifier = self.put()
        self.now += 10
        class Crash(BaseException): pass
        def crash(job):
            self.publish(job)
            raise Crash()
        self.store.publish = crash
        with self.assertRaises(Crash): self.store.advance()
        self.assertEqual(self.store.get('@alice:local', identifier)['state'], 'sending')
        recovered = ScheduledStore(self.path, self.publish, lambda: self.now)
        self.assertTrue(recovered.advance())
        self.assertEqual(self.calls, [identifier, identifier])
        self.assertEqual(len(self.events), 1)
        self.assertEqual(recovered.get('@alice:local', identifier)['state'], 'sent')

    def test_revoked_access_is_visible_and_keeps_the_draft_for_its_owner(self):
        identifier = self.put()
        self.now += 10
        self.store.publish = lambda _: (_ for _ in ()).throw(ScheduleError('audience_changed', 409))
        self.store.advance()
        self.assertFalse(self.store.advance())
        row = self.store.get('@alice:local', identifier)
        self.assertEqual((row['state'], row['error']), ('failed', 'audience_changed'))
        self.assertIsNotNone(row['payload'])
        self.assertEqual(self.store.list('@bob:local'), [])
        with self.assertRaises(ScheduleError): self.store.get('@bob:local', identifier)
        with self.assertRaises(ScheduleError): self.store.cancel('@bob:local', identifier)
        self.store.cancel('@alice:local', identifier)
        self.assertIsNone(self.store.get('@alice:local', identifier)['payload'])

    def test_server_horizon_and_owner_device_are_bound_to_the_transaction(self):
        now = int(self.now * 1000)
        for due in (True, now, now - 1, now + 48 * 3600 * 1000 + 1):
            with self.subTest(due=due), self.assertRaises(ScheduleError): self.put(due=due)
        self.put(due=now + 48 * 3600 * 1000)
        self.assertNotEqual(self.put(device='PHONE'), self.put(device='BROWSER'))
        self.assertNotEqual(ScheduledStore.identifier('@alice:local','a\0b','c'),
                            ScheduledStore.identifier('@alice:local','a','b\0c'))
        self.assertEqual(len(self.store.list('@alice:local')), 2)

    def test_audience_digest_tracks_members_and_keys_in_a_stable_order(self):
        members = ['@bob:local', '@alice:local']
        keys = {user: {'D': {'keys': {'curve25519:D':'curve-'+user, 'ed25519:D':'ed-'+user}}} for user in members}
        digest = audience_digest(members, keys)
        self.assertEqual(digest, audience_digest(list(reversed(members)), dict(reversed(list(keys.items())))))
        self.assertNotEqual(digest, audience_digest(members + ['@carol:local'], keys))
        keys['@bob:local']['D']['keys']['ed25519:D'] = 'changed'
        self.assertNotEqual(digest, audience_digest(members, keys))

    def test_private_audience_includes_an_invited_peer_but_groups_only_include_joined_members(self):
        state = [{'type':'m.room.member','state_key':user,'content':{'membership':membership}}
                 for user, membership in [('@alice:local','join'),('@bob:local','invite')]]
        self.assertEqual(scheduled_audience(state), {'@alice:local'})
        state.append({'type':'dev.voicechat.kind','state_key':'',
                      'content':{'kind':'direct','owner':'@alice:local','peer':'@bob:local'}})
        self.assertEqual(scheduled_audience(state), {'@alice:local','@bob:local'})
        state.append({'type':'m.room.member','state_key':'@mallory:local','content':{'membership':'join'}})
        with self.assertRaises(ScheduleError): scheduled_audience(state)

    def test_only_a_bounded_encrypted_envelope_from_the_authenticated_device_is_accepted(self):
        curve = base64.b64encode(bytes(range(32))).decode().rstrip('=')
        payload = {'algorithm':'m.megolm.v1.aes-sha2','device_id':'PHONE','sender_key':curve,
                   'session_id':curve,'ciphertext':base64.b64encode(b'opaque fixture').decode()}
        policy = load_policy()
        validate_envelope(payload, 'PHONE', curve, policy)
        validate_envelope({**payload,'dev.voicechat.ttl_seconds':10}, 'PHONE', curve, policy)
        for change in [{'body':'never store plaintext'}, {'device_id':'FOREIGN'}, {'ciphertext':'bad%%%'},
                       {'ciphertext':'A'*61441}, {'session_id':'short'}, {'dev.voicechat.ttl_seconds':11},
                       {'org.matrix.self_destruct_after':9999999999},
                       {'m.relates_to':{'rel_type':'m.replace','event_id':'$old'}}]:
            with self.subTest(change=list(change)), self.assertRaises((ScheduleError, ValueError)):
                validate_envelope({**payload,**change}, 'PHONE', curve, policy)


if __name__ == '__main__': unittest.main()
