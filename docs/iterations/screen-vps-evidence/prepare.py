"""Prepare private server-issued sessions for the published-client media smoke."""
import json
import os
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[3]
private = root / '.prototype/screen-vps-test'
private.mkdir(parents=True, exist_ok=True)
private.chmod(0o700)
ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', 'root@84.200.80.13']
fixture = private / 'accounts.json'
if fixture.exists():
    users = [a['user_id'] for a in json.loads(fixture.read_text())['accounts']]
    assert all(re.fullmatch(r'@new_(anna|boris|vera)_[0-9]+:univc[.]duckdns[.]org', u) for u in users)
    query = "SELECT COUNT(*) FROM users WHERE name IN (" + ','.join("'" + u + "'" for u in users) + ") AND deactivated=0"
    code = 'import subprocess\nprint(subprocess.check_output(' + repr(['docker', 'exec', 'voicechat-postgres-1', 'psql', '-U', 'synapse', '-d', 'synapse', '-At', '-c', query]) + ',text=True).strip())'
    assert subprocess.check_output([*ssh, 'python3 -'], input=code.encode()).strip() == b'0', 'Clean up the previous fixture first'
source = (root / 'prototype/seed_device_link.py').read_text()
old = """            if registered.get('access_token'):
                request(matrix, '/_matrix/client/v3/logout', {}, registered['access_token'])
            session = request(matrix, '/_matrix/client/v3/login',
                dict(type='m.login.password', user=username, password=password))
"""
assert old in source
source = source.replace(old, "            session = registered\n            assert session.get('access_token') and session.get('device_id')\n", 1)
old = "accounts.append(dict(username=username, password=password, user_id=session['user_id']))"
assert old in source
source = source.replace(old, "accounts.append(dict(username=username, password=password, user_id=session['user_id'], session=session))", 1)
old = "        for session in sessions:\n            request(matrix, '/_matrix/client/v3/logout', {}, session['access_token'])"
assert old in source
source = source.replace(old, '        pass  # Fixture sessions are revoked by cleanup.py.', 1)
subprocess.run([*ssh, 'docker exec -i voicechat-synapse-1 python3 - --config /data/homeserver.yaml --output /data/screen-vps-test-20261024.json'], input=source.encode(), stdout=subprocess.DEVNULL, check=True)
data = subprocess.check_output([*ssh, 'docker exec voicechat-synapse-1 cat /data/screen-vps-test-20261024.json'])
with os.fdopen(os.open(fixture, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600), 'wb') as output:
    output.write(data)
print('Disposable server-issued sessions prepared; no credentials printed')
