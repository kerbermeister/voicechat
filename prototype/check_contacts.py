#!/usr/bin/env python3
"""Real local Synapse/API consent check; disposable users, no credentials in output."""
import hashlib
import hmac
import json
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

MATRIX = 'http://127.0.0.1:8008'
CONTROL = 'http://127.0.0.1:8090'

def api(base, path, token=None, body=None, method=None, expected=200):
    headers = {'Content-Type': 'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(base + path, None if body is None else json.dumps(body).encode(), headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            status, data = response.status, json.load(response)
    except urllib.error.HTTPError as error:
        status, data = error.code, json.load(error)
    assert status == expected, f'{path.split("?")[0]}: expected {expected}, got {status}'
    return data

def main():
    secret = json.loads((Path(__file__).resolve().parents[1] / '.prototype/secrets.json').read_text())['registration']
    users = []
    for role in ('first', 'second', 'third'):
        name, password = f'consent_{role}_{time.time_ns()}', secrets.token_urlsafe(24)
        nonce = api(MATRIX, '/_synapse/admin/v1/register')['nonce']
        message = '\0'.join((nonce, name, password, 'notadmin')).encode()
        api(MATRIX, '/_synapse/admin/v1/register', body=dict(nonce=nonce, username=name, password=password, admin=False,
            mac=hmac.new(secret.encode(), message, hashlib.sha1).hexdigest()))
        session = api(MATRIX, '/_matrix/client/v3/login', body={'type': 'm.login.password', 'user': name, 'password': password})
        users.append((session['user_id'], session['access_token']))
    (alice, at), (bob, bt), (carol, ct) = users
    control = lambda token, body: api(CONTROL, '/contacts', token, body)
    matrix = lambda path, token, body=None, **kw: api(MATRIX, '/_matrix/client/v3/' + path, token, body, **kw)
    def direct(user, token, peer):
        return matrix('createRoom', token, {
            'preset': 'private_chat', 'is_direct': True, 'invite': [peer],
            'initial_state': [
                {'type': 'm.room.encryption', 'state_key': '', 'content': {'algorithm': 'm.megolm.v1.aes-sha2'}},
                {'type': 'dev.voicechat.kind', 'state_key': '', 'content': {'kind': 'direct', 'owner': user, 'peer': peer}},
            ],
        })['room_id']
    control(bt, {'action': 'policy', 'allow_direct': False})
    room = direct(alice, at, bob)
    request = control(at, {'action': 'request', 'recipient': bob, 'room_id': room})
    assert request['state'] == 'pending'
    group = matrix('createRoom', at, {'preset': 'private_chat'})['room_id']
    path = 'rooms/' + urllib.parse.quote(group, safe='') + '/invite'
    matrix(path, at, {'user_id': bob}, expected=403)
    api(CONTROL, '/contacts', at, {'action': 'accept', 'id': request['id']}, expected=403)
    control(bt, {'action': 'accept', 'id': request['id']})
    matrix(path, at, {'user_id': bob})
    matrix(path, at, {'user_id': carol}, expected=403)
    room_path = 'rooms/' + urllib.parse.quote(room, safe='')
    matrix(room_path + '/invite', at, {'user_id': carol}, expected=403)
    matrix(room_path + '/state/m.room.name', at, {'name': 'Forbidden'}, method='PUT', expected=403)
    # Open-by-default requires no recipient decision, but groups remain explicit invites.
    open_room = direct(alice, at, carol)
    accepted = control(at, {'action': 'request', 'recipient': carol, 'room_id': open_room})
    assert accepted['state'] == 'accepted'
    matrix(path, at, {'user_id': carol})
    print('PASS: default-open/restricted contacts, consent authorization, group allowlist, direct-room immutability')

if __name__ == '__main__': main()
