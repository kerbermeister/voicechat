"""Opt-in real local Synapse -> HTTP gateway smoke test; no Apple delivery or E2EE claim."""
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import urllib.parse
import hmac
import hashlib
import secrets
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
import base64
from check_contacts import api, MATRIX
from web_push import PushStore
import token_server


@unittest.skipUnless(os.environ.get('VOICECHAT_PUSH_SYNAPSE_TEST') == '1', 'Explicit local Synapse check only')
class SynapsePushTests(unittest.TestCase):
    def test_registration_callback_and_revocation(self):
        registration_secret = json.loads((Path(__file__).resolve().parents[1] / '.prototype/secrets.json').read_text())['registration']
        def account():
            name, password = 'push_fixture_' + secrets.token_hex(6), secrets.token_urlsafe(24)
            nonce = api(MATRIX, '/_synapse/admin/v1/register')['nonce']
            mac = hmac.new(registration_secret.encode(), '\0'.join((nonce, name, password, 'notadmin')).encode(), hashlib.sha1).hexdigest()
            api(MATRIX, '/_synapse/admin/v1/register', body={'nonce': nonce, 'username': name, 'password': password, 'admin': False, 'mac': mac})
            return api(MATRIX, '/_matrix/client/v3/login', body={'type': 'm.login.password', 'user': name, 'password': password})
        sender, receiver = account(), account()
        matrix = lambda path, session, body=None, method=None: api(MATRIX, '/_matrix/client/v3/' + path, session['access_token'], body, method)
        received = threading.Event()
        payloads = []
        def deliver(subscription, payload):
            payloads.append(payload)
            received.set()
            return 201
        with tempfile.TemporaryDirectory() as directory:
            store = PushStore(directory, 'https://fixture.example', deliver)
            server = token_server.ControlServer(('127.0.0.1', 0), token_server.Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            gateway = f'http://host.docker.internal:{server.server_port}/_matrix/push/v1/notify'
            base = f'http://127.0.0.1:{server.server_port}'
            public = ec.generate_private_key(ec.SECP256R1()).public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
            encode = lambda value: base64.urlsafe_b64encode(value).rstrip(b'=').decode()
            try:
                with patch.object(token_server, '_push', store), patch.dict(os.environ, {'VOICECHAT_PUSH_GATEWAY_URL': gateway}):
                    api(base, '/push/subscribe', receiver['access_token'], {'action': 'register', 'subscription': {
                        'endpoint': 'https://web.push.apple.com/local-fixture',
                        'keys': {'p256dh': encode(public), 'auth': encode(secrets.token_bytes(16))},
                    }})
                    pushers = matrix('pushers', receiver)['pushers']
                    self.assertEqual(len(pushers), 1)
                    self.assertEqual(pushers[0]['data']['url'], gateway)
                    self.assertEqual(pushers[0]['data']['format'], 'event_id_only')
                    room = matrix('createRoom', sender, {'preset': 'public_chat', 'initial_state': [
                        {'type': 'm.room.encryption', 'state_key': '', 'content': {'algorithm': 'm.megolm.v1.aes-sha2'}},
                    ]})['room_id']
                    path = 'rooms/' + urllib.parse.quote(room, safe='')
                    matrix('join/' + urllib.parse.quote(room, safe=''), receiver, {})
                    def send(transaction):
                        # Synthetic ciphertext tests notification transport, not encryption/decryption.
                        return matrix(path + '/send/m.room.encrypted/' + transaction, sender, {
                            'algorithm': 'm.megolm.v1.aes-sha2', 'ciphertext': 'synthetic-transport-fixture',
                            'session_id': 'fixture', 'device_id': sender['device_id'],
                        }, 'PUT')
                    send('first')
                    self.assertTrue(received.wait(15), 'Real Synapse did not reach the local gateway')
                    self.assertEqual(len(payloads), 1)
                    self.assertEqual(set(payloads[0]), {'title', 'body', 'binding'})
                    api(base, '/push/subscribe', receiver['access_token'], {'action': 'remove'})
                    self.assertEqual(matrix('pushers', receiver)['pushers'], [])
                    send('after-revocation')
                    time.sleep(1)
                    self.assertEqual(len(payloads), 1)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
                for session in (sender, receiver):
                    matrix('logout', session, {})
        print('REAL SYNAPSE: registered event_id_only pusher, callback delivered, revoke stopped delivery: PASS (provider simulated)')
