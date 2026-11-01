"""Opt-in transport smoke inside the Synapse container; creates/deactivates its own fixtures.

No real installation token, message contents or media are used. Credentials stay
in this process and the server. This is not proof of FCM/phone/E2EE delivery.
"""
import hashlib
import hmac
import json
from pathlib import Path
import secrets
import urllib.error
import urllib.parse
import urllib.request

import yaml

MATRIX = 'http://127.0.0.1:8008'
CONTROL = 'http://control:8090'


def api(base, path, token='', body=None, method=None):
    request = urllib.request.Request(base + path,
        None if body is None else json.dumps(body).encode(),
        {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'}, method=method)
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def expect(result, status=200):
    assert result[0] == status, f'Unexpected fixture API status: {result[0]} (expected {status})'
    return result[1]


def main():
    config = yaml.safe_load(Path('/data/homeserver.yaml').read_text())
    shared = config['registration_shared_secret']
    fixtures = []

    def login(user, password):
        return expect(api(MATRIX, '/_matrix/client/v3/login', body={
            'type': 'm.login.password', 'identifier': {'type': 'm.id.user', 'user': user}, 'password': password}))

    def account():
        name, password = 'android_push_fixture_' + secrets.token_hex(8), secrets.token_urlsafe(32)
        nonce = expect(api(MATRIX, '/_synapse/admin/v1/register'))['nonce']
        mac = hmac.new(shared.encode(), '\0'.join((nonce, name, password, 'notadmin')).encode(), hashlib.sha1).hexdigest()
        expect(api(MATRIX, '/_synapse/admin/v1/register', body={
            'nonce': nonce, 'username': name, 'password': password, 'admin': False, 'mac': mac}))
        session = login(name, password)
        fixtures.append((session, password))
        return session, password

    def matrix(session, path, body=None, method=None):
        return api(MATRIX, '/_matrix/client/v3/' + path, session['access_token'], body, method)

    def control(session, path, body):
        return api(CONTROL, path, session['access_token'], body)

    def password_auth(session, password, extra=None):
        return {'type': 'm.login.password', 'identifier': {'type': 'm.id.user', 'user': session['user_id']},
                'password': password, **({'session': extra} if extra else {})}

    try:
        caller, caller_password = account()
        receiver, receiver_password = account()
        room = expect(matrix(caller, 'createRoom', {'preset': 'public_chat', 'initial_state': [
            {'type': 'm.room.encryption', 'state_key': '', 'content': {'algorithm': 'm.megolm.v1.aes-sha2'}}]}))['room_id']
        expect(matrix(receiver, 'join/' + urllib.parse.quote(room, safe=''), {}))
        session = secrets.token_hex(16)
        notice = expect(control(caller, '/push/call', {'action': 'invite', 'session': session, 'room': room, 'video': False}))['call']
        binding = expect(control(receiver, '/push/android', {'action': 'register', 'token': 'synthetic-fixture-' + secrets.token_hex(64)}))['binding']
        result = expect(api(CONTROL, '/push/android/resolve', binding, {'notice': notice}))
        assert result['kind'] == 'call' and result['room'] == room and result['video'] is False
        expect(api(CONTROL, '/push/android/resolve', secrets.token_urlsafe(32), {'notice': notice}), 410)
        # No call wakeup to the synthetic FCM token: remove it before acceptance.
        expect(control(receiver, '/push/android', {'action': 'remove'}))
        expect(control(receiver, '/push/call', {'action': 'accept', 'session': session}))
        other = login(receiver['user_id'], receiver_password)
        fixtures[-1] = (other, receiver_password)
        expect(control(other, '/push/call', {'action': 'accept', 'session': session}), 409)
        expect(control(other, '/push/call', {'action': 'end', 'session': session}), 403)
        binding = expect(control(receiver, '/push/android', {'action': 'register', 'token': 'synthetic-fixture-' + secrets.token_hex(64)}))['binding']
        target = 'devices/' + urllib.parse.quote(receiver['device_id'], safe='')
        response = matrix(other, target, {}, 'DELETE')
        if response[0] == 401:
            response = matrix(other, target, {'auth': password_auth(other, receiver_password, response[1].get('session'))}, 'DELETE')
        expect(response)
        expect(api(CONTROL, '/push/android/resolve', binding, {'notice': notice}), 403)
        expect(control(caller, '/push/call', {'action': 'end', 'session': session}))
        proof = {'schema': 1, 'real_synapse_and_control': True,
            'device_bound_resolve': True, 'foreign_binding_rejected': True,
            'atomic_answer': True, 'foreign_end_rejected': True, 'revoked_device_rejected': True,
            'real_fcm_delivery_tested': False, 'media_decryption_tested': False}
    finally:
        for session, password in fixtures:
            response = matrix(session, 'account/deactivate', {'auth': password_auth(session, password), 'erase': False})
            if response[0] == 401:
                response = matrix(session, 'account/deactivate', {
                    'auth': password_auth(session, password, response[1].get('session')), 'erase': False})
            expect(response)
    print(json.dumps({**proof, 'fixtures_deactivated': True}))


if __name__ == '__main__':
    main()
