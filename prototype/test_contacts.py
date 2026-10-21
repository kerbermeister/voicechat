import tempfile
import unittest
from pathlib import Path
from contacts import ContactStore, ContactError

class ContactTests(unittest.TestCase):
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
