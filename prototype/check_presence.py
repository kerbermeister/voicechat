#!/usr/bin/env python3
"""Real accepted contacts before the recipient joins their DM; disposable users only."""
import hashlib
import hmac
import json
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

def request(url, body=None, token=None, method=None):
    headers = {'Content-Type': 'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(url, None if body is None else json.dumps(body).encode(), headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as response: return response.status, json.load(response)
    except urllib.error.HTTPError as error: return error.code, json.load(error)

matrix = 'http://localhost:8008/_matrix/client/v3/'
register = 'http://localhost:8008/_synapse/admin/v1/register'
secret = json.loads((Path(__file__).resolve().parents[1] / '.prototype/secrets.json').read_text())['registration']
sessions = []
try:
    for role in ('sender', 'recipient'):
        name, password = f'presence_{role}_{time.time_ns()}', secrets.token_urlsafe(24)
        status, nonce = request(register)
        assert status == 200
        mac = hmac.new(secret.encode(), '\0'.join([nonce['nonce'], name, password, 'notadmin']).encode(), hashlib.sha1).hexdigest()
        assert request(register, dict(nonce=nonce['nonce'], username=name, password=password, admin=False, mac=mac))[0] == 200
        status, session = request(matrix + 'login', dict(type='m.login.password', user=name, password=password))
        assert status == 200
        sessions.append(session)
    first, second = sessions
    status, room = request(matrix + 'createRoom', {
        'invite': [second['user_id']], 'is_direct': True, 'preset': 'private_chat',
        'initial_state': [
            {'type': 'm.room.encryption', 'state_key': '', 'content': {'algorithm': 'm.megolm.v1.aes-sha2'}},
            {'type': 'dev.voicechat.kind', 'state_key': '', 'content': {'kind': 'direct', 'owner': first['user_id'], 'peer': second['user_id']}},
        ]}, first['access_token'])
    assert status == 200
    status, contact = request('http://localhost:8090/contacts', {'action': 'request', 'recipient': second['user_id'], 'room_id': room['room_id']}, first['access_token'])
    assert status == 200 and contact['state'] == 'accepted'
    peer = urllib.parse.quote(second['user_id'], safe='')
    assert request(matrix + 'presence/' + peer + '/status', token=first['access_token'])[0] == 403
    fallback = 'http://localhost:8090/presence?' + urllib.parse.urlencode({'user_id': second['user_id']})
    for presence in ('online', 'offline'):
        status, body = request(matrix + 'presence/' + peer + '/status', {'presence': presence}, second['access_token'], 'PUT')
        if status == 429:
            delay = body.get('retry_after_ms', 1000)
            assert isinstance(delay, int) and 0 <= delay <= 10000
            time.sleep((delay + 50) / 1000)
            status, body = request(matrix + 'presence/' + peer + '/status', {'presence': presence}, second['access_token'], 'PUT')
        assert status == 200, (status, body.get('errcode'))
        status, body = request(fallback, token=first['access_token'])
        assert status == 200 and body['presence'] == presence
        assert isinstance(body.get('last_active_ago'), int)
    assert request(fallback, token='invalid-token')[0] == 401
    assert request('http://localhost:8090/presence?user_id=%40stranger%3Avoicechat.local', token=first['access_token'])[0] == 403
    assert request('http://localhost:8008/_synapse/client/voicechat/presence?user_id=' + peer)[0] == 403
    print('PASS: actual online/offline and last activity before DM join; strangers and invalid tokens denied')
finally:
    for session in sessions: request(matrix + 'logout', {}, session['access_token'])
