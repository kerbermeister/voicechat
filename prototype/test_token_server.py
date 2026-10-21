"""Trust-boundary tests; no Docker or real account required."""
import io
import json
import threading
import unittest
import urllib.error
import urllib.request
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

    def test_report_rejects_unknown_fields_and_non_strings(self):
        for body in [
            {'run': 'test', 'role': 'web', 'stage': 'ok', 'key': 'secret'},
            {'run': 'test', 'role': 'web', 'stage': {}},
            {'stage': 'ok'},
        ]:
            self.assertEqual(self.request(body, path='/report')[0], 400)

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
