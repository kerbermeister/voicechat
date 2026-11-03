"""Isolated TURN/TLS regression: injected relay sendto EPERM must not kill allocation."""
import argparse
import hashlib
import ipaddress
import json
import secrets
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

from check_three_vps import image, ROOT
sys.path.insert(0, str(ROOT / 'infra'))
sys.path.insert(0, str(ROOT / 'apps/client/tool'))
from call_network_lab import require_local_docker
from edge_turn import configuration
from entry_turn import COOKIE, allocate, attribute, credential, error_code, exchange, receive_message

PUBLIC_RELAY = '192.0.2.10'
DROP = b'vc-eperm-drop'
ECHO = '''import select,socket
sockets=[socket.socket(socket.AF_INET,socket.SOCK_DGRAM) for _ in range(2)]
for i,sock in enumerate(sockets):sock.bind(('0.0.0.0',56001+i))
while True:
 for sock in select.select(sockets,[],[])[0]:
  data,address=sock.recvfrom(4096);sock.sendto(data,address)
'''


def xor_peer(address, port):
    return attribute(0x12, struct.pack('!BBHI', 0, 1, port ^ (COOKIE >> 16),
                                      int(ipaddress.IPv4Address(address)) ^ COOKIE))


def active_allocation(stream, secret):
    udp = attribute(0x19, bytes([17, 0, 0, 0]))
    kind, challenge, _ = exchange(stream, 3, [udp])
    assert kind == 0x113 and error_code(challenge) == 401
    issued = credential(secret)
    username = issued['username'].encode()
    realm, nonce = challenge[0x14], challenge[0x15]
    key = hashlib.md5(username + b':' + realm + b':' + issued['credential'].encode()).digest()
    auth = [attribute(6, username), attribute(0x14, realm), attribute(0x15, nonce)]
    kind, result, verified = exchange(stream, 3, [udp, attribute(0xd, struct.pack('!I', 180)), *auth], key)
    assert kind == 0x103 and verified and 0x16 in result, 'Authenticated allocation required'
    assert struct.unpack('!I', result[0xd])[0] >= 120, 'Allocation must outlive the watchdog observation'
    return auth, key


def send_indication(stream, peer, port, payload):
    body = xor_peer(peer, port) + attribute(0x13, payload)
    stream.sendall(struct.pack('!HHI', 0x16, len(body), COOKIE) + secrets.token_bytes(12) + body)


def echo(stream, peer, port, payload):
    send_indication(stream, peer, port, payload)
    kind, response, _ = receive_message(stream, timeout=2)
    assert kind == 0x17 and response.get(0x13) == payload, 'Unexpected relay response'
    assert attribute(0x12, response[0x12]) == xor_peer(peer, port), 'Unexpected echo peer'


def exercise(stream, secret, peer, persistent, expect_closed):
    auth, key = active_allocation(stream, secret)
    for address in ('127.0.0.1', '10.88.0.1', '169.254.169.254', '192.168.1.1'):
        kind, result, verified = exchange(stream, 8, [xor_peer(address, 80), *auth], key)
        assert kind == 0x118 and error_code(result) == 403 and verified, 'Private peer policy changed'
    kind, _, verified = exchange(stream, 8, [xor_peer(peer, 56001), *auth], key)
    assert kind == 0x108 and verified, 'Fixture peer permission failed'
    echo(stream, peer, 56001, b'before-fault')
    send_indication(stream, peer, 56001, DROP)
    started = time.monotonic()
    try:
        echo(stream, peer, 56002, b'after-fault')
        survived = True
    except (OSError, ValueError):
        survived = False
    assert survived != expect_closed, 'Unexpected allocation survival after EPERM'
    if survived and not persistent:
        echo(stream, peer, 56001, DROP)  # The same flow works after the single dropped datagram.
    print(json.dumps({'phase': 'observing allocation past watchdog', 'survived': survived}), flush=True)
    healthy_echoes = 0
    while time.monotonic() - started < 67:
        if persistent:
            send_indication(stream, peer, 56001, DROP)
            echo(stream, peer, 56002, b'independent-peer')
            healthy_echoes += 1
        time.sleep(1)
    try:
        kind, result, verified = exchange(stream, 4, [attribute(0xd, struct.pack('!I', 120)), *auth], key)
        refresh = 200 if kind == 0x104 and verified else error_code(result)
    except (OSError, ValueError):
        refresh = 'connection_closed_or_timed_out'
    if expect_closed:
        assert refresh in (437, 'connection_closed_or_timed_out'), 'Old allocation unexpectedly refreshed'
    else:
        assert refresh == 200, 'Patched allocation did not survive watchdog'
        echo(stream, peer, 56002, b'after-refresh')
        if persistent:
            assert healthy_echoes >= 20, 'Persistent drop did not exercise independent peer'
        kind, _, verified = exchange(stream, 4, [attribute(0xd, bytes(4)), *auth], key)
        assert kind == 0x104 and verified, 'Patched allocation did not release normally'
    return {'survived': survived, 'refresh': refresh, 'healthy_peer_echoes': healthy_echoes,
            'private_peer_policy_verified': True, 'watchdog_observed_seconds': round(time.monotonic() - started, 1)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True, help='Locally built fault fixture image')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--expect-closed', action='store_true')
    parser.add_argument('--persistent', action='store_true')
    args = parser.parse_args()
    if args.expect_closed and args.persistent:
        parser.error('Persistent case requires a surviving patched allocation')
    require_local_docker()
    project = 'voicechat-turn-eperm-' + uuid.uuid4().hex[:10]
    secret = secrets.token_hex(32)
    with tempfile.TemporaryDirectory(prefix=project) as temporary:
        folder = Path(temporary)
        cert, private_key = folder / 'turn.crt', folder / 'turn.key'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
                        '-keyout', str(private_key), '-out', str(cert)], check=True, capture_output=True, timeout=15)
        private_key.chmod(0o644)  # Parent is 0700; only the disposable UID10001 mount needs read access.
        config = folder / 'turn.conf'
        config.touch(mode=0o644)
        services = {
            'peer': {'image': image('configure'), 'command': ['python', '-u', '-c', ECHO], 'mem_limit': '64m'},
            'turn': {'image': args.image, 'entrypoint': ['/bin/sh', '-c'],
                     'command': ['for i in $(seq 1 100); do test ! -s /turn.conf || exec /opt/turnserver-under-test -c /turn.conf; sleep .1; done; exit 1'],
                     'environment': {'VOICECHAT_TEST_EPERM_MODE': 'persistent' if args.persistent else 'once'},
                     'ports': ['127.0.0.1::5349/tcp'], 'cap_drop': ['ALL'],
                     'security_opt': ['no-new-privileges:true'], 'read_only': True,
                     'tmpfs': ['/tmp'], 'mem_limit': '128m',
                     'volumes': ['./turn.conf:/turn.conf:ro', './turn.crt:/tls/turn.crt:ro', './turn.key:/tls/turn.key:ro']},
        }
        compose = folder / 'compose.json'
        compose.write_text(json.dumps({'name': project, 'services': services}))
        command = ['docker', 'compose', '-f', str(compose)]

        def container_address(service):
            container = subprocess.check_output([*command, 'ps', '-q', service], text=True, timeout=10).strip()
            inspected = json.loads(subprocess.check_output(['docker', 'inspect', container], timeout=10))[0]
            networks = inspected['NetworkSettings']['Networks']
            assert set(networks) == {project + '_default'}, 'Fixture container left its network'
            return networks[project + '_default']['IPAddress']

        def connect():
            deadline = time.monotonic() + 15
            while True:
                try:
                    raw = socket.create_connection(('127.0.0.1', port), timeout=2)
                    try:
                        return context.wrap_socket(raw, server_hostname='localhost')
                    except BaseException:
                        raw.close()
                        raise
                except (ConnectionRefusedError, ConnectionResetError, ssl.SSLEOFError):
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(.1)

        try:
            subprocess.run([*command, 'up', '-d', '--wait', '--wait-timeout', '30'],
                           check=True, timeout=45, capture_output=True)
            peer = container_address('peer')
            config.write_text(configuration(secret, PUBLIC_RELAY, container_address('turn'), 'turn-fixture.invalid', peer))
            address = subprocess.check_output([*command, 'port', 'turn', '5349'], text=True, timeout=10).strip()
            assert address.startswith('127.0.0.1:'), 'Loopback only'
            port = int(address.split(':')[1])
            context = ssl.create_default_context(cafile=str(cert))
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            with connect() as stream:
                expired = credential(secret, expires=int(time.time()) - 60)
                allocate(stream, expired['username'], expired['credential'], relay_ip=PUBLIC_RELAY, rejected=True)
            with connect() as stream:
                result = exercise(stream, secret, peer, args.persistent, args.expect_closed)
            hashes = subprocess.check_output([*command, 'exec', '-T', 'turn', 'sha256sum',
                                             '/usr/bin/turnserver', '/opt/turnserver-under-test'], text=True, timeout=10)
            original, fixture = [row.split()[0] for row in hashes.splitlines()]
            assert original == fixture, 'Fault binary differs from image binary'
            logs = subprocess.run([*command, 'logs', '--no-color', 'turn'], capture_output=True,
                                  text=True, check=True, timeout=10)
            output = logs.stdout + logs.stderr
            injected = output.count('VOICECHAT_TEST_EPERM_INJECTED')
            warnings = output.count('UDP send failed with EPERM')
            assert injected == 1 and 'VOICECHAT_TEST_FAULT_LOADED' in output, 'No real sendto fault exercised'
            if args.expect_closed:
                assert 'udp send: Operation not permitted' in output
            else:
                assert 1 <= warnings <= (2 if args.persistent else 1), 'Warning not bounded'
                assert 'udp send: Operation not permitted' not in output, 'Old fatal handling still active'
            result.update(schema=1, image=args.image, binary_sha256=original, tls_verified=True,
                          expired_credential_rejected=True, syscall_fault='sendto:EPERM',
                          persistent=args.persistent, expected_closed=args.expect_closed,
                          rate_limited_warnings=warnings, namespace_only=True, media_saved=False)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(result, indent=2) + '\n')
            print(json.dumps(result), flush=True)
        except Exception:
            logs = subprocess.run([*command, 'logs', '--no-color', 'turn'], capture_output=True, text=True, timeout=10)
            diagnostic = logs.stdout + logs.stderr
            print(json.dumps({'fixture_error_lines': diagnostic.count('ERROR'),
                              'fault_loaded': 'VOICECHAT_TEST_FAULT_LOADED' in diagnostic,
                              'fault_injected': 'VOICECHAT_TEST_EPERM_INJECTED' in diagnostic}), file=sys.stderr)
            raise
        finally:
            subprocess.run([*command, 'down', '--volumes', '--remove-orphans'],
                           check=True, timeout=50, capture_output=True)


if __name__ == '__main__':
    main()
