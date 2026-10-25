"""Create disposable users and encrypted groups; keep credentials out of logs."""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import time
import urllib.request


def seed(matrix, control, registration_secret, output):
    def request(base, route, body=None, token=None, method=None):
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        req = urllib.request.Request(base + route,
            data=json.dumps(body).encode() if body is not None else None,
            headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.load(response)

    accounts, sessions, rooms = [], [], []
    suffix = str(int(time.time()))
    try:
        for role in ('anna', 'boris', 'vera'):
            username, password = f'new_{role}_{suffix}', secrets.token_urlsafe(24)
            nonce = request(matrix, '/_synapse/admin/v1/register')['nonce']
            mac = hmac.new(registration_secret.encode(),
                '\0'.join((nonce, username, password, 'notadmin')).encode(), hashlib.sha1).hexdigest()
            registered = request(matrix, '/_synapse/admin/v1/register',
                dict(nonce=nonce, username=username, password=password, admin=False, mac=mac))
            if registered.get('access_token'):
                request(matrix, '/_matrix/client/v3/logout', {}, registered['access_token'])
            session = request(matrix, '/_matrix/client/v3/login',
                dict(type='m.login.password', user=username, password=password))
            sessions.append(session)
            accounts.append(dict(username=username, password=password, user_id=session['user_id']))
            # Save each created account immediately, including after partial failure.
            output.parent.mkdir(parents=True, exist_ok=True)
            descriptor = os.open(output, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, 'w') as file:
                json.dump(dict(accounts=accounts, rooms=rooms), file, ensure_ascii=False, indent=2)
        owner = sessions[0]
        def create(name, invitees, extra=()):
            return request(matrix, '/_matrix/client/v3/createRoom', dict(
                name=name, preset='private_chat', invite=invitees,
                initial_state=[dict(type='m.room.encryption', state_key='',
                    content=dict(algorithm='m.megolm.v1.aes-sha2')), *extra]),
                owner['access_token'])['room_id']
        directs = {session['user_id']: {} for session in sessions}
        for peer in sessions[1:]:
            room = create('Знакомство', [peer['user_id']], [dict(
                type='dev.voicechat.kind', state_key='', content=dict(
                    kind='direct', owner=owner['user_id'], peer=peer['user_id']))])
            request(control, '/contacts', dict(action='request', recipient=peer['user_id'], room_id=room), owner['access_token'])
            from urllib.parse import quote
            request(matrix, '/_matrix/client/v3/join/' + quote(room, safe=''), {}, peer['access_token'])
            directs[owner['user_id']][peer['user_id']] = [room]
            directs[peer['user_id']][owner['user_id']] = [room]
        for session in sessions:
            request(matrix, '/_matrix/client/v3/user/' + quote(session['user_id'], safe='') + '/account_data/m.direct',
                directs[session['user_id']], session['access_token'], method='PUT')
        for name in ('Семейный круг', 'Планы на выходные'):
            room = create(name, [s['user_id'] for s in sessions[1:]])
            from urllib.parse import quote
            for peer in sessions[1:]:
                request(matrix, '/_matrix/client/v3/join/' + quote(room, safe=''), {}, peer['access_token'])
            rooms.append(dict(name=name, room_id=room))
        output.write_text(json.dumps(dict(accounts=accounts, rooms=rooms), ensure_ascii=False, indent=2))
        output.chmod(0o600)
        print(f'Created {len(accounts)} users and {len(rooms)} encrypted groups; credentials: {output}')
    finally:
        for session in sessions:
            request(matrix, '/_matrix/client/v3/logout', {}, session['access_token'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--matrix', default='http://localhost:8008')
    parser.add_argument('--control', default='http://control:8090')
    args = parser.parse_args()
    if args.config.suffix == '.json':
        registration_secret = json.loads(args.config.read_text())['registration']
    else:
        import yaml
        registration_secret = yaml.safe_load(args.config.read_text())['registration_shared_secret']
    seed(args.matrix, args.control, registration_secret, args.output)
