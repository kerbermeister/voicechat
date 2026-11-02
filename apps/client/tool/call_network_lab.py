"""Serve the renderer fixture with a disposable, loopback-only TURN/netem lab."""
import argparse
import base64
import hashlib
import hmac
import json
import mimetypes
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'prototype'))
from check_route_turn import reserve_range
from check_three_vps import image

PROFILES = {
    'clean': ['delay', '0ms'],
    'delay': ['delay', '40ms'],
    'loss': ['loss', '2%'],
    'offline': ['loss', '100%'],
}


def asset_path(root, request_path):
    try:
        path = (root / unquote(urlsplit(request_path).path).lstrip('/')).resolve()
        return path if path.is_relative_to(root) and path.is_file() else None
    except (ValueError, OSError):
        return None


def require_local_docker():
    context = subprocess.check_output(['docker', 'context', 'inspect'], text=True)
    endpoint = json.loads(context)[0]['Endpoints']['docker']['Host']
    if not endpoint.startswith('unix://'):
        raise ValueError('A local Unix-socket Docker context is required')
    if any(os.environ.get(key) for key in ('DOCKER_HOST', 'DOCKER_CONTEXT')):
        raise ValueError('Unset Docker endpoint overrides; select the local context explicitly')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--web-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--netem-image', default='voicechat-network-probe:fixture')
    parser.add_argument('--port', type=int, default=7390)
    parser.add_argument('--transport', choices=('udp', 'tcp'), default='udp')
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error('Use an unprivileged port')
    web_root = args.web_root.resolve()
    if not (web_root / 'main.dart.js').is_file():
        parser.error('Build call_renderer_fixture.dart first')
    # No implicit remote Docker target: namespace capabilities belong only to this lab.
    try:
        require_local_docker()
    except ValueError as error:
        parser.error(str(error))
    project = 'voicechat-call-net-' + uuid.uuid4().hex[:10]
    origin = f'http://127.0.0.1:{args.port}'
    nonce = secrets.token_hex(24)
    secret = secrets.token_hex(32)
    first, sockets = reserve_range()
    with tempfile.TemporaryDirectory(prefix=project) as temporary:
        folder = Path(temporary)
        folder.chmod(0o700)
        config = '\n'.join([
            'listening-port=3478', 'fingerprint', 'use-auth-secret',
            'static-auth-secret=' + secret, 'realm=call-network-lab',
            f'min-port={first}', f'max-port={first + 7}', 'cli=off',
            'no-tls', 'no-dtls', 'no-multicast-peers', 'allow-loopback-peers',
            'external-ip=127.0.0.1', 'user-quota=8', 'total-quota=16',
            'log-file=stdout',
        ]) + '\n'
        (folder / 'turn.conf').write_text(config)
        (folder / 'turn.conf').chmod(0o600)
        services = {
            'turn': {
                'image': image('turn'), 'command': ['-c', '/turn.conf'],
                'volumes': ['./turn.conf:/turn.conf:ro'],
                'ports': ['127.0.0.1::3478/tcp', '127.0.0.1::3478/udp'] + [
                    f'127.0.0.1:{p}:{p}/udp' for p in range(first, first + 8)
                ],
                'mem_limit': '128m', 'cpus': .5,
            },
            'netem': {
                'image': args.netem_image, 'entrypoint': ['/bin/sh', '-c'],
                'command': ['sleep infinity'], 'network_mode': 'service:turn',
                'cap_add': ['NET_ADMIN'], 'read_only': True, 'mem_limit': '64m',
            },
        }
        compose = folder / 'compose.json'
        compose.write_text(json.dumps({'name': project, 'services': services}))
        command = ['docker', 'compose', '-f', str(compose)]
        current = 'clean'
        qdiscs = []
        lock = threading.Lock()

        def profile(name):
            nonlocal current
            if name not in PROFILES:
                raise ValueError('Unknown profile')
            with lock:
                for device in ('lo', 'eth0'):
                    subprocess.run([
                        *command, 'exec', '-T', 'netem', 'tc', 'qdisc', 'replace',
                        'dev', device, 'root', 'netem', *PROFILES[name],
                    ], check=True, capture_output=True, timeout=10)
                current = name

        server = None
        expiry = None
        try:
            for item in sockets:
                item.close()
            subprocess.run([*command, 'up', '-d', '--wait', '--wait-timeout', '45'],
                           check=True, timeout=60)
            address = subprocess.check_output(
                [*command, 'port', '--protocol', args.transport, 'turn', '3478'],
                text=True).strip()
            if not address.startswith('127.0.0.1:'):
                raise ValueError('TURN must bind loopback')
            username = f'{int(time.time()) + 900}:call-lab'
            password = base64.b64encode(hmac.digest(
                secret.encode(), username.encode(), hashlib.sha1)).decode()
            profile('clean')

            class Handler(BaseHTTPRequestHandler):
                def reply(self, status, data, mime='application/json'):
                    body = data if isinstance(data, bytes) else json.dumps(data).encode()
                    self.send_response(status)
                    for key, value in {
                        'Content-Type': mime, 'Content-Length': str(len(body)),
                        'Cache-Control': 'no-store',
                        'Cross-Origin-Opener-Policy': 'same-origin',
                        'Cross-Origin-Embedder-Policy': 'require-corp',
                    }.items():
                        self.send_header(key, value)
                    self.end_headers()
                    self.wfile.write(body)

                def valid_host(self):
                    return self.headers.get('Host') == f'127.0.0.1:{args.port}'

                def do_GET(self):
                    if not self.valid_host():
                        return self.reply(403, {'error': 'forbidden'})
                    if self.path == '/turn.json':
                        return self.reply(200, {
                            'iceTransportPolicy': 'relay',
                            'iceServers': [{'urls': f'turn:{address}?transport={args.transport}',
                                            'username': username, 'credential': password}],
                            'lab_key': nonce, 'profile': current,
                        })
                    path = asset_path(web_root, self.path)
                    if path is None:
                        return self.reply(404, {'error': 'not_found'})
                    return self.reply(200, path.read_bytes(),
                                      mimetypes.guess_type(path)[0] or 'application/octet-stream')

                def do_POST(self):
                    if (not self.valid_host() or self.headers.get('Origin') != origin or
                            self.headers.get('X-Lab-Key') != nonce):
                        return self.reply(403, {'error': 'forbidden'})
                    try:
                        size = int(self.headers.get('Content-Length', '0'))
                        if not 0 < size <= 200000:
                            return self.reply(400, {'error': 'invalid_size'})
                        data = json.loads(self.rfile.read(size))
                        if not isinstance(data, dict):
                            return self.reply(400, {'error': 'invalid_request'})
                        if self.path == '/profile':
                            if (not isinstance(data.get('profile'), str) or
                                    data['profile'] not in PROFILES):
                                return self.reply(400, {'error': 'unknown_profile'})
                            qdiscs.append({'profile': current, **{
                                device: subprocess.check_output([
                                    *command, 'exec', '-T', 'netem', 'tc', '-s',
                                    'qdisc', 'show', 'dev', device,
                                ], text=True, timeout=10)
                                for device in ('lo', 'eth0')
                            }})
                            profile(data['profile'])
                            return self.reply(200, {'profile': current})
                        if self.path == '/result':
                            samples = data.get('samples')
                            if (data.get('rtp_recovered') is not True or not isinstance(samples, list)
                                    or len(samples) != 51):
                                return self.reply(400, {'error': 'invalid_result'})
                            args.output.parent.mkdir(parents=True, exist_ok=True)
                            args.output.write_text(json.dumps({
                                'synthetic_media': True, 'physical_lip_sync_measured': False,
                                'transport': 'TURN ' + args.transport.upper(),
                                'namespace_only': True,
                                'profiles': PROFILES, 'qdiscs': qdiscs, 'result': data,
                            }, indent=2) + '\n')
                            return self.reply(200, {'saved': True})
                        return self.reply(404, {'error': 'not_found'})
                    except (ValueError, KeyError):
                        return self.reply(400, {'error': 'invalid_request'})
                    except (subprocess.SubprocessError, OSError):
                        return self.reply(500, {'error': 'fixture_operation_failed'})

            server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
            expiry = threading.Timer(900, server.shutdown)
            expiry.daemon = True
            expiry.start()
            print(json.dumps({'ready': True, 'project': project,
                              'compose': str(compose),
                              'url': origin + '/index.html?network_lab=1'}), flush=True)
            server.serve_forever()
        finally:
            if expiry:
                expiry.cancel()
            if server:
                server.server_close()
            for item in sockets:
                item.close()
            subprocess.run([*command, 'down', '--volumes', '--remove-orphans'],
                           check=True, timeout=60)


if __name__ == '__main__':
    main()
