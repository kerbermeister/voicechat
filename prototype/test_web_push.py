import base64
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
import http_ece
import requests
from web_push import PushStore, PushError, APP_ID, validate_subscription
import token_server


def encode(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b'=').decode()


def subscription(endpoint='https://web.push.apple.com/test-device'):
    private = ec.generate_private_key(ec.SECP256R1())
    public = private.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return private, {'endpoint': endpoint, 'keys': {'p256dh': encode(public), 'auth': encode(b'0123456789abcdef')}}


def notice(token, event='$new'):
    return {'notification': {'event_id': event, 'room_id': '!secret:local', 'content': {'body': 'SECRET MESSAGE'}, 'devices': [{'app_id': APP_ID, 'pushkey': token}]}}


class PushTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.sent = []
        self.code = 201
        self.store = PushStore(self.directory.name, 'https://voice.example', self.deliver)
        self.private, self.subscription = subscription()

    def deliver(self, sub, payload):
        self.sent.append((sub, payload))
        return self.code

    def test_validation_refuses_ssrf_credentials_redirect_hosts_and_bad_keys(self):
        for endpoint in ['http://web.push.apple.com/x', 'https://localhost/x', 'https://127.0.0.1/x', 'https://web.push.apple.com.evil.test/x', 'https://user@web.push.apple.com/x', 'https://web.push.apple.com:8090/x', 'https://web.push.apple.com/x#fragment']:
            with self.subTest(endpoint=endpoint), self.assertRaises(PushError):
                validate_subscription({**self.subscription, 'endpoint': endpoint})
        for keys in [{}, {'auth': 'short', 'p256dh': self.subscription['keys']['p256dh']}, {'auth': self.subscription['keys']['auth'], 'p256dh': encode(b'\x04' + b'\0' * 64)}]:
            with self.assertRaises(PushError): validate_subscription({**self.subscription, 'keys': keys})

    def test_dedup_retries_and_generic_payload(self):
        token = self.store.register('@a:local', 'DEVICE', self.subscription)
        self.code = 503
        with self.assertRaises(PushError): self.store.notify(notice(token))
        self.code = 201
        self.assertEqual(self.store.notify(notice(token)), {'rejected': []})
        self.store.notify(notice(token))
        self.store.notify(notice(token, None))
        self.assertEqual(len(self.sent), 2)
        payload = self.sent[-1][1]
        self.assertEqual(set(payload), {'title', 'body', 'binding'})
        self.assertNotIn('SECRET', json.dumps(payload))
        self.assertNotIn('!secret', json.dumps(payload))
        self.assertEqual(payload['binding'], token)

    def test_account_switch_rotation_revocation_and_gone_provider(self):
        old = self.store.register('@a:local', 'DEVICE', self.subscription)
        new = self.store.register('@b:local', 'DEVICE', self.subscription)
        self.assertEqual(self.store.notify(notice(old)), {'rejected': [old]})
        self.assertEqual(self.store.remove('@a:local', 'DEVICE'), [])
        self.store.notify(notice(new))
        self.assertEqual(len(self.sent), 1)
        self.code = 410
        self.assertEqual(self.store.notify(notice(new, '$gone')), {'rejected': [new]})
        self.store.notify(notice(new, '$later'))
        self.assertEqual(len(self.sent), 2)
        latest = self.store.register('@b:local', 'DEVICE', self.subscription)
        self.assertEqual(self.store.remove('@b:local', 'DEVICE'), [latest])
        self.assertEqual(self.store.notify(notice(latest)), {'rejected': [latest]})

    def test_vapid_key_survives_restart_and_has_private_permissions(self):
        reopened = PushStore(self.directory.name, 'https://voice.example', self.deliver)
        self.assertEqual(reopened.public_key, self.store.public_key)
        self.assertEqual(self.store.key.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)

    def test_actual_webpush_ciphertext_decrypts_only_with_browser_key_and_no_redirect(self):
        store = PushStore(self.directory.name, 'https://voice.example')
        prepared = []
        def send(session, request, **kwargs):
            self.assertFalse(kwargs['allow_redirects'])
            prepared.append(request)
            response = requests.Response()
            response.status_code = 201
            return response
        with patch.object(requests.Session, 'send', send):
            self.assertEqual(store._deliver(self.subscription, {'body': 'encrypted generic activity'}), 201)
        request = prepared[0]
        self.assertIn('vapid ', request.headers['Authorization'])
        self.assertNotIn(b'encrypted generic activity', request.body)
        decrypted = http_ece.decrypt(request.body, private_key=self.private, auth_secret=b'0123456789abcdef', version='aes128gcm')
        self.assertEqual(json.loads(decrypted), {'body': 'encrypted generic activity'})
        with self.assertRaises(Exception):
            http_ece.decrypt(request.body, private_key=ec.generate_private_key(ec.SECP256R1()), auth_secret=b'0123456789abcdef', version='aes128gcm')

    def test_http_subscription_requires_matrix_device_and_installs_event_id_only_pusher(self):
        server = token_server.ControlServer(('127.0.0.1', 0), token_server.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        calls = []
        def matrix(handler, path, body=None):
            if handler.headers.get('Authorization') != 'Bearer test': raise token_server.ContactError('unauthorized')
            calls.append((path, body))
            return {'user_id': '@a:local', 'device_id': 'DEVICE'} if path == 'account/whoami' else {}
        def register(auth):
            request = urllib.request.Request(f'http://127.0.0.1:{server.server_port}/push/subscribe', json.dumps({'action': 'register', 'subscription': self.subscription}).encode(), {'Authorization': auth})
            try:
                with urllib.request.urlopen(request) as response: return response.status, json.load(response)
            except urllib.error.HTTPError as error: return error.code, json.load(error)
        with patch.object(token_server, '_push', self.store), patch.object(token_server.Handler, 'matrix', matrix):
            self.assertEqual(register('')[0], 401)
            status, first = register('Bearer test')
            self.assertEqual(status, 200)
            self.assertEqual(register('Bearer test')[0], 200)
        self.assertIn(('pushers/set', {'app_id': APP_ID, 'pushkey': first['binding'], 'kind': None}), calls)
        pusher = calls[-1][1]
        self.assertEqual(pusher['data']['format'], 'event_id_only')
        self.assertEqual(pusher['data']['url'].split('/', 3)[-1], '_matrix/push/v1/notify')
        self.assertNotIn('subscription', pusher['data'])
