#!/usr/bin/env python3
"""Loopback-only real Synapse auth/block check. Disposable local accounts only."""
import base64
import json
import secrets
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
import token_server
from contacts import ContactStore
from stream_http import StreamService

ROOT = Path(__file__).resolve().parents[1]
MATRIX = 'http://127.0.0.1:8008/_matrix/client/v3/'


def matrix(method, path, body=None, token=None):
    req = urllib.request.Request(MATRIX + path,
        None if body is None else json.dumps(body).encode(),
        {'Content-Type': 'application/json', **({'Authorization': 'Bearer ' + token} if token else {})},
        method=method)
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.load(response)


def main():
    accounts = json.loads((ROOT / '.prototype/accounts.json').read_text())
    clients = []
    server = thread = service = None
    try:
        for name in ('alice', 'bob', 'carol'):
            account = accounts[name]
            logged = matrix('POST', 'login', {'type': 'm.login.password',
                'identifier': {'type': 'm.id.user', 'user': account['username']},
                'password': account['password'], 'device_id': 'streams-' + secrets.token_hex(6)})
            clients.append(logged)
            user, device, token = (logged[k] for k in ('user_id', 'device_id', 'access_token'))
            # Synthetic device keys: this test proves authentication/transport,
            # not signatures, trust or E2EE. The crypto probe is separate.
            keys = {kind + ':' + device: base64.b64encode(secrets.token_bytes(32)).decode().rstrip('=')
                    for kind in ('curve25519', 'ed25519')}
            matrix('POST', 'keys/upload', {'device_keys': {'user_id': user, 'device_id': device,
                'algorithms': ['m.olm.v1.curve25519-aes-sha2'], 'keys': keys,
                'signatures': {user: {'ed25519:' + device: 'synthetic-fixture'}}}}, token)
        a, b, outsider = clients
        with tempfile.TemporaryDirectory() as directory:
            contacts = ContactStore(Path(directory) / 'contacts.sqlite')
            contacts.request(a['user_id'], b['user_id'], '!stream-fixture:voicechat.local')
            service = StreamService(Path(directory) / 'streams.sqlite', contacts,
                token_server.stream_pair_allowed,
                lambda user, device: token_server.validate_push_device(user, device, ''),
                token_server.media_api, enabled=True)
            token_server._streams = service
            server = token_server.ControlServer(('127.0.0.1', 0), token_server.Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            def command(client, op, **body):
                req = urllib.request.Request(f'http://127.0.0.1:{server.server_port}/streams',
                    json.dumps(dict(protocol_version=1, operation=op, **body)).encode(),
                    {'Authorization': 'Bearer ' + client['access_token'], 'Content-Type': 'application/json'})
                try:
                    response = urllib.request.urlopen(req, timeout=10)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    return response.status, json.load(response)
            status, stream = command(a, 'start', request_id='attempt', title='private local stream',
                description='', audience=[b['user_id']], comments=True, duration=60)
            assert status == 200, stream.get('error', 'start failed')
            identifier = stream['id']
            assert command(outsider, 'discover')[1]['streams'] == []
            assert command(b, 'join', stream_id=identifier)[0] == 200
            path = 'user/' + urllib.parse.quote(a['user_id'], safe='') + '/account_data/m.ignored_user_list'
            try:
                matrix('PUT', path, {'ignored_users': {b['user_id']: {}}}, a['access_token'])
                for attempt in range(20):
                    if command(b, 'info', stream_id=identifier)[0] == 404: break
                    time.sleep(.2)
                else: raise AssertionError('block did not revoke access')
            finally:
                matrix('PUT', path, {'ignored_users': {}}, a['access_token'])
            revision = command(a, 'info', stream_id=identifier)[1]['revision']
            assert command(a, 'stop', stream_id=identifier, revision=revision)[0] == 200
            print(json.dumps({'result': 'PASS', 'real_matrix_auth': True,
                'real_symmetric_block': True, 'closed_stream_hidden': True,
                'synthetic_device_keys': True, 'media_checked': False}))
    finally:
        if server:
            server.shutdown()
            server.server_close()
            thread.join()
        if service:
            service.core.close()
        for client in clients:
            matrix('POST', 'logout', {}, client['access_token'])


if __name__ == '__main__':
    main()
