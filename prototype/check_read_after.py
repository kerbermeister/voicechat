"""Isolated real-Synapse check; run inside the pinned image with network=none.

Uses fictional accounts, opaque ciphertext and disposable SQLite. No host ports,
production services, credentials, real users or device-media claims.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


def main():
    import yaml  # Supplied by the pinned Synapse image.
    root = Path(tempfile.mkdtemp(prefix='voicechat-read-after-'))
    config = {
        'server_name': 'chat.test', 'public_baseurl': 'http://127.0.0.1:18008',
        'pid_file': str(root / 'server.pid'),
        'listeners': [{'port': 18008, 'bind_addresses': ['127.0.0.1'], 'type': 'http', 'tls': False,
                       'resources': [{'names': ['client'], 'compress': False}]}],
        'database': {'name': 'sqlite3', 'args': {'database': str(root / 'server.db')}},
        'media_store_path': str(root / 'media'), 'signing_key_path': str(root / 'signing.key'),
        'macaroon_secret_key': 'disposable-macaroon-secret-0123456789',
        'form_secret': 'disposable-form-secret-0123456789', 'report_stats': False,
        'enable_registration': True, 'enable_registration_without_verification': True,
        'enable_ephemeral_messages': True, 'trusted_key_servers': [],
        'rc_registration': {'per_second': 100, 'burst_count': 100},
        'rc_message': {'per_second': 100, 'burst_count': 100},
        'modules': [{'module': 'voicechat_policy.ContactPolicy', 'config': {
            'url': 'http://127.0.0.1:9/internal/contact-authorized', 'secret': 'test-policy-secret-' + 'x' * 32}}],
    }
    path = root / 'server.yaml'
    path.write_text(yaml.safe_dump(config))
    log = (root / 'server.log').open('w+')
    process = None

    def api(method, path, content=None, token=None):
        data = None if content is None else json.dumps(content).encode()
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        request = Request('http://127.0.0.1:18008' + path, data=data, headers=headers, method=method)
        try:
            with urlopen(request, timeout=10) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            return error.code, json.load(error)

    def start_server():
        nonlocal process
        process = subprocess.Popen(['python', '-m', 'synapse.app.homeserver', '-c', str(path)], stdout=log, stderr=log,
                                   env={**os.environ, 'PYTHONPATH': '/modules'})
        for _ in range(150):
            if process.poll() is not None:
                log.flush()
                raise AssertionError('Synapse failed to start: ' + (root / 'server.log').read_text()[-8000:])
            try:
                if api('GET', '/_matrix/client/versions')[0] == 200:
                    return
            except (URLError, TimeoutError):
                pass
            time.sleep(.1)
        raise AssertionError('Synapse startup timed out')

    def register(name):
        code, body = api('POST', '/_matrix/client/v3/register', {
            'username': name, 'password': 'disposable-password', 'auth': {'type': 'm.login.dummy'}})
        assert code == 200, (code, body)
        return body['user_id'], body['access_token']

    def send(room, name, delay=2, token=None):
        content = {'algorithm': 'm.megolm.v1.aes-sha2', 'ciphertext': 'opaque-fixture-ciphertext',
                   'sender_key': 'A' * 43, 'session_id': 'B' * 43, 'device_id': 'TEST',
                   'dev.voicechat.read_after_seconds': delay}
        return api('PUT', '/_matrix/client/v3/rooms/' + quote(room, safe='') + '/send/m.room.encrypted/' + name,
                   content, token)

    def read(token, **fields):
        return api('POST', '/_synapse/client/voicechat-read-after', fields, token)

    def event(token, room, identifier):
        return api('GET', '/_matrix/client/v3/rooms/' + quote(room, safe='') + '/event/' + quote(identifier, safe=''), token=token)

    try:
        start_server()
        alice, a = register('alice')
        bob, b = register('bob')
        _, stranger = register('stranger')
        code, body = api('POST', '/_matrix/client/v3/createRoom', {
            'preset': 'trusted_private_chat', 'invite': [bob],
            'initial_state': [{'type': 'dev.voicechat.kind', 'state_key': '', 'content': {'kind': 'direct', 'owner': alice, 'peer': bob}},
                              {'type': 'm.room.encryption', 'state_key': '', 'content': {'algorithm': 'm.megolm.v1.aes-sha2'}}]}, a)
        assert code == 200, (code, body)
        room = body['room_id']
        assert api('POST', '/_matrix/client/v3/join/' + quote(room, safe=''), {}, b)[0] == 200
        code, body = send(room, 'first', token=a)
        assert code == 200, (code, body)
        identifier = body['event_id']
        time.sleep(2.3)
        assert event(a, room, identifier)[1]['content']['ciphertext'] == 'opaque-fixture-ciphertext', 'Expired before read'
        assert read(a, room_id=room, event_id=identifier)[0] == 403
        assert read(stranger, room_id=room, event_id=identifier)[0] == 403
        assert read(b, room_id=room, event_ids=[identifier])[1]['deadlines'] == {}
        code, first = read(b, room_id=room, event_id=identifier)
        assert code == 200, (code, first)
        code, repeat = read(b, room_id=room, event_id=identifier, read_at=first['server_time_ms'] + 3600000)
        assert code == 200 and repeat['expires_at'] == first['expires_at'], 'Read extended the first deadline'
        time.sleep(2.5)
        assert event(a, room, identifier)[1]['content'] == {}, 'Ciphertext not erased'
        assert identifier in read(a, room_id=room, event_ids=[identifier])[1]['unavailable']
        code, body = api('POST', '/_matrix/client/v3/createRoom', {'preset': 'private_chat'}, a)
        assert code == 200
        group = body['room_id']
        assert send(group, 'group-refused', token=a)[0] == 403
        assert read(a, room_id=group, event_ids=[])[0] == 403
        code, body = send(room, 'restart', delay=8, token=a)
        assert code == 200
        restart_id = body['event_id']
        code, started = read(b, room_id=room, event_id=restart_id)
        assert code == 200
        process.terminate(); process.wait(timeout=15)
        start_server()
        remaining = max(0, (started['expires_at'] - time.time() * 1000) / 1000)
        time.sleep(remaining + 1)
        assert event(b, room, restart_id)[1]['content'] == {}, 'Restart lost expiry'
        print('PASS: real pinned Synapse — unread retained; recipient only; no timer extension; ciphertext erased; group rejected; expiry survives restart')
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
        log.close()


if __name__ == '__main__':
    main()
