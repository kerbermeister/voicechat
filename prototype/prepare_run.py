#!/usr/bin/env python3
"""Create fresh disposable users and ignored dart-define fixtures per test run."""
import hashlib
import hmac
import json
import secrets
import time
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1] / '.prototype'
secret = json.loads((root / 'secrets.json').read_text())['registration']
run = str(int(time.time()))
config = {'RUN_ID': run, 'MATRIX_URL': 'http://localhost:8008',
          'TOKEN_URL': 'http://localhost:8090', 'LIVEKIT_URL': 'ws://localhost:7880'}
url = 'http://127.0.0.1:8008/_synapse/admin/v1/register'
for role in ['alice', 'bob', 'carol']:
    name, password = role + run, secrets.token_urlsafe(24)
    nonce = json.load(urllib.request.urlopen(url, timeout=10))['nonce']
    msg = '\0'.join([nonce, name, password, 'notadmin']).encode()
    data = dict(nonce=nonce, username=name, password=password, admin=False,
                mac=hmac.new(secret.encode(), msg, hashlib.sha1).hexdigest())
    req = urllib.request.Request(url, json.dumps(data).encode(), {'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=10) as response: json.load(response)
    config[role.upper() + '_USER'] = name
    config[role.upper() + '_PASSWORD'] = password
for role in ['web', 'android']:
    path = root / (role + '.json')
    path.write_text(json.dumps({**config, 'ROLE': role}, indent=2))
    path.chmod(0o600)
print('Fresh run configured:', run)
