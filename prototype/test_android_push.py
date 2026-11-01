"""Android push boundaries: account routing, retries, revoke and atomic answering."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from android_push import AndroidPushStore, APP_ID
from web_push import PushError


class AndroidPushTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.sent = []
        self.valid = True
        self.code = 200
        def send(token, binding, notice, **_):
            self.sent.append((token, binding, notice))
            return self.code
        self.store = AndroidPushStore(Path(self.directory.name), 'https://voice.example', send,
            lambda *_: self.valid)
        self.binding = self.store.register_android('@bob:local', 'B', 'b' * 100)

    def notify(self, event='$message'):
        return self.store.notify({'notification': {'event_id': event, 'room_id': '!room:local',
            'devices': [{'app_id': APP_ID, 'pushkey': self.binding}]}})

    def invite(self):
        return self.store.call_action('@alice:local', 'A',
            {'action': 'invite', 'session': 'call-1', 'room': '!room:local'}, {'@alice:local', '@bob:local'})['call']

    def test_authenticated_registration_is_idempotent_and_token_rotation_keeps_binding(self):
        self.assertEqual(self.binding, self.store.register_android('@bob:local', 'B', 'b' * 100))
        self.store.rotate(self.binding, 'c' * 100)
        self.notify()
        self.assertEqual(self.sent[0][:2], ('c' * 100, self.binding))
        with self.assertRaises(PushError): self.store.rotate('unknown', 'd' * 100)
        self.valid = False
        with self.assertRaises(PushError): self.store.rotate(self.binding, 'e' * 100)

    def test_no_content_in_fcm_and_notice_resolves_only_for_its_device(self):
        self.assertEqual(self.notify(), {'rejected': []})
        self.notify()
        self.assertEqual(len(self.sent), 1)
        token, binding, notice = self.sent[0]
        self.assertNotIn('room', notice)
        self.assertEqual(self.store.resolve(binding, notice)['room'], '!room:local')
        other = self.store.register_android('@charlie:local', 'C', 'c' * 100)
        with self.assertRaises(PushError): self.store.resolve(other, notice)
        self.store.remove_android('@bob:local', 'B')
        with self.assertRaises(PushError): self.store.resolve(binding, notice)

    def test_revoke_checked_on_send_and_receive_without_deleting_other_room_bindings(self):
        self.notify()
        self.valid = False
        with self.assertRaises(PushError): self.store.resolve(self.binding, self.sent[0][2])
        self.notify('$second')
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.store.android_tokens('@bob:local', 'B'), [self.binding])

    def test_transient_delivery_failure_is_retryable_and_only_unregistered_removes_device(self):
        self.code = 503
        with self.assertRaises(PushError): self.notify()
        self.code = 200
        self.notify()
        self.assertEqual(len(self.sent), 2)
        self.code = 410
        self.assertEqual(self.notify('$other'), {'rejected': [self.binding]})

    def test_count_only_and_web_only_callbacks_do_not_create_android_alerts(self):
        self.store.notify({'notification': {'devices': [{'app_id': APP_ID, 'pushkey': self.binding}]}})
        self.store.notify({'notification': {'event_id': '$web', 'devices': []}})
        self.assertEqual(self.sent, [])

    def test_web_registration_does_not_erase_android_deduplication(self):
        self.notify()
        with patch('web_push.validate_subscription', return_value={'endpoint': 'https://provider.example', 'keys': {}}):
            self.store.register('@web:local', 'W', {})
        self.notify()
        self.assertEqual(len(self.sent), 1)

    def test_call_cancel_and_expiry_are_resolved_before_display(self):
        notice = self.invite()
        self.assertEqual(self.store.resolve(self.binding, notice)['kind'], 'call')
        self.store.call_action('@alice:local', 'A', {'action': 'end', 'session': 'call-1'})
        self.assertEqual(self.store.resolve(self.binding, notice)['kind'], 'dismiss')
        with self.assertRaises(PushError):
            self.store.call_action('@bob:local', 'B', {'action': 'accept', 'session': 'call-1'})
        with self.store.connect() as db:
            db.execute('UPDATE push_calls SET ended=0,expires=0')
        self.assertEqual(self.store.resolve(self.binding, notice)['kind'], 'dismiss')

    def test_matrix_wakeup_during_ringing_resolves_to_the_same_call_notification(self):
        notice = self.invite()
        self.notify()
        resolved = self.store.resolve(self.binding, self.sent[0][2])
        self.assertEqual((resolved['kind'], resolved['call']), ('call', notice))

    def test_video_mode_is_explicit_and_malformed_mode_is_rejected(self):
        body = {'action': 'invite', 'session': 'video-call', 'room': '!room:local', 'video': True}
        notice = self.store.call_action('@alice:local', 'A', body, {'@alice:local', '@bob:local'})['call']
        self.assertTrue(self.store.resolve(self.binding, notice)['video'])
        with self.assertRaises(PushError):
            self.store.call_action('@alice:local', 'A', {**body, 'session': 'invalid', 'video': 'true'}, {'@alice:local', '@bob:local'})

    def test_answer_is_atomic_per_user_and_decline_is_device_scoped(self):
        notice = self.invite()
        self.store.register_android('@bob:local', 'B2', 'd' * 100)
        def accept(device):
            try:
                self.store.call_action('@bob:local', device, {'action': 'accept', 'session': 'call-1'})
                return True
            except PushError: return False
        with ThreadPoolExecutor(2) as pool:
            self.assertEqual(sum(pool.map(accept, ['B', 'B2'])), 1)
        self.assertEqual(self.store.resolve(self.binding, notice)['kind'], 'dismiss')
        with self.assertRaises(PushError):
            self.store.call_action('@mallory:local', 'M', {'action': 'status', 'session': 'call-1'})

    def test_native_decline_and_durable_wakeup_survive_reopen(self):
        notice = self.invite()
        self.store.bound_call_action(self.binding, {'notice': notice, 'action': 'decline'})
        self.store = AndroidPushStore(Path(self.directory.name), 'https://voice.example',
            lambda *args, **kwargs: self.sent.append(args) or 200, lambda *_: True)
        self.store.advance()
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.store.resolve(self.binding, notice)['kind'], 'dismiss')
        self.assertTrue(self.store.call_action('@alice:local', 'A', {'action': 'status', 'session': 'call-1'})['declined'])

    def test_cancellation_enqueued_during_send_is_not_lost(self):
        notice = self.invite()
        def send(*_, **kwargs):
            self.store.call_action('@alice:local', 'A', {'action': 'end', 'session': 'call-1'})
            return 200
        self.store.send = send
        self.store.advance()
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM call_wakes').fetchone()[0], 1)
        self.assertEqual(self.store.resolve(self.binding, notice)['kind'], 'dismiss')
