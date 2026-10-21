#!/usr/bin/env python3
"""Provision disposable test users without printing passwords or tokens."""
import hashlib
import hmac
import json
import secrets
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1] / '.prototype'
secret = json.loads((root / 'secrets.json').read_text())['registration']
path = root / 'accounts.json'
accounts = json.loads(path.read_text()) if path.exists() else {}
url = 'http://127.0.0.1:8008/_synapse/admin/v1/register'
for name in ['alice', 'bob', 'carol']:
    if name in accounts: continue
    password = secrets.token_urlsafe(24)
    nonce = json.load(urllib.request.urlopen(url))['nonce']
    msg = '\0'.join([nonce, name, password, 'notadmin']).encode()
    payload = dict(nonce=nonce, username=name, password=password, admin=False,
                   mac=hmac.new(secret.encode(), msg, hashlib.sha1).hexdigest())
    req = urllib.request.Request(url, json.dumps(payload).encode(),
                                 {'Content-Type': 'application/json'})
    with urllib.request.urlopen(req) as r: json.load(r)
    accounts[name] = {'username': name, 'password': password}
    path.write_text(json.dumps(accounts, indent=2))
    path.chmod(0o600)
print('Disposable accounts ready; credentials: .prototype/accounts.json')
