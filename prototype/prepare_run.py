#!/usr/bin/env python3
"""Create fresh disposable users and ignored dart-define fixtures per test run."""
from itertools import combinations
from contacts import ContactStore
import hashlib
import hmac
import json
import secrets
import sys
import time
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1] / '.prototype'
secret = json.loads((root / 'secrets.json').read_text())['registration']
run = str(int(time.time()))
config = {'RUN_ID': run, 'MATRIX_URL': 'http://localhost:8008',
          'TOKEN_URL': 'http://localhost:8090', 'LIVEKIT_URL': 'ws://localhost:7880'}
if sys.argv[1:] not in ([], ['--load']): raise SystemExit('Usage: prepare_run.py [--load]')
roles = [f'load{i}' for i in range(11)] if '--load' in sys.argv else ['alice', 'bob', 'carol']
accounts = []
url = 'http://127.0.0.1:8008/_synapse/admin/v1/register'
for role in roles:
    name, password = role + run, secrets.token_urlsafe(24)
    nonce = json.load(urllib.request.urlopen(url, timeout=10))['nonce']
    msg = '\0'.join([nonce, name, password, 'notadmin']).encode()
    data = dict(nonce=nonce, username=name, password=password, admin=False,
                mac=hmac.new(secret.encode(), msg, hashlib.sha1).hexdigest())
    req = urllib.request.Request(url, json.dumps(data).encode(), {'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=10) as response: json.load(response)
    config[role.upper() + '_USER'] = name
    config[role.upper() + '_PASSWORD'] = password
    accounts.append({'username': name, 'password': password})
if '--load' in sys.argv: config['LOAD_ACCOUNTS'] = json.dumps(accounts)
# Disposable laboratory users explicitly consent to one another for this test.
store = ContactStore()
for first, second in combinations(roles, 2):
    store.request(f'@{first}{run}:voicechat.local', f'@{second}{run}:voicechat.local', f'!fixture-{run}-{first}-{second}:voicechat.local')
for role in ['web', 'android']:
    path = root / (role + '.json')
    path.write_text(json.dumps({**config, 'ROLE': role}, indent=2))
    path.chmod(0o600)
print('Fresh run configured:', run)
