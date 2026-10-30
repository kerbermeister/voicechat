"""Disposable two-TURN fixture for a real browser ICE-restart probe (loopback only)."""
import argparse
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import uuid
from check_three_vps import image, ROOT


def reserve_range():
    # Hold a short contiguous UDP range until its Compose definition is ready.
    for _ in range(100):
        sockets = []
        start = 30000 + secrets.randbelow(20000)
        try:
            for port in range(start, start + 8):
                item = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sockets.append(item)
                item.bind(('127.0.0.1', port))
            return start, sockets
        except OSError:
            for item in sockets: item.close()
    raise RuntimeError('No free local relay range')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node', required=True, type=Path)
    args = parser.parse_args()
    project = 'voicechat-turn-' + uuid.uuid4().hex[:12]
    sockets = []
    with tempfile.TemporaryDirectory(prefix=project) as temporary:
        root = Path(temporary)
        services, credentials = {}, {}
        for role in ('b', 'c'):
            first, held = reserve_range(); sockets.extend(held)
            secret = secrets.token_hex(32)
            config = '\n'.join(['listening-port=3478', 'fingerprint', 'use-auth-secret',
                'static-auth-secret=' + secret, 'realm=local-route-test',
                f'min-port={first}', f'max-port={first+7}', 'cli=off', 'no-tls', 'no-dtls',
                'no-multicast-peers', 'allow-loopback-peers', 'external-ip=127.0.0.1',
                'user-quota=8', 'total-quota=16', 'log-file=stdout']) + '\n'
            (root / (role + '.conf')).write_text(config)
            services[role] = {'image': image('turn'), 'command': ['-c', '/turn.conf'],
                'volumes': ['./' + role + '.conf:/turn.conf:ro'],
                'ports': ['127.0.0.1::3478/tcp'] + [f'127.0.0.1:{p}:{p}/udp' for p in range(first, first+8)]}
            credentials[role] = secret
        compose = root / 'compose.json'
        compose.write_text(json.dumps({'name': project, 'services': services}))
        command = ['docker', 'compose', '-f', str(compose)]
        try:
            for item in sockets: item.close()
            subprocess.run([*command, 'up', '-d'], check=True)
            ports = {role: subprocess.check_output([*command, 'port', role, '3478'], text=True).strip()
                     for role in ('b', 'c')}
            if any(not value.startswith('127.0.0.1:') for value in ports.values()):
                raise ValueError('Loopback TURN required')
            env = {**os.environ, 'ROUTE_TURN_FIXTURE': json.dumps({'ports': ports, 'secrets': credentials, 'compose': str(compose)})}
            subprocess.run([str(args.node.resolve()), str(ROOT / 'prototype/check_route_turn.cjs')],
                           env=env, check=True)
        finally:
            for item in sockets: item.close()
            subprocess.run([*command, 'down', '--volumes', '--remove-orphans'], check=True)


if __name__ == '__main__':
    main()
