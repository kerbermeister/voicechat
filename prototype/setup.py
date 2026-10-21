#!/usr/bin/env python3
"""Generate local-only configuration. Never reuse these accounts for production."""
import json
import secrets
from contacts import ContactStore
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
out = ROOT / '.prototype'
out.mkdir(mode=0o700, exist_ok=True)
ContactStore()
(out / "contacts").chmod(0o700)
secret_file = out / 'secrets.json'
if not secret_file.exists():
    secret_file.write_text(json.dumps({k: secrets.token_hex(32) for k in
        ['postgres', 'registration', 'macaroon', 'livekit', 'turn', 'policy']}, indent=2))
    secret_file.chmod(0o600)
s = json.loads(secret_file.read_text())
if 'policy' not in s:
    s['policy'] = secrets.token_hex(32)
    secret_file.write_text(json.dumps(s, indent=2))
    secret_file.chmod(0o600)
if 'turn' not in s:
    s['turn'] = secrets.token_hex(32)
    secret_file.write_text(json.dumps(s, indent=2))
    secret_file.chmod(0o600)
(out / 'postgres.env').write_text(f'POSTGRES_PASSWORD={s["postgres"]}\nPOSTGRES_USER=synapse\nPOSTGRES_DB=synapse\nPOSTGRES_INITDB_ARGS=--encoding=UTF8 --locale=C\n')
(out / 'homeserver.yaml').write_text(f'''server_name: voicechat.local
public_baseurl: http://localhost:8008/
pid_file: /data/homeserver.pid
modules:
  - module: voicechat_policy.ContactPolicy
    config:
      url: http://host.docker.internal:8090/internal/contact-authorized
      secret: "{s['policy']}"
listeners:
  - port: 8008
    type: http
    tls: false
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client]
        compress: false
database:
  name: psycopg2
  args:
    user: synapse
    password: "{s['postgres']}"
    database: synapse
    host: postgres
    cp_min: 2
    cp_max: 5
media_store_path: /data/media_store
signing_key_path: /data/voicechat.signing.key
registration_shared_secret: "{s['registration']}"
macaroon_secret_key: "{s['macaroon']}"
experimental_features:
  msc2654_enabled: true
enable_registration: true
registrations_require_3pid: [email]
enable_registration_without_verification: false
email:
  smtp_host: mailpit
  smtp_port: 1025
  require_transport_security: false
  enable_tls: false
  notif_from: 'VoiceChat <noreply@voicechat.local>'
  app_name: VoiceChat
user_directory:
  search_all_users: true
turn_uris: ['turn:localhost:3478?transport=tcp']
turn_shared_secret: "{s['turn']}"
turn_user_lifetime: 1h
turn_allow_guests: false
report_stats: false
trusted_key_servers: []
federation_domain_whitelist: []
# Local multi-device tests log in repeatedly from one loopback address.
rc_login:
  address:
    per_second: 20
    burst_count: 100
  account:
    per_second: 20
    burst_count: 100
rc_message:
  per_second: 20
  burst_count: 100
''')
(out / 'livekit.yaml').write_text(f'''port: 7880
bind_addresses: ['0.0.0.0']
rtc:
  tcp_port: 7881
  port_range_start: 50100
  port_range_end: 50200
  use_external_ip: false
  node_ip: 127.0.0.1
keys:
  prototype: "{s['livekit']}"
room:
  max_participants: 10
''')
(out / 'turnserver.conf').write_text(f'''listening-port=3478
fingerprint
use-auth-secret
static-auth-secret={s['turn']}
realm=voicechat.local
listening-ip=0.0.0.0
relay-ip=0.0.0.0
min-port=49160
max-port=49200
cli=off
no-tls
no-multicast-peers
# Loopback is intentional for this private, loopback-published laboratory only.
allow-loopback-peers
''')
for p in out.glob('*'):
    if p.is_file(): p.chmod(0o600)
print('Local configuration generated in .prototype/ (gitignored).')
