"""Real browser WASM signature, HTTP discovery and localStorage catalog proof.

Build locked assets with build_web_assets.py first. Serves only synthetic catalogs
and two generated crypto files on loopback; never reads application profiles.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
from route_catalog import public_key, sign


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', type=Path, required=True)
    parser.add_argument('--node', type=Path, required=True)
    args = parser.parse_args()
    assets = ROOT / 'apps/client/web/pkg'
    allowed = {'vodozemac_bindings_dart.js': 'text/javascript',
               'vodozemac_bindings_dart_bg.wasm': 'application/wasm'}
    if any(not (assets / name).is_file() for name in allowed):
        raise ValueError('Build pinned web crypto assets first')
    state = {'phase': 'initial', 'requests': {'b': 0, 'd': 0}, 'credentials_seen': False}
    catalogs = {}
    lock = threading.Lock()
    web_root = None

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass

        def respond(self, body, content_type='application/json', status=200):
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cross-Origin-Resource-Policy', 'cross-origin')
            self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
            self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.startswith('/pkg/') and self.path[5:] in allowed:
                name = self.path[5:]
                self.respond((assets / name).read_bytes(), allowed[name])
            elif self.path == '/.well-known/voicechat/routes.json':
                with lock:
                    state['requests'][self.server.edge] += 1
                    state['credentials_seen'] |= bool(self.headers.get('Authorization') or self.headers.get('Cookie'))
                    phase = state['phase']
                self.respond(catalogs[phase][self.server.edge], status=503 if phase == 'offline' else 200)
            elif self.path == '/fixture/status':
                with lock: body = json.dumps(state).encode()
                self.respond(body)
            else:
                relative = unquote(urlsplit(self.path).path).lstrip('/') or 'index.html'
                path = (web_root / relative).resolve()
                if path.is_relative_to(web_root) and path.is_file():
                    self.respond(path.read_bytes(), mimetypes.guess_type(path)[0] or 'application/octet-stream')
                else:
                    self.respond(b'{}', status=404)

        def do_POST(self):
            phase = self.path.removeprefix('/fixture/')
            if not self.path.startswith('/fixture/') or phase not in catalogs:
                self.respond(b'{}', status=404)
                return
            with lock: state['phase'] = phase
            self.respond(b'{}')

    servers = [ThreadingHTTPServer(('127.0.0.1', 0), Handler) for _ in range(2)]
    threads = []
    try:
        origins = ['http://127.0.0.1:' + str(server.server_port) for server in servers]
        edges = [{'id': name, 'origin': origin, 'turn_host': 'turn-' + name + '.localhost'}
                 for name, origin in zip(('b', 'd'), origins)]
        topology = {'schema': 1, 'service_id': 'web-proof-' + uuid.uuid4().hex[:12],
                    'matrix_server_name': 'catalog.localhost', 'canonical_origin': origins[0],
                    'web_origins': origins, 'edges': edges}
        bootstrap = {**topology, 'edges': edges[:1]}
        with tempfile.TemporaryDirectory(prefix='voicechat-catalog-web-') as directory:
            root = Path(directory)
            key = root / 'signing.pem'
            subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(key)],
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            key.chmod(0o600)
            now = int(time.time())

            def signed(revision, *, expires=None, value=None):
                return json.dumps(sign(value or topology, key, revision, now - 60,
                                       expires or now + 3600)).encode()

            for phase, envelope in {'initial': signed(2), 'rollback': signed(1),
                    'advance': signed(4), 'expired': signed(5, expires=now - 1),
                    'foreign': signed(5, value={**topology, 'service_id': 'foreign'}),
                    'offline': b'{}'}.items():
                catalogs[phase] = dict.fromkeys(('b', 'd'), envelope)
            tampered = json.loads(signed(5))
            tampered['payload'] = 'e30='
            catalogs['tampered'] = dict.fromkeys(('b', 'd'), json.dumps(tampered).encode())
            catalogs['conflict'] = {'b': signed(3), 'd': signed(3, expires=now + 1800)}
            defines = root / 'defines.json'
            defines.write_text(json.dumps({'ROUTE_WEB_PROBE': json.dumps({
                'bootstrap': bootstrap, 'key': public_key(key), 'origin': origins[0]})}))
            web_root = (root / 'web').resolve()
            subprocess.run([str(args.flutter.resolve()), 'build', 'web', '--release', '--no-web-resources-cdn',
                            '--target', 'tool/route_catalog_web_probe.dart', '--output', str(web_root),
                            '--dart-define-from-file', str(defines)], cwd=ROOT / 'apps/client', check=True)
            for server, name in zip(servers, ('b', 'd')):
                server.edge = name
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start(); threads.append(thread)
            # Use the production JS compilation path and real isolation headers.
            # Dart/Wasm is not supported by the pinned crypto bridge decoder.
            subprocess.run([str(args.node.resolve()), str(ROOT / 'prototype/check_route_catalog_web.cjs')],
                           env={**os.environ, 'ROUTE_CATALOG_PROBE_ORIGIN': origins[0]}, check=True)
            print('PASS: browser WASM signature, discovered D, real localStorage, rollback/conflict/tamper/expiry guards')
    finally:
        for index, server in enumerate(servers):
            if index < len(threads): server.shutdown()
            server.server_close()
        for thread in threads: thread.join(timeout=5)


if __name__ == '__main__':
    main()
