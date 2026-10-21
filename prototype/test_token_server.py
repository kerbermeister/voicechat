"""Trust-boundary tests; no Docker or real account required."""
import io
import json
import threading
import unittest
import urllib.error
import urllib.request
import tempfile
from contacts import ContactStore
from unittest.mock import patch
from http.server import ThreadingHTTPServer
import token_server


class AdmissionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), token_server.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def request(self, body, auth='Bearer test', path='/token'):
        request = urllib.request.Request(
            f'http://127.0.0.1:{self.server.server_port}{path}',
            json.dumps(body).encode(), {'Authorization': auth})
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def test_missing_auth_and_bad_input(self):
        self.assertEqual(self.request({'room_id': '!room:local', 'session': 'test'}, '')[0], 401)
        self.assertEqual(self.request({'room_id': {}, 'session': 'test'})[0], 400)
        self.assertEqual(self.request({'room_id': '!room:local', 'session': ''})[0], 400)

    def test_contact_consent_uses_authenticated_user_and_real_encrypted_pair(self):
        with tempfile.TemporaryDirectory() as directory:
            store = ContactStore(directory + '/contacts.sqlite')
            store.set_policy('@bob:local', False)
            member = lambda user: {'type': 'm.room.member', 'state_key': user,
                                  'content': {'membership': 'join' if user == '@alice:local' else 'invite'}}
            state = [member('@alice:local'), member('@bob:local'),
                     {'type': 'm.room.encryption', 'content': {'algorithm': 'm.megolm.v1.aes-sha2'}}]
            caller = '@alice:local'
            def matrix(handler, path):
                return {'user_id': caller} if path == 'account/whoami' else state
            with patch.object(token_server, '_contacts', store), patch.object(token_server.Handler, 'matrix', matrix):
                request = {'action': 'request', 'recipient': '@bob:local', 'room_id': '!pair:local'}
                status, body = self.request(request, path='/contacts')
                self.assertEqual(status, 200)
                self.assertEqual(body['state'], 'pending')
                self.assertFalse(store.accepted('@alice:local', '@bob:local'))
                decision = {'action': 'accept', 'id': body['id']}
                self.assertEqual(self.request(decision, path='/contacts')[0], 403)
                caller = '@eve:local'
                self.assertEqual(self.request(decision, path='/contacts')[0], 403)
                caller = '@bob:local'
                self.assertEqual(self.request(decision, path='/contacts')[0], 200)
                self.assertTrue(store.accepted('@alice:local', '@bob:local'))
                caller = '@alice:local'
                state.append(member('@eve:local'))
                self.assertEqual(self.request(request, path='/contacts')[0], 403)
                state.pop()
                state[-1]['content']['algorithm'] = 'plaintext'
                self.assertEqual(self.request(request, path='/contacts')[0], 403)

    def test_report_rejects_unknown_fields_and_non_strings(self):
        for body in [
            {'run': 'test', 'role': 'web', 'stage': 'ok', 'key': 'secret'},
            {'run': 'test', 'role': 'web', 'stage': {}},
            {'stage': 'ok'},
        ]:
            self.assertEqual(self.request(body, path='/report')[0], 400)

    def test_public_fingerprint_report(self):
        with patch('pathlib.Path.write_text'), patch('pathlib.Path.chmod'):
            status, _ = self.request({'run': 'test', 'role': 'web', 'stage': 'identity',
                'user_id': '@alice:local', 'device_id': 'DEVICE', 'fingerprint': 'public-only'}, path='/report')
        self.assertEqual(status, 200)

    def test_membership_encryption_and_grant(self):
        original = urllib.request.urlopen
        for membership, algorithm, expected in [
            ('leave', 'm.megolm.v1.aes-sha2', 403),
            ('join', 'plaintext', 403),
            ('join', 'm.megolm.v1.aes-sha2', 200),
        ]:
            def upstream(request, *args, **kwargs):
                if ':8008/' not in request.full_url:
                    return original(request, *args, **kwargs)
                if request.full_url.endswith('whoami'):
                    data = {'user_id': '@alice:local', 'device_id': 'DEVICE'}
                elif 'm.room.member/' in request.full_url:
                    data = {'membership': membership}
                else:
                    data = {'algorithm': algorithm}
                return io.BytesIO(json.dumps(data).encode())
            with patch('urllib.request.urlopen', side_effect=upstream):
                status, body = self.request({'room_id': '!room:local', 'session': 'test'})
            self.assertEqual(status, expected)
            if status == 200:
                import base64
                payload = body['token'].split('.')[1]
                grant = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
                self.assertEqual(grant['sub'], '@alice:local/DEVICE')
                self.assertEqual(grant['exp'] - grant['nbf'], 65)
                self.assertEqual(grant['video']['canPublishSources'], ['microphone'])
                self.assertNotIn('key', grant)


if __name__ == '__main__':
    unittest.main()
