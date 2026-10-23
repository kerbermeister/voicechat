"""Два выбранных устройства, свежий групповой lease и устойчивый отзыв допуска."""
import sqlite3
import tempfile
import unittest
from pathlib import Path
from screen_control import ScreenStore, ScreenError
from call_control import CallStore
from screen_access import verified_devices


class ScreenAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'calls.sqlite'
        self.now = 1000.
        self.calls = CallStore(self.path, lambda *_: None, lambda: self.now)
        self.store = ScreenStore(self.path, lambda: self.now)
        self.a = {'user_id': '@a:x', 'device_id': 'A'}
        self.b = {'user_id': '@b:x', 'device_id': 'B'}
        self.valid = {'@a:x/A': ('curve-a', 'ed-a'), '@b:x/B': ('curve-b', 'ed-b')}

    def bind(self, actor, peer):
        return self.store.bind(actor, {'room_id':'!dm:x','call_session':'call-id','transport':'direct', 'peer':peer}, self.valid)

    def auth(self, actor, result, valid=None):
        return self.store.authorize(actor, result['binding_id'], result['lease_id'], self.valid if valid is None else valid)

    def test_direct_requires_two_matching_confirmations_and_retry_keeps_lease(self):
        first = self.bind(self.a, self.b)
        with self.assertRaises(ScreenError):
            self.auth(self.a, first)
        second = self.bind(self.b, self.a)
        self.assertEqual(first['binding_id'], second['binding_id'])
        self.assertEqual(self.auth(self.a, first)['identity'], '@a:x/A')
        self.assertEqual(self.bind(self.a, self.b), first)
        other = {'user_id':'@a:x', 'device_id':'OTHER'}
        self.valid['@a:x/OTHER'] = ('curve-other','ed-other')
        with self.assertRaisesRegex(ScreenError, 'screen_binding_mismatch'):
            self.bind(other, self.b)
        with self.assertRaises(ScreenError):
            self.auth(self.b, first)

    def test_leave_and_expiry_do_not_resurrect_same_direct_call(self):
        first = self.bind(self.a, self.b)
        self.bind(self.b, self.a)
        with self.assertRaises(ScreenError):
            self.store.leave(self.b, first['binding_id'], first['lease_id'])
        self.now += 31
        with self.assertRaises(ScreenError):
            self.auth(self.a, first)
        with self.assertRaisesRegex(ScreenError, 'call_ended'):
            self.bind(self.a, self.b)
        ScreenStore(self.path, lambda:self.now)
        with self.store.db() as db:
            self.assertEqual(db.execute('SELECT state FROM screen_bindings').fetchone()[0], 'ended')

    def test_key_revocation_is_committed_even_when_authorization_fails(self):
        first = self.bind(self.a, self.b)
        self.bind(self.b, self.a)
        with self.assertRaises(ScreenError):
            self.auth(self.a, first, {'@a:x/A':self.valid['@a:x/A'], '@b:x/B':None})
        with self.assertRaises(ScreenError):
            self.auth(self.a, first)

    def test_mismatched_pair_cannot_be_confirmed(self):
        self.bind(self.a,self.b)
        self.valid['@c:x/C'] = ('curve-c','ed-c')
        with self.assertRaisesRegex(ScreenError, 'screen_binding_mismatch'):
            self.bind(self.b, {'user_id':'@c:x','device_id':'C'})

    def test_heartbeat_renews_only_current_unexpired_lease(self):
        first = self.bind(self.a,self.b)
        second = self.bind(self.b,self.a)
        self.now += 20
        self.store.authorize(self.a,first['binding_id'],first['lease_id'],self.valid,renew=True)
        self.store.authorize(self.b,second['binding_id'],second['lease_id'],self.valid,renew=True)
        self.now += 20
        self.auth(self.a,first)
        self.now += 11
        with self.assertRaises(ScreenError):
            self.store.authorize(self.a,first['binding_id'],first['lease_id'],self.valid,renew=True)

    def test_simultaneous_two_device_bind_keeps_one_selected_device(self):
        from concurrent.futures import ThreadPoolExecutor
        other = {'user_id':'@a:x','device_id':'OTHER'}
        self.valid['@a:x/OTHER'] = ('curve-other','ed-other')
        def attempt(actor):
            try:
                return self.bind(actor,self.b)
            except ScreenError:
                return None
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(attempt,[self.a,other]))
        self.assertEqual(sum(result is not None for result in results),1)
        with self.store.db() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM screen_participants').fetchone()[0],1)

    def test_group_uses_live_call_lease_without_allocating_second_seat(self):
        try:
            self.calls.admission('!g:x','s',False,self.a,*self.valid['@a:x/A'])
        except ValueError:
            pass
        self.now += 1
        call = self.calls.admission('!g:x','s',False,self.a,*self.valid['@a:x/A'])
        request = {'room_id':'!g:x','call_session':'s','transport':'group','call_lease_id':call['lease_id']}
        bound = self.store.bind(self.a,request,self.valid)
        self.auth(self.a,bound)
        with self.store.db() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM leases').fetchone()[0], 1)
        self.calls.leave(self.a,call['lease_id'])
        with self.assertRaises(ScreenError):
            self.auth(self.a,bound)

    def test_v1_metadata_upgrade_preserves_bindings(self):
        path = self.path.with_name('old.sqlite')
        with sqlite3.connect(path) as db:
            db.executescript(Path(__file__).with_name('screen_schema.sql').read_text())
            db.execute("INSERT INTO screen_bindings VALUES('old','!r:x','s','group','pending',0,NULL)")
        upgraded = ScreenStore(path)
        with upgraded.db() as db:
            self.assertEqual(db.execute('SELECT id FROM screen_bindings').fetchone()[0], 'old')
            self.assertEqual(db.execute('SELECT version FROM screen_schema').fetchone()[0], 2)

    def test_old_matrix_snapshot_does_not_remove_concurrent_group_join(self):
        bindings = []
        for actor in (self.a,self.b):
            keys = self.valid[actor['user_id']+'/'+actor['device_id']]
            try:
                self.calls.admission('!g:x','s',False,actor,*keys)
            except ValueError:
                pass
            self.now += 1
            call = self.calls.admission('!g:x','s',False,actor,*keys)
            bindings.append(self.store.bind(actor, {'room_id':'!g:x','call_session':'s',
                'transport':'group','call_lease_id':call['lease_id']}, self.valid))
        self.auth(self.a,bindings[0],{'@a:x/A':self.valid['@a:x/A']})
        self.assertEqual(len(self.store.participants(bindings[0]['binding_id'])),2)
        self.auth(self.a,bindings[0],{'@a:x/A':self.valid['@a:x/A'],'@b:x/B':None})
        self.assertEqual(len(self.store.participants(bindings[0]['binding_id'])),1)


class ScreenMatrixBoundaryTests(unittest.TestCase):
    def test_unknown_device_and_nonmember_keys_are_not_trusted(self):
        who = {'user_id':'@a:x','device_id':'A'}
        key = 'A'*43
        def matrix(path, body=None):
            if path.endswith('joined_members'): return {'joined':{'@a:x':{}}}
            if '/state/' in path: return {'algorithm':'m.megolm.v1.aes-sha2'}
            self.assertNotIn('@outsider:x',body['device_keys'])
            return {'device_keys':{'@a:x':{'A':{'user_id':'@a:x','device_id':'WRONG',
                'keys':{'curve25519:A':key,'ed25519:A':key}}}}}
        self.assertEqual(verified_devices(matrix,who,'!r:x',{'@outsider:x':['O']}),
                         {'@a:x/A':None,'@outsider:x/O':None})


if __name__ == '__main__':
    unittest.main()
