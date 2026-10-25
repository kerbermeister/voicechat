import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
import threading
from pathlib import Path
from contacts import ContactStore, ContactError

class ContactTests(unittest.TestCase):
    def test_link_preview_consent_retry_and_secret_storage(self):
        with tempfile.TemporaryDirectory() as root:
            store = ContactStore(Path(root) / 'contacts.sqlite')
            owner, user = '@owner:local', '@user:local'
            store.set_policy(owner, False)
            store.set_policy(user, False)
            token = store.create_link(owner)
            for _ in range(2):
                self.assertFalse(store.inspect_link(user, token)['claimed'])
            self.assertEqual(store.list(user), [])
            with self.assertRaises(ContactError): store.accept_link(owner, token, '!self:local')
            accepted = store.accept_link(user, token, '!room:local')
            self.assertTrue(store.accepted(owner, user))
            self.assertFalse(store.policy(owner))
            self.assertFalse(store.policy(user))
            self.assertEqual(store.accept_link(user, token, '!retry:local'), accepted)
            self.assertEqual(len(store.list(user)), 1)
            self.assertEqual(store.list(user)[0]['room_id'], '!room:local')
            for operation in (store.inspect_link, lambda u, t: store.accept_link(u, t, '!other:local')):
                with self.assertRaisesRegex(ContactError, 'link_used'): operation('@other:local', token)
            self.assertEqual(store.request('@other:local', owner, '!other:local')['state'], 'pending')
            reopened = ContactStore(store.path)
            self.assertEqual(reopened.inspect_link(user, token), accepted)
            self.assertNotIn(token.encode(), store.path.read_bytes())
            for bad in (None, {}, 'a' * 42, 'a' * 44, '/' * 43):
                with self.assertRaises(ContactError): store.inspect_link(user, bad)

    def test_link_claim_is_atomic_between_connections(self):
        with tempfile.TemporaryDirectory() as root:
            store = ContactStore(Path(root) / 'contacts.sqlite')
            other = ContactStore(store.path)
            token = store.create_link('@owner:local')
            barrier = threading.Barrier(2)
            def claim(args):
                db, user = args
                barrier.wait()
                try: return (user, db.claim_link(user, token))
                except ContactError as error: return str(error)
            with ThreadPoolExecutor(2) as executor:
                result = list(executor.map(claim, [(store, '@alice:local'), (other, '@bob:local')]))
            self.assertEqual(sum(isinstance(item, tuple) for item in result), 1)
            self.assertIn('link_used', result)
            self.assertEqual(store.list('@owner:local'), [])
            user, receipt = next(item for item in result if isinstance(item, tuple))
            self.assertFalse(receipt['accepted'])
            with self.assertRaises(ContactError): store.greeting(user, receipt['id'])
            store = ContactStore(store.path)
            self.assertEqual(store.claim_link(user, token), receipt)
            store.accept_link(user, token, '!room:local')
            self.assertEqual(len(store.list('@owner:local')), 1)

    def test_link_greeting_keeps_first_device_payload_and_receipt(self):
        with tempfile.TemporaryDirectory() as root:
            store = ContactStore(Path(root) / 'contacts.sqlite')
            token = store.create_link('@owner:local')
            receipt = store.accept_link('@user:local', token, '!room:local')
            identifier = receipt['id']
            first = store.prepare_greeting('@user:local', identifier, 'ONE', {'ciphertext': 'first'}, 'a' * 64)
            self.assertEqual(store.prepare_greeting('@user:local', identifier, 'TWO', {'ciphertext': 'second'}, 'b' * 64), first)
            with self.assertRaises(ContactError): store.greeting('@other:local', identifier)
            store = ContactStore(store.path)
            self.assertEqual(store.greeting('@user:local', identifier), first)
            store.finish_greeting('@user:local', identifier, '$sent')
            retried = store.prepare_greeting('@user:local', identifier, 'TWO', {}, 'b' * 64)
            self.assertEqual(retried['event_id'], '$sent')
            self.assertIsNone(retried['payload'])

    def test_link_upgrades_existing_request_without_duplicate_or_policy_change(self):
        with tempfile.TemporaryDirectory() as root:
            store = ContactStore(Path(root) / 'contacts.sqlite')
            store.set_policy('@owner:local', False)
            old = store.request('@user:local', '@owner:local', '!room:local')
            store.decide('@owner:local', old['id'], 'decline')
            token = store.create_link('@owner:local')
            store.accept_link('@user:local', token, '!room:local')
            self.assertEqual(len(store.list('@owner:local')), 1)
            self.assertEqual(store.list('@owner:local')[0]['id'], old['id'])
            self.assertTrue(store.accepted('@owner:local', '@user:local'))
            self.assertFalse(store.policy('@owner:local'))

    def test_consent_and_authorization(self):
        with tempfile.TemporaryDirectory() as root:
            store = ContactStore(Path(root) / 'contacts.sqlite')
            self.assertTrue(store.policy('@bob:local'))
            direct = store.request('@alice:local','@bob:local','!open:local')
            self.assertEqual(direct['state'], 'accepted')
            self.assertTrue(store.accepted('@bob:local','@alice:local'))
            store.set_policy('@carol:local',False)
            invite = store.request('@alice:local','@carol:local','!private:local')
            self.assertEqual(invite['state'],'pending')
            self.assertFalse(store.accepted('@alice:local','@carol:local'))
            for user in ['@alice:local','@mallory:local']:
                with self.assertRaises(ContactError): store.decide(user,invite['id'],'accept')
            store.decide('@carol:local',invite['id'],'decline')
            self.assertEqual(next(r for r in store.list('@alice:local') if r['id'] == invite['id'])['state'],'declined')
            with self.assertRaises(ContactError): store.decide('@carol:local',invite['id'],'accept')
            self.assertEqual(store.list('@mallory:local'),[])
            self.assertEqual(ContactStore(store.path).list('@carol:local')[0]['state'],'declined')
    def test_simultaneous_requests_are_mutual_consent(self):
        with tempfile.TemporaryDirectory() as root:
            store = ContactStore(Path(root) / 'contacts.sqlite')
            store.set_policy('@alice:local',False); store.set_policy('@bob:local',False)
            one = store.request('@alice:local','@bob:local','!one:local')
            two = store.request('@bob:local','@alice:local','!two:local')
            self.assertEqual(one['id'],two['id']); self.assertEqual(two['room_id'],'!one:local')
            self.assertEqual(two['state'],'accepted')
            with self.assertRaises(ContactError): store.set_policy('@alice:local',1)
            with self.assertRaises(ContactError): store.request('@alice:local','@alice:local','!one:local')

    def test_cancelled_request_can_be_sent_again_without_reviving_old_consent(self):
        with tempfile.TemporaryDirectory() as root:
            store = ContactStore(Path(root) / 'contacts.sqlite')
            store.set_policy('@bob:local', False)
            first = store.request('@alice:local', '@bob:local', '!one:local')
            store.decide('@alice:local', first['id'], 'cancel')
            second = store.request('@alice:local', '@bob:local', '!two:local')
            self.assertNotEqual(first['id'], second['id'])
            self.assertEqual(second['state'], 'pending')
            self.assertEqual(second['room_id'], '!two:local')
            with self.assertRaises(ContactError): store.decide('@bob:local', first['id'], 'accept')
