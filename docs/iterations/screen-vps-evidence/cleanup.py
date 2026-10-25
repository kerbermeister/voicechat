"""Run inside the VPS Synapse container; only this preview's disposable fixture."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import time
import urllib.parse
import urllib.request
import yaml

accounts = json.loads(Path('/data/screen-vps-test-20261024.json').read_text())['accounts']
assert len(accounts) == 3
for account in accounts:
    assert re.fullmatch(r'new_(anna|boris|vera)_[0-9]+', account['username'])
    assert account['user_id'] == '@' + account['username'] + ':univc.duckdns.org'

def request(route, body=None, token=None):
    req = urllib.request.Request('http://localhost:8008' + route,
        json.dumps(body).encode() if body is not None else None,
        {'Content-Type': 'application/json', **({'Authorization': 'Bearer ' + token} if token else {})})
    with urllib.request.urlopen(req, timeout=20) as response:
        return json.load(response)

# A short-lived local operator avoids extra public password logins during cleanup.
private = Path('/data/screen-vps-cleanup-admin.json')
assert not private.exists(), 'Resolve the previous cleanup operator before creating another'
secret = yaml.safe_load(Path('/data/homeserver.yaml').read_text())['registration_shared_secret']
username, password = 'ssvps_cleanup_' + str(int(time.time())), secrets.token_urlsafe(32)
nonce = request('/_synapse/admin/v1/register')['nonce']
mac = hmac.new(secret.encode(), '\0'.join((nonce, username, password, 'admin')).encode(), hashlib.sha1).hexdigest()
session = request('/_synapse/admin/v1/register', dict(nonce=nonce, username=username, password=password, admin=True, mac=mac))
with os.fdopen(os.open(private, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'w') as output:
    json.dump(dict(username=username, password=password, **session), output)
for account in accounts:
    request('/_synapse/admin/v1/deactivate/' + urllib.parse.quote(account['user_id'], safe=''),
        {'erase': True}, session['access_token'])
request('/_matrix/client/v3/account/deactivate', {'auth': {'type': 'm.login.password',
    'identifier': {'type': 'm.id.user', 'user': session['user_id']}, 'password': password},
    'erase': True}, session['access_token'])
private.unlink()
print(json.dumps({'deactivated': len(accounts), 'temporary_cleanup_admin_deactivated': True,
    'private_admin_file_removed': True}))
