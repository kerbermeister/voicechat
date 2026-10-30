"""Native LiveKit signaling recovery through disposable loopback B/C proxies.

No microphone/camera capture, production access, or claim of decoded media E2EE.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import uuid

from check_three_vps import ROOT, fault_server
from check_route_turn import reserve_range


def token(identity, key, secret):
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value, separators=(',', ':')).encode()).decode().rstrip('=')
    now = int(time.time())
    body = encode({'alg': 'HS256', 'typ': 'JWT'}) + '.' + encode({
        'iss': key, 'sub': identity, 'nbf': now - 10, 'exp': now + 900,
        'video': {'roomJoin': True, 'room': 'route-probe', 'canPublish': True,
                  'canSubscribe': True, 'canPublishData': True}})
    signature = base64.urlsafe_b64encode(hmac.digest(secret.encode(), body.encode(), hashlib.sha256)).decode().rstrip('=')
    return body + '.' + signature


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', type=Path, required=True)
    args = parser.parse_args()
    project = 'voicechat-livekit-' + uuid.uuid4().hex[:12]
    first, held = reserve_range()
    key, secret = 'local-probe', secrets.token_hex(32)
    with tempfile.TemporaryDirectory(prefix=project) as temporary:
        root = Path(temporary)
        (root / 'livekit.json').write_text(json.dumps({
            'port': 7880, 'bind_addresses': ['0.0.0.0'], 'keys': {key: secret},
            'rtc': {'port_range_start': first, 'port_range_end': first + 7,
                    'use_external_ip': False, 'node_ip': '127.0.0.1'},
        }))
        sfu = (ROOT / 'infra/control.Dockerfile').read_text().splitlines()[0].split()[1]
        caddy = (ROOT / 'infra/web.Dockerfile').read_text().splitlines()[0].split()[1]
        if any('@sha256:' not in value for value in (sfu, caddy)):
            raise ValueError('Pinned fixture images required')
        services = {'sfu': {'image': sfu, 'command': ['--config', '/livekit.json'],
            'volumes': ['./livekit.json:/livekit.json:ro'],
            'ports': [f'127.0.0.1:{port}:{port}/udp' for port in range(first, first + 8)]}}
        for role in ('b', 'c'):
            health = json.dumps({'schema': 1, 'service_id': 'media-probe', 'edge_id': role,
                                 'age_ms': 0, 'matrix': True, 'control': True}, separators=(',', ':'))
            (root / (role + '.Caddyfile')).write_text('''{
    admin off
    auto_https off
}
:80 {
    handle /health/route {
        header Content-Type application/json
        respond `''' + health + '''`
    }
    handle {
        reverse_proxy sfu:7880
    }
}
''')
            service = 'front-b' if role == 'b' else 'edge-c'
            if role == 'b':
                # Keep readiness alive when only the WSS upstream is killed.
                path = root / 'b.Caddyfile'
                path.write_text(path.read_text().replace('reverse_proxy sfu:7880', 'reverse_proxy edge-b:80'))
                (root / 'signal-b.Caddyfile').write_text('{\n admin off\n auto_https off\n}\n:80 {\n reverse_proxy sfu:7880\n}\n')
                services['edge-b'] = {'image': caddy,
                    'volumes': ['./signal-b.Caddyfile:/etc/caddy/Caddyfile:ro']}
            services[service] = {'image': caddy, 'ports': ['127.0.0.1::80'],
                'volumes': ['./' + role + '.Caddyfile:/etc/caddy/Caddyfile:ro'],
                'healthcheck': {'test': ['CMD', 'wget', '-q', '-O', '/dev/null', 'http://127.0.0.1/'],
                                'interval': '1s', 'timeout': '2s', 'retries': 30}}
        compose = root / 'compose.json'
        compose.write_text(json.dumps({'name': project, 'services': services}))
        command = ['docker', 'compose', '-f', str(compose)]
        faults, thread, fault_secret = fault_server(command)
        try:
            for item in held: item.close()
            subprocess.run([*command, 'up', '-d', '--wait', '--wait-timeout', '60'], check=True)
            edges = []
            for role in ('b', 'c'):
                address = subprocess.check_output([*command, 'port', 'front-b' if role == 'b' else 'edge-c', '80'], text=True).strip()
                if not address.startswith('127.0.0.1:'):
                    raise ValueError('Loopback proxy required')
                edges.append({'id': role, 'origin': 'http://' + address, 'turn_host': 'turn-' + role + '.localhost'})
            config = {'schema': 1, 'service_id': 'media-probe', 'matrix_server_name': 'media.localhost',
                      'canonical_origin': 'http://localhost:9', 'web_origins': ['http://localhost:9'], 'edges': edges}
            defines = {'ROUTE_CONFIG': json.dumps(config, separators=(',', ':')),
                       'LIVEKIT_TEST_ALICE': token('alice', key, secret),
                       'LIVEKIT_TEST_BOB': token('bob', key, secret),
                       'ROUTE_TEST_FAULTS': 'http://127.0.0.1:' + str(faults.server_port),
                       'ROUTE_TEST_FAULT_SECRET': fault_secret}
            # Keep synthetic tokens out of process command lines and public evidence.
            define_file = root / 'client.json'
            define_file.write_text(json.dumps(defines)); define_file.chmod(0o600)
            logs = ROOT / '.prototype/three-vps'
            logs.mkdir(mode=0o700, parents=True, exist_ok=True)
            log = logs / (project + '.log')
            print('Native LiveKit output: ' + str(log), flush=True)
            env = {**os.environ, 'LC_ALL': 'en_US.UTF-8', 'LC_CTYPE': 'en_US.UTF-8', 'LANG': 'en_US.UTF-8'}
            with log.open('w') as output:
                log.chmod(0o600)
                subprocess.run([str(args.flutter.resolve()), 'test', '--no-pub', '-d', 'macos',
                    '--dart-define-from-file=' + str(define_file), 'integration_test/route_livekit_test.dart'],
                    cwd=ROOT / 'apps/client', env=env, stdout=output, stderr=subprocess.STDOUT, check=True)
            print('PASS: native LiveKit data delivery before and after proxy loss', flush=True)
        except subprocess.CalledProcessError:
            raise SystemExit('Local LiveKit proof failed; inspect the private test log') from None
        finally:
            for item in held: item.close()
            faults.shutdown(); faults.server_close(); thread.join()
            subprocess.run([*command, 'down', '--volumes', '--remove-orphans'], check=True)


if __name__ == '__main__':
    main()
