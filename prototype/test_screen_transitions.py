"""Перехват, повторы, crash recovery и fencing без реальных медиаключей."""
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4
import unittest
import test_screen_admission as admission
from screen_control import ScreenStore, ScreenError
from screen_transitions import ScreenTransitions


class ScreenTransitionTests(unittest.TestCase):
    bind = admission.ScreenAdmissionTests.bind
    auth = admission.ScreenAdmissionTests.auth

    def setUp(self):
        admission.ScreenAdmissionTests.setUp(self)
        self.first = self.bind(self.a,self.b)
        self.second = self.bind(self.b,self.a)
        self.rooms = set()
        self.events = []
        self.fail_delete = False
        self.invalidate_on_create = False
        self.engine = ScreenTransitions(self.store,self.media)

    def media(self, operation, body):
        # Запись другой connection доказывает, что SQL-транзакция не удерживается на IO.
        with self.store.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS io_probe(id INTEGER)')
        self.events.append((operation,body.copy()))
        if operation == 'DeleteRoom':
            if self.fail_delete: raise OSError('offline')
            self.rooms.discard(body['room'])
        else:
            self.rooms.add(body['name'])
            if self.invalidate_on_create:
                self.store.leave(self.a,self.first['binding_id'],self.first['lease_id'])

    def session(self):
        with self.store.db() as db:
            return dict(db.execute('SELECT * FROM screen_sessions').fetchone())

    def command(self, actor=None, bound=None, action='claim', request_id=None, revision=None):
        bound = bound or self.first
        return self.engine.command(action,actor or self.a,bound['binding_id'],bound['lease_id'],self.valid,
                                   request_id or str(uuid4()),self.session()['revision'] if revision is None else revision)

    def test_takeover_deletes_old_room_before_create_and_repeat_has_no_new_effect(self):
        request = str(uuid4())
        revision = self.session()['revision']
        self.assertEqual(self.command(request_id=request,revision=revision)['status'],'succeeded')
        old = self.session()['generation']
        events = len(self.events)
        self.command(request_id=request,revision=revision)
        self.assertEqual(len(self.events),events)
        with self.assertRaisesRegex(ScreenError,'idempotency_conflict'):
            self.command(request_id=request,revision=revision+1)
        self.command(self.b,self.second)
        self.assertNotIn(old,self.rooms)
        self.assertEqual(len(self.rooms),1)
        self.assertEqual(self.events[-2][0],'DeleteRoom')
        self.assertEqual(self.events[-1][0],'CreateRoom')
        with self.assertRaisesRegex(ScreenError,'screen_not_owner'):
            self.command(action='stop')
        self.command(self.b,self.second,action='stop')
        self.assertEqual(self.rooms,set())

    def test_two_same_revision_claims_have_only_one_winner(self):
        revision = self.session()['revision']
        def attempt(pair):
            try: return self.command(*pair,revision=revision)['status']
            except ScreenError as error: return str(error)
        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes=list(pool.map(attempt,[(self.a,self.first),(self.b,self.second)]))
        self.assertCountEqual(outcomes,['succeeded','screen_revision_conflict'])
        self.assertEqual(len(self.rooms),1)

    def test_unknown_delete_result_blocks_new_room_and_recovery_finishes_same_intent(self):
        self.command()
        self.fail_delete=True
        with self.assertRaisesRegex(ScreenError,'screen_unavailable'):
            self.command(self.b,self.second)
        self.assertEqual(self.session()['state'],'switching')
        self.assertEqual(len(self.rooms),1)
        self.fail_delete=False
        ScreenTransitions(ScreenStore(self.path,lambda:self.now),self.media).recover()
        self.assertEqual(self.session()['state'],'active')
        self.assertEqual(self.session()['owner_identity'],'@b:x/B')
        self.assertEqual(len(self.rooms),1)

    def test_deadline_and_concurrent_leave_do_not_activate_stale_generation(self):
        self.command()
        self.fail_delete=True
        with self.assertRaises(ScreenError): self.command(self.b,self.second)
        self.now+=16
        self.fail_delete=False
        self.engine.recover()
        self.assertEqual(self.session()['state'],'idle')
        self.assertEqual(self.rooms,set())
        self.invalidate_on_create=True
        self.command()
        self.assertEqual(self.session()['state'],'ended')
        self.assertEqual(self.rooms,set())

    def test_fifty_fake_sfu_cycles_leave_no_retired_rooms_and_replay_has_no_effect(self):
        first_request=str(uuid4())
        initial_revision=self.session()['revision']
        self.command(request_id=first_request,revision=initial_revision)
        for index in range(50):
            actor,bound=(self.b,self.second) if index%2==0 else (self.a,self.first)
            self.command(actor,bound)
            generation=self.session()['generation']
            self.assertEqual(self.rooms,{generation})
            self.command(request_id=first_request,revision=initial_revision)
            self.assertEqual(self.session()['generation'],generation)
            self.command(actor,bound,action='stop')
            self.assertEqual(self.rooms,set())
            with self.store.db() as db:
                self.assertEqual(db.execute('SELECT COUNT(*) FROM screen_retired').fetchone()[0],0)
        self.assertEqual(self.session()['state'],'idle')

    def test_process_restart_annuls_leases_instead_of_resuming_capture(self):
        self.command()
        restarted=ScreenStore(self.path,lambda:self.now)
        restarted.recover()
        ScreenTransitions(restarted,self.media).recover()
        self.assertEqual(self.session()['state'],'ended')
        self.assertEqual(self.rooms,set())
        with self.assertRaises(ScreenError):
            self.auth(self.a,self.first)


if __name__ == '__main__':
    unittest.main()
