"""Check actual Synapse expiry on a disposable account; opaque ciphertext, no E2EE claim."""
import hashlib
import hmac
import json
from pathlib import Path
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request

root = Path(__file__).resolve().parents[1]
base = 'http://localhost:8008'


def request(route, body=None, token=None, method=None):
    headers = {'Content-Type': 'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(base + route, None if body is None else json.dumps(body).encode(),
                                 headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


username, password = 'expiry_probe_' + str(time.time_ns()), secrets.token_urlsafe(24)
route = '/_synapse/admin/v1/register'
status, data = request(route)
assert status == 200, 'Local Matrix must be ready'
nonce = data['nonce']
secret = json.loads((root / '.prototype/secrets.json').read_text())['registration']
mac = hmac.new(secret.encode(), '\0'.join((nonce, username, password, 'notadmin')).encode(), hashlib.sha1).hexdigest()
assert request(route, dict(nonce=nonce, username=username, password=password, admin=False, mac=mac))[0] == 200
status, login = request('/_matrix/client/v3/login', dict(type='m.login.password', user=username, password=password))
assert status == 200
token = login['access_token']


def matrix(route, body=None, method=None):
    return request('/_matrix/client/v3/' + route, body, token, method)


try:
    status, data = matrix('createRoom', {'initial_state': [{'type': 'm.room.encryption', 'state_key': '',
        'content': {'algorithm': 'm.megolm.v1.aes-sha2'}}]})
    assert status == 200
    room = urllib.parse.quote(data['room_id'], safe='')
    def send(content):
        return matrix('rooms/' + room + '/send/m.room.encrypted/' + secrets.token_hex(16), content, 'PUT')
    opaque = {'algorithm': 'm.megolm.v1.aes-sha2', 'ciphertext': 'disposable-opaque-fixture'}
    for ttl in (None, True, 0, 9, 11, 610):
        assert send({**opaque, 'dev.voicechat.ttl_seconds': ttl})[0] == 403, 'Invalid duration accepted'
    assert send({**opaque, 'org.matrix.self_destruct_after': 9999999999999})[0] == 403
    before = int(time.time() * 1000)
    status, data = send({**opaque, 'dev.voicechat.ttl_seconds': 10,
                         'org.matrix.self_destruct_after': 9999999999999})
    assert status == 200, 'Temporary message rejected'
    event_id = data['event_id']
    event = 'rooms/' + room + '/event/' + urllib.parse.quote(event_id, safe='')
    status, data = matrix(event)
    assert status == 200 and data['content']['ciphertext'] == opaque['ciphertext']
    deadline = data['content']['org.matrix.self_destruct_after']
    assert before + 10000 <= deadline <= int(time.time() * 1000) + 10000, 'Client supplied expiry trusted'
    status, edited = send({**opaque, 'dev.voicechat.ttl_seconds':600,
        'm.relates_to': {'rel_type':'m.replace', 'event_id':event_id}})
    assert status == 200
    edit_path = 'rooms/' + room + '/event/' + urllib.parse.quote(edited['event_id'], safe='')
    status, edited = matrix(edit_path)
    assert status == 200 and edited['content']['org.matrix.self_destruct_after'] == deadline, 'Editing prolonged expiry'
    for _ in range(130):
        status, data = matrix(event)
        assert status == 200
        if not data['content']: break
        time.sleep(.1)
    assert not data['content'], 'Expired ciphertext remains available'
    assert int(time.time() * 1000) >= deadline
    assert not matrix(edit_path)[1]['content'], 'Expired replacement ciphertext remains available'
    ordinary_status, ordinary = send(opaque)
    assert ordinary_status == 200, 'Ordinary messages must keep working'
    assert send({**opaque, 'm.relates_to': {'rel_type':'m.replace', 'event_id':ordinary['event_id']}})[0] == 200
    (root / 'prototype/verified-temporary-server-run.json').write_text(json.dumps({
        'run': int(time.time()), 'result': 'PASS', 'scope': 'real Synapse expiry of opaque test ciphertext; not client E2EE',
        'invalid_durations_rejected': True, 'server_clock_used': True,
        'expired_ciphertext_unavailable': True,
        'editing_does_not_extend_expiry': True, 'ordinary_messages_and_edits_unchanged': True,
    }, indent=2) + '\n')
    print('PASS: temporary duration validated, server expiry overrides client timestamp, expired ciphertext unavailable')
finally:
    status, _ = matrix('account/deactivate', {'auth': {'type': 'm.login.password',
        'identifier': {'type': 'm.id.user', 'user': username}, 'password': password}, 'erase': True})
    assert status == 200, 'Disposable account cleanup failed'
