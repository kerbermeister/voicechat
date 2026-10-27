#!/usr/bin/env python3
"""Disposable local Matrix identities for the P2P integration test; no production accounts."""
import hashlib
import hmac
import json
import secrets
import sys
import time
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1] / '.prototype'
accounts_path = root / 'p2p-test-accounts.json'
fixture_path = root / 'p2p-matrix-test.json'
base = 'http://127.0.0.1:8008'

def post(path, payload, token=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(base + path, json.dumps(payload).encode(), headers)
    with urllib.request.urlopen(req, timeout=20) as response:
        return json.load(response)

if sys.argv[1:] == ['cleanup']:
    if accounts_path.exists():
        for account in json.loads(accounts_path.read_text()):
            assert account['username'].startswith('p2p_')
            post('/_matrix/client/v3/account/deactivate', {'auth': {
                'type': 'm.login.password', 'identifier': {'type': 'm.id.user', 'user': account['username']},
                'password': account['password']}, 'erase': True}, account['access_token'])
        accounts_path.unlink()
    fixture_path.unlink(missing_ok=True)
    print('Disposable P2P accounts deactivated')
    raise SystemExit()
if sys.argv[1:]:
    raise SystemExit('Usage: prepare_p2p.py [cleanup]')
if accounts_path.exists():
    raise SystemExit('P2P fixture already exists; clean it up before a new run')
secret = json.loads((root / 'secrets.json').read_text())['registration']
run = str(int(time.time())) + secrets.token_hex(3)
accounts, fixture = [], {'P2P_RUN': run}
for role in ['sender', 'receiver']:
    name, password = f'p2p_{role}_{run}', secrets.token_urlsafe(24)
    with urllib.request.urlopen(base + '/_synapse/admin/v1/register', timeout=20) as response:
        nonce = json.load(response)['nonce']
    mac = hmac.new(secret.encode(), '\0'.join([nonce, name, password, 'notadmin']).encode(), hashlib.sha1).hexdigest()
    account = post('/_synapse/admin/v1/register', {'nonce': nonce, 'username': name, 'password': password, 'admin': False, 'mac': mac})
    accounts.append({'username': name, 'password': password, 'access_token': account['access_token']})
    fixture[f'P2P_{role.upper()}_USER'] = name
    fixture[f'P2P_{role.upper()}_PASSWORD'] = password
    accounts_path.write_text(json.dumps(accounts)); accounts_path.chmod(0o600)
fixture_path.write_text(json.dumps(fixture)); fixture_path.chmod(0o600)
print('Disposable P2P Matrix fixture prepared:', run)
