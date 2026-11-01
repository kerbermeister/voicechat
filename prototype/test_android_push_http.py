import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

from android_push import AndroidPushStore
from contacts import ContactError
import token_server


class AndroidPushHTTPTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.store = AndroidPushStore(directory.name, 'https://voice.example', lambda *_args, **_kw: 200, lambda *_: True)
        store_patch = patch.object(token_server, 'push_store', return_value=self.store)
        store_patch.start()
        self.addCleanup(store_patch.stop)
        def matrix(handler, path, body=None):
            if handler.headers.get('Authorization') != 'Bearer matrix-token': raise ContactError('unauthorized')
            if path == 'account/whoami': return {'user_id': '@bob:local', 'device_id': 'B'}
            if path == 'pushers/set': return {}
            if path.endswith('joined_members'): return {'joined': {'@bob:local': {}, '@alice:local': {}}}
            if path.endswith('m.room.encryption/'): return {'algorithm': 'm.megolm.v1.aes-sha2'}
            if path.endswith('m.room.create/'): return {}
            raise AssertionError(path)
        matrix_patch = patch.object(token_server.Handler, 'matrix', matrix)
        matrix_patch.start()
        self.addCleanup(matrix_patch.stop)
        self.server = token_server.ControlServer(('127.0.0.1', 0), token_server.Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def request(self, path, body, bearer='matrix-token'):
        request = urllib.request.Request(f'http://127.0.0.1:{self.server.server_port}' + path,
            json.dumps(body).encode(), {'Authorization': 'Bearer ' + bearer})
        try:
            with urllib.request.urlopen(request, timeout=5) as response: return response.status, json.load(response)
        except urllib.error.HTTPError as error: return error.code, json.load(error)

    def test_registration_uses_authenticated_identity_and_revokes_its_own_pusher(self):
        body = {'action': 'register', 'token': 'f' * 100, 'user': '@mallory:local', 'device': 'M'}
        self.assertEqual(self.request('/push/android', body, bearer='other')[0], 401)
        status, result = self.request('/push/android', body)
        self.assertEqual(status, 200)
        self.assertEqual(self.store.android_tokens('@bob:local', 'B'), [result['binding']])
        self.assertEqual(self.store.android_tokens('@mallory:local', 'M'), [])
        self.assertEqual(self.request('/push/android', {'action': 'remove'})[0], 200)
        self.assertEqual(self.store.android_tokens('@bob:local', 'B'), [])

    def test_native_resolution_and_decline_cannot_act_for_another_binding(self):
        binding = self.store.register_android('@alice:local', 'A', 'a' * 100)
        call = self.request('/push/call', {'action': 'invite', 'room': '!room:local', 'session': 'call-1'})[1]['call']
        body = {'notice': call}
        self.assertEqual(self.request('/push/android/resolve', body, bearer=binding)[1]['kind'], 'call')
        other = self.store.register_android('@mallory:local', 'M', 'm' * 100)
        self.assertEqual(self.request('/push/android/resolve', body, bearer=other)[0], 410)
        self.assertEqual(self.request('/push/android/action', {**body, 'action': 'decline'}, bearer=binding)[0], 200)
        self.assertTrue(self.request('/push/call', {'action': 'status', 'session': 'call-1'})[1]['declined'])
