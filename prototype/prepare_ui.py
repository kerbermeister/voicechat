#!/usr/bin/env python3
"""Disposable UI account without consuming the email verification rate limit."""
import hashlib
import hmac
import json
import secrets
import time
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1] / '.prototype'
secret = json.loads((root / 'secrets.json').read_text())['registration']
username = 'ui_' + str(time.time_ns())
password = secrets.token_urlsafe(24)
url = 'http://localhost:8008/_synapse/admin/v1/register'
with urllib.request.urlopen(url, timeout=10) as response:
    nonce = json.load(response)['nonce']
mac = hmac.new(secret.encode(), '\0'.join([nonce, username, password, 'notadmin']).encode(), hashlib.sha1).hexdigest()
request = urllib.request.Request(url, json.dumps(dict(nonce=nonce, username=username, password=password, admin=False, mac=mac)).encode(), {'Content-Type': 'application/json'})
with urllib.request.urlopen(request, timeout=10) as response:
    assert json.load(response)['user_id'] == f'@{username}:voicechat.local'
for name, data in [
    ('registered-account.json', dict(username=username, password=password)),
    ('android-ui.json', dict(UI_USERNAME=username, UI_PASSWORD=password)),
]:
    path = root / name
    path.touch(mode=0o600, exist_ok=True)
    path.chmod(0o600)
    path.write_text(json.dumps(data))
print('Disposable UI fixture prepared')
