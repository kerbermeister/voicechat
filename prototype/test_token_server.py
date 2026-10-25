"""Trust-boundary tests; no Docker or real account required."""
import io
import json
import threading
import unittest
import urllib.error
import urllib.request
import tempfile
from contacts import ContactStore, ContactError
from call_control import CallStore
from unittest.mock import patch, Mock
import token_server


class AdmissionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = token_server.ControlServer(('127.0.0.1', 0), token_server.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def request(self, body=None, auth='Bearer test', path='/token'):
        if path == '/token' and isinstance(body, dict): body = {'protocol_version': 1, **body}
        request = urllib.request.Request(
            f'http://127.0.0.1:{self.server.server_port}{path}',
            None if body is None else json.dumps(body).encode(), {'Authorization': auth})
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def test_missing_auth_and_bad_input(self):
        def identity(handler, path):
            if handler.headers.get('Authorization') != 'Bearer test': raise ContactError('unauthorized')
            return {'user_id': '@alice:local', 'device_id': 'DEVICE'}
        with patch.object(token_server.Handler, 'matrix', identity):
            self.assertEqual(self.request({'room_id': '!room:local', 'session': 'test'}, '')[0], 401)
            self.assertEqual(self.request({'room_id': {}, 'session': 'test'})[0], 400)
            self.assertEqual(self.request({'room_id': '!room:local', 'session': ''})[0], 400)
            for mode in ('true', 1, None, {}):
                self.assertEqual(self.request({'room_id': '!room:local', 'session': 'test', 'video': mode})[0], 400)

    def test_presence_is_limited_to_authenticated_accepted_contacts(self):
        with tempfile.TemporaryDirectory() as directory:
            store = ContactStore(directory + '/contacts.sqlite')
            store.request('@alice:local', '@bob:local', '!pair:local')
            store.set_policy('@pending:local', False)
            store.request('@alice:local', '@pending:local', '!pending:local')
            def identity(handler, path):
                if handler.headers.get('Authorization') != 'Bearer test': raise ContactError('unauthorized')
                return {'user_id': '@alice:local'}
            with patch.object(token_server, '_contacts', store), patch.object(token_server.Handler, 'matrix', identity), patch.object(token_server, 'contact_presence', return_value={'presence': 'offline', 'last_active_ago': 45000}) as fetch:
                path = '/presence?user_id=%40bob%3Alocal'
                self.assertEqual(self.request(path=path), (200, {'presence': 'offline', 'last_active_ago': 45000}))
                for target in ('%40eve%3Alocal', '%40pending%3Alocal', '%40alice%3Alocal'):
                    self.assertEqual(self.request(path='/presence?user_id=' + target)[0], 403)
                self.assertEqual(self.request(auth='', path=path)[0], 403)
                self.assertEqual(fetch.call_count, 1)
                fetch.side_effect = OSError('offline')
                self.assertEqual(self.request(path=path)[0], 503)
                fetch.side_effect = None
                fetch.return_value = {'presence': 'invented'}
                self.assertEqual(self.request(path=path)[0], 503)
                fetch.return_value = []
                self.assertEqual(self.request(path=path)[0], 503)

    def test_contact_consent_uses_authenticated_user_and_real_encrypted_pair(self):
        with tempfile.TemporaryDirectory() as directory:
            store = ContactStore(directory + '/contacts.sqlite')
            store.set_policy('@bob:local', False)
            member = lambda user: {'type': 'm.room.member', 'state_key': user,
                                  'content': {'membership': 'join' if user == '@alice:local' else 'invite'}}
            marker = {'type': 'dev.voicechat.kind', 'content': {'kind': 'direct', 'owner': '@alice:local', 'peer': '@bob:local'}}
            state = [member('@alice:local'), member('@bob:local'), marker,
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
                state.remove(marker)
                self.assertEqual(self.request(request, path='/contacts')[0], 403, 'Two-person groups must not bypass group invitation consent')
                state.insert(0, marker)
                state.append(member('@eve:local'))
                self.assertEqual(self.request(request, path='/contacts')[0], 403)
                state.pop()
                state[-1]['content']['algorithm'] = 'plaintext'
                self.assertEqual(self.request(request, path='/contacts')[0], 403)

    def test_contact_link_boundary_and_lost_publication_reply(self):
        with tempfile.TemporaryDirectory() as directory:
            store = ContactStore(directory + '/contacts.sqlite')
            owner, user = '@owner:local', '@user:local'
            store.set_policy(owner, False)
            caller = owner
            device = 'ONE'
            state = [
                {'type': 'm.room.member', 'state_key': user, 'content': {'membership': 'join'}},
                {'type': 'm.room.member', 'state_key': owner, 'content': {'membership': 'invite'}},
                {'type': 'dev.voicechat.kind', 'state_key': '', 'content': {'kind': 'direct', 'owner': user, 'peer': owner}},
                {'type': 'm.room.encryption', 'content': {'algorithm': 'm.megolm.v1.aes-sha2'}},
                {'type': 'm.room.join_rules', 'content': {'join_rule': 'invite'}},
            ]
            def matrix(handler, path, body=None):
                if handler.headers.get('Authorization') != 'Bearer test': raise ContactError('unauthorized')
                if path == 'account/whoami': return {'user_id': caller, 'device_id': device}
                if path == 'keys/query': return {'device_keys': {user: {device: {'keys': {'curve25519:' + device: 'A' * 43}}}}}
                return state
            calls = []
            def publish(job):
                calls.append(job.copy())
                if len(calls) == 1: raise OSError('Reply lost after Synapse committed')
                return '$same-event'
            def request(body=None, auth='Bearer test'):
                return self.request(body, auth=auth, path='/contact-links')
            with patch.object(token_server, '_contacts', store), patch.object(token_server.Handler, 'matrix', matrix), patch.object(token_server, 'publish_scheduled', side_effect=publish):
                self.assertEqual(request({'action': 'create'}, auth='')[0], 401)
                self.assertEqual(request()[0], 404, 'GET/preview bots must never create or accept')
                status, created = request({'action': 'create'})
                self.assertEqual(status, 200)
                token = created['token']
                caller = user
                preview = {'action': 'inspect', 'token': token}
                self.assertFalse(request(preview)[1]['claimed'])
                self.assertEqual(store.list(user), [])
                accept = {'action': 'accept', 'token': token, 'room_id': '!room:local'}
                marker = state.pop(2)
                self.assertEqual(request(accept)[0], 403)
                state.insert(2, marker)
                state.append({'type': 'm.room.member', 'state_key': '@eve:local', 'content': {'membership': 'join'}})
                self.assertEqual(request(accept)[0], 403)
                state.pop()
                state[-1]['content']['join_rule'] = 'public'
                self.assertEqual(request(accept)[0], 403)
                state[-1]['content']['join_rule'] = 'invite'
                self.assertFalse(request(preview)[1]['claimed'])
                status, receipt = request(accept)
                self.assertEqual(status, 200)
                self.assertTrue(store.accepted(owner, user))
                self.assertFalse(store.policy(owner))
                identifier = receipt['id']
                caller = '@eve:local'
                self.assertEqual(request(preview)[1]['error'], 'link_used')
                self.assertEqual(request(accept)[0], 403)
                self.assertEqual(request({'action': 'greet', 'id': identifier})[0], 403)
                caller = user
                self.assertEqual(request({'action': 'greet', 'id': identifier, 'payload': {'body': 'Привет'}, 'audience': 'a' * 64})[0], 400)
                payload = {'algorithm': 'm.megolm.v1.aes-sha2', 'ciphertext': 'YWJj', 'session_id': 'B' * 43, 'sender_key': 'A' * 43, 'device_id': device}
                status, _ = request({'action': 'greet', 'id': identifier, 'payload': payload, 'audience': 'a' * 64})
                self.assertEqual(status, 503)
                self.assertTrue(request(preview)[1]['prepared'])
                device = 'TWO'
                token_server._contacts = ContactStore(store.path)
                status, sent = request({'action': 'greet', 'id': identifier})
                self.assertEqual((status, sent), (200, {'event_id': '$same-event'}))
                self.assertEqual(calls[0], calls[1], 'Retry uses the original device, ciphertext and transaction')
                self.assertEqual(request({'action': 'greet', 'id': identifier}), (200, sent))
                self.assertEqual(len(calls), 2)
                self.assertEqual(request(accept)[1]['event_id'], '$same-event')

    def test_report_rejects_unknown_fields_and_non_strings(self):
        for body in [
            {'run': 'test', 'role': 'web', 'stage': 'ok', 'key': 'secret'},
            {'run': 'test', 'role': 'web', 'stage': {}},
            {'stage': 'ok'},
        ]:
            self.assertEqual(self.request(body, path='/report')[0], 400)

    def test_previews_require_identity_and_are_rate_limited(self):
        token_server._preview_calls.clear()
        def identity(handler, path):
            if handler.headers.get('Authorization') != 'Bearer test': raise ContactError('unauthorized')
            return {'user_id': '@preview:local'}
        with patch.object(token_server.Handler, 'matrix', identity), patch.object(token_server, 'preview', return_value={'url': 'https://example.com', 'title': 'Title', 'description': ''}) as preview:
            self.assertEqual(self.request({'url': 'https://example.com'}, '', '/link-preview')[0], 401)
            self.assertEqual(self.request({'url': 'https://example.com', 'extra': True}, path='/link-preview')[0], 400)
            for _ in range(10): self.assertEqual(self.request({'url': 'https://example.com'}, path='/link-preview')[0], 200)
            self.assertEqual(self.request({'url': 'https://example.com'}, path='/link-preview')[0], 429)
            self.assertEqual(preview.call_count, 10)

    def test_public_fingerprint_report(self):
        with patch('pathlib.Path.write_text'), patch('pathlib.Path.chmod'):
            status, _ = self.request({'run': 'test', 'role': 'web', 'stage': 'identity',
                'user_id': '@alice:local', 'device_id': 'DEVICE', 'fingerprint': 'public-only'}, path='/report')
        self.assertEqual(status, 200)

    def test_membership_encryption_and_grant(self):
        original = urllib.request.urlopen
        for membership, algorithm, video, expected in [
            ('leave', 'm.megolm.v1.aes-sha2', True, 403),
            ('join', 'plaintext', True, 403),
            ('join', 'm.megolm.v1.aes-sha2', False, 200),
            ('join', 'm.megolm.v1.aes-sha2', True, 200),
        ]:
            def upstream(request, *args, **kwargs):
                if ':8008/' not in request.full_url:
                    return original(request, *args, **kwargs)
                if request.full_url.endswith('whoami'):
                    data = {'user_id': '@alice:local', 'device_id': 'DEVICE'}
                elif request.full_url.endswith('keys/query'):
                    data = {'device_keys': {'@alice:local': {'DEVICE': {'user_id': '@alice:local', 'device_id': 'DEVICE',
                            'keys': {'curve25519:DEVICE': 'A'*43, 'ed25519:DEVICE': 'B'*43}}}}}
                elif request.full_url.endswith('joined_members'):
                    data = {'joined': {'@alice:local': {}} if membership == 'join' else {}}
                else:
                    data = {'algorithm': algorithm}
                return io.BytesIO(json.dumps(data).encode())
            store = Mock()
            store.roster.return_value = []
            store.admission.return_value = {'identity': '@alice:local/DEVICE', 'generation': 'vc-' + 'a'*48,
                                           'lease_id': 'b'*64, 'lease_seconds': 30, 'roster': []}
            with patch('urllib.request.urlopen', side_effect=upstream), patch.object(token_server, 'call_store', return_value=store):
                status, body = self.request({'room_id': '!room:local', 'session': 'test', 'video': video})
            self.assertEqual(status, expected)
            if status == 200:
                import base64
                payload = body['token'].split('.')[1]
                grant = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
                self.assertEqual(grant['sub'], '@alice:local/DEVICE')
                self.assertEqual(grant['exp'] - grant['nbf'], 65)
                self.assertEqual(grant['video']['canPublishSources'], ['microphone', 'camera'] if video else ['microphone'])
                self.assertFalse(grant['video']['canPublishData'])
                self.assertNotIn('roomAdmin', grant['video'])
                self.assertNotIn('key', grant)

    def test_matrix_outage_does_not_renew_a_lease_or_disguise_itself_as_revocation(self):
        with tempfile.TemporaryDirectory() as directory:
            now = [1000.]
            media = Mock()
            store = CallStore(directory + '/calls.sqlite', media, lambda: now[0])
            who = {'user_id': '@alice:local', 'device_id': 'DEVICE'}
            try:
                store.admission('!room:local', 'test', False, who, 'curve', 'ed')
            except ValueError as error:
                self.assertEqual(str(error), 'generation_settling')
            now[0] += 1
            grant = store.admission('!room:local', 'test', False, who, 'curve', 'ed')
            expires = store.roster('!room:local', 'test')[0]['expires']
            body = {'room_id': '!room:local', 'session': 'test', 'lease_id': grant['lease_id']}
            for code, expected in ((401, 401), (403, 403), (429, 503), (500, 503), (503, 503)):
                error = urllib.error.HTTPError('http://matrix.invalid', code, 'unavailable', {}, None)
                with patch.object(token_server.Handler, 'matrix', side_effect=error), \
                     patch.object(token_server, 'call_store', return_value=store):
                    status, response = self.request(body)
                self.assertEqual(status, expected)
                self.assertEqual(response['error'], 'upstream_unavailable' if expected == 503 else 'matrix_denied')
                self.assertEqual(store.roster('!room:local', 'test')[0]['expires'], expires)
            now[0] = expires + 1
            store.sweep()
            self.assertEqual(store.roster('!room:local', 'test'), [])
            media.assert_called_with('DeleteRoom', {'room': grant['generation']})


if __name__ == '__main__':
    unittest.main()
