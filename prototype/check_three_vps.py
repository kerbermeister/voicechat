"""Run the native Matrix route proof against disposable Synapse/Postgres/B/C.

All published ports are loopback-only. No production runtime, credentials,
volumes or existing Compose projects are read or changed.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import threading
import uuid


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
from route_catalog import sign, public_key


def image(service):
    source = (ROOT / 'infra/compose.yaml').read_text()
    match = re.search(r'^  ' + service + r':\n    image: (\S+)', source, re.M)
    if not match or '@sha256:' not in match[1]:
        raise ValueError('A pinned service image is required')
    return match[1]


def configuration(directory, project):
    (directory / 'catalog').mkdir(exist_ok=True)
    password = secrets.token_hex(32)
    synapse = {
        'server_name': 'routes.test', 'report_stats': False,
        'pid_file': '/data/homeserver.pid',
        'signing_key_path': '/data/routes.test.signing.key',
        'media_store_path': '/data/media',
        'listeners': [{'port': 8008, 'type': 'http', 'tls': False,
                       'bind_addresses': ['0.0.0.0'], 'x_forwarded': True,
                       'resources': [{'names': ['client'], 'compress': False}]}],
        'database': {'name': 'psycopg2', 'args': {
            'user': 'synapse', 'password': password, 'database': 'synapse',
            'host': 'postgres', 'cp_min': 2, 'cp_max': 5}},
        'enable_registration': True, 'enable_registration_without_verification': True,
        'macaroon_secret_key': secrets.token_hex(32),
        'trusted_key_servers': [], 'federation_domain_whitelist': [],
        'rc_registration': {'per_second': 10, 'burst_count': 20},
        'rc_login': {name: {'per_second': 10, 'burst_count': 20}
                     for name in ('address', 'account', 'failed_attempts')},
    }
    path = directory / 'homeserver.json'
    path.write_text(json.dumps(synapse))
    # Only synthetic credentials in a private TemporaryDirectory; container UID
    # must be able to read this mounted file.
    path.chmod(0o644)
    (directory / 'Caddyfile').write_text('''{
    admin off
    auto_https off
}
:80 {
    @private path /_synapse/admin/* /_synapse/client/voicechat/*
    respond @private 404
    reverse_proxy synapse:8008
}
''')
    caddy = (ROOT / 'infra/web.Dockerfile').read_text().splitlines()[0].split()[1]
    if '@sha256:' not in caddy:
        raise ValueError('Pinned proxy image required')
    services = {
        'postgres': {
            'image': image('postgres'),
            'environment': {'POSTGRES_USER': 'synapse', 'POSTGRES_DB': 'synapse',
                            'POSTGRES_PASSWORD': password,
                            'POSTGRES_INITDB_ARGS': '--encoding=UTF8 --locale=C'},
            'volumes': ['postgres:/var/lib/postgresql/data'],
            'healthcheck': {'test': ['CMD-SHELL', 'pg_isready -U synapse'],
                            'interval': '1s', 'timeout': '2s', 'retries': 60}},
        'synapse-data': {
            'image': image('synapse'), 'user': '0:0',
            'entrypoint': ['chown', '991:991', '/data'], 'volumes': ['synapse:/data']},
        'synapse': {
            'image': image('synapse'),
            'environment': {'SYNAPSE_CONFIG_PATH': '/config/homeserver.json'},
            'volumes': ['./homeserver.json:/config/homeserver.json:ro', 'synapse:/data'],
            'depends_on': {'postgres': {'condition': 'service_healthy'},
                           'synapse-data': {'condition': 'service_completed_successfully'}},
            'healthcheck': {'test': ['CMD', 'python', '-c',
                'import urllib.request;urllib.request.urlopen("http://localhost:8008/_matrix/client/versions",timeout=2)'],
                'interval': '2s', 'timeout': '3s', 'retries': 60}},
    }
    for role in ('edge-b', 'edge-c', 'edge-d'):
        health = 'health-' + role[-1]
        proxy = (directory / 'Caddyfile').read_text().replace(
            '    reverse_proxy synapse:8008',
            '    handle /.well-known/voicechat/routes.json {\n        root * /catalog\n'
            '        rewrite * /routes.json\n        header Cache-Control no-store\n        file_server\n    }\n'
            f'    handle /health/route {{\n        reverse_proxy {health}:8091\n    }}\n'
            '    handle {\n        reverse_proxy synapse:8008\n    }')
        (directory / (role + '.Caddyfile')).write_text(proxy)
        services[health] = {
            'image': image('configure'),
            'entrypoint': ['python3', '/route_health.py'],
            'command': ['--service-id', 'route-test', '--edge-id', role[-1],
                        '--matrix-url', 'http://synapse:8008',
                        '--control-url', 'http://127.0.0.1:9'],
            'volumes': [str(ROOT / 'infra/route_health.py') + ':/route_health.py:ro'],
            'read_only': True, 'cap_drop': ['ALL'],
        }
        services[role] = {
            'image': caddy, 'ports': ['127.0.0.1::80'],
            'volumes': ['./' + role + '.Caddyfile:/etc/caddy/Caddyfile:ro', './catalog:/catalog:ro'],
            'depends_on': {'synapse': {'condition': 'service_healthy'}},
            'healthcheck': {'test': ['CMD', 'wget', '-q', '-O', '/dev/null',
                                   'http://127.0.0.1/_matrix/client/versions'],
                            'interval': '2s', 'timeout': '3s', 'retries': 30},
        }
    return {'name': project, 'services': services,
            'volumes': {'postgres': {}, 'synapse': {}}}


def fault_server(command):
    secret = secrets.token_hex(24)
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_POST(self):
            if self.headers.get('Authorization') != 'Bearer ' + secret or self.path not in ('/stop/b', '/stop/c', '/stop/d'):
                self.send_error(403)
                return
            subprocess.run([*command, 'stop', '-t', '1', 'edge-' + self.path[-1]],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.send_response(204); self.end_headers()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread, secret


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', type=Path, required=True)
    parser.add_argument('--bootstrap-edges', type=int, choices=(1, 2), default=2)
    args = parser.parse_args()
    flutter = args.flutter.resolve(strict=True)
    project = 'voicechat-routes-' + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix=project + '-') as temporary:
        directory = Path(temporary)
        compose_path = directory / 'compose.json'
        compose_path.write_text(json.dumps(configuration(directory, project)))
        compose_path.chmod(0o600)
        command = ['docker', 'compose', '-f', str(compose_path)]
        faults, fault_thread, fault_secret = fault_server(command)
        try:
            print('Starting isolated Synapse/Postgres and two loopback proxies', flush=True)
            subprocess.run([*command, 'up', '-d', '--wait', '--wait-timeout', '150'], check=True)
            defines = []
            edges = []
            for role in ('edge-b', 'edge-c', 'edge-d'):
                address = subprocess.check_output([*command, 'port', role, '80'], text=True).strip()
                if not re.fullmatch(r'127\.0\.0\.1:[0-9]+', address):
                    raise ValueError('Test port must be loopback-only')
                defines.append('--dart-define=ROUTE_TEST_' + role[-1].upper() + '=http://' + address)
                edges.append({'id': role[-1], 'origin': 'http://' + address,
                              'turn_host': 'turn-' + role[-1] + '.localhost'})
            config = {'schema': 1, 'service_id': 'route-test', 'matrix_server_name': 'routes.test',
                      'canonical_origin': 'http://localhost:9', 'web_origins': ['http://localhost:9'], 'edges': edges[:args.bootstrap_edges]}
            key = directory / 'test-only-ed25519.pem'
            key.touch(mode=0o600)
            subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(key)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            import time
            now = int(time.time())
            expanded = {**config, 'edges': edges}
            (directory / 'catalog/routes.json').write_text(json.dumps(sign(expanded, key, 2, now, now + 3600)))
            defines.append('--dart-define=ROUTE_CATALOG_KEY=' + public_key(key))
            defines.append('--dart-define=ROUTE_TEST_BOOTSTRAP_COUNT=' + str(args.bootstrap_edges))
            defines.extend(['--dart-define=ROUTE_CONFIG=' + json.dumps(config, separators=(',', ':')),
                            '--dart-define=ROUTE_TEST_FAULTS=http://127.0.0.1:' + str(faults.server_port),
                            '--dart-define=ROUTE_TEST_FAULT_SECRET=' + fault_secret])
            logs = ROOT / '.prototype/three-vps'
            logs.mkdir(mode=0o700, parents=True, exist_ok=True)
            log = logs / (project + '.log')
            env = os.environ.copy()
            if sys.platform == 'darwin':
                # macOS lacks Linux's C.UTF-8; CocoaPods also requires UTF-8
                # when a project change triggers pod install (unlike a warm build).
                env.update(LC_ALL='en_US.UTF-8', LC_CTYPE='en_US.UTF-8', LANG='en_US.UTF-8')
            print('Native test output: ' + str(log), flush=True)
            with log.open('w') as output:
                log.chmod(0o600)
                subprocess.run([str(flutter), 'test', '--no-pub', '-d', 'macos', *defines,
                                'integration_test/route_transport_test.dart'],
                               cwd=ROOT / 'apps/client', env=env, stdout=output,
                               stderr=subprocess.STDOUT, check=True)
            print('PASS: signed route expansion and encrypted Matrix profile after proxy loss/reopen', flush=True)
        except subprocess.CalledProcessError:
            raise SystemExit('Local route proof failed; inspect the private test log') from None
        finally:
            faults.shutdown(); faults.server_close(); fault_thread.join()
            # Only this randomly named project and its synthetic volumes.
            subprocess.run([*command, 'down', '--volumes', '--remove-orphans'], check=True)


if __name__ == '__main__':
    main()
