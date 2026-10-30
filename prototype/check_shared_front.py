"""Isolated Docker proof of shared SNI routing; no real TURN or production data.

Run only on a disposable Linux Docker host. Publishes loopback TCP 19443 and
removes its own containers/networks afterward. Requires openssl and Python 3.
"""
import base64
import json
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
import role_config
import topology

CADDY = 'caddy@sha256:226d1f059b75399fe19182893c7184591c07b97afc8dfcf44eeb80c9a77a530f'
PROJECT = 'vc-shared-front-probe'


def run(*arguments):
    result = subprocess.run(arguments, capture_output=True, timeout=180)
    if result.returncode: raise RuntimeError(result.stderr.decode()[-4000:])
    return result.stdout


def main():
    if sys.platform != 'linux': raise ValueError('Use a disposable Linux Docker host')
    public = topology.load(role_config.ROOT / 'infra/single-vps.example.json')
    public.update(canonical_origin='https://chat.fixture.invalid', matrix_server_name='chat.fixture.invalid',
                  web_origins=['https://chat.fixture.invalid'], edges=[{'id': 'fixture',
                  'origin': 'https://chat.fixture.invalid', 'turn_host': 'turn.fixture.invalid'}])
    kind = b'ssh-ed25519'
    key = 'ssh-ed25519 ' + base64.b64encode(struct.pack('>I', len(kind)) + kind + struct.pack('>I', 32) + b'x' * 32).decode()
    inventory = {'schema': 1, 'service_id': public['service_id'], 'ssh_user': 'root', 'ssh_port': 22,
        'core': {'generation': 1, 'public_ip': '198.51.100.10', 'tunnel_ip': '10.89.0.1', 'ssh_host_key': key},
        'edges': [{'id': 'fixture', 'host': 'core', 'shared_tls': {'network': 'vc-shared-front-probe-legacy',
            'subnet': '172.30.42.0/29', 'legacy_ip': '172.30.42.2', 'ingress_ip': '172.30.42.3'}}]}
    _, files = role_config.edge(public, inventory, 'fixture', '10.242.0.0/28')
    front = json.loads(files['compose.shared-front.json'])
    front['name'] = PROJECT
    front['services']['ingress']['ports'] = ['127.0.0.1:19443:8443/tcp']
    names = [value['name'] for value in front['networks'].values()]
    assert not run('docker', 'ps', '-aq', '--filter', 'label=com.docker.compose.project=' + PROJECT).strip()
    for name in names:
        if run('docker', 'network', 'ls', '-q', '--filter', 'name=^' + name + '$').strip():
            raise ValueError('Fixture network already exists; refusing to adopt it')
    with tempfile.TemporaryDirectory(prefix='vc-shared-front-') as temporary:
        root = Path(temporary)
        run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
            '-subj', '/CN=neighbor.fixture.invalid', '-addext',
            'subjectAltName=DNS:neighbor.fixture.invalid,DNS:chat.fixture.invalid,DNS:turn.fixture.invalid',
            '-keyout', str(root / 'server.key'), '-out', str(root / 'server.crt'))
        (root / 'haproxy.cfg').write_text(files['haproxy.cfg'])
        wrappers = '''servers :443 {
    protocols h1 h2
    strict_sni_host on
    listener_wrappers {
        proxy_protocol {
            allow 172.30.42.3/32
            fallback_policy reject
        }
        tls
    }
}'''
        for name, host, port, address, network, proxy in (
                ('neighbor', 'neighbor.fixture.invalid', 443, '172.30.42.2', 'legacy', True),
                ('web', 'chat.fixture.invalid', 8443, '10.242.0.3', 'edge', True),
                ('turn', 'turn.fixture.invalid', 5349, '10.242.0.4', 'edge', False)):
            listeners = wrappers.replace(':443', ':' + str(port)).replace('172.30.42.3',
                '172.30.42.3' if name == 'neighbor' else '10.242.0.2') if proxy else ''
            config = '{\n admin off\n auto_https off\n ' + listeners + '\n}\n'
            config += f'https://{host}:{port} {{\n tls /tls/server.crt /tls/server.key\n respond "{name}-ok"\n}}\n'
            (root / (name + '.caddy')).write_text(config)
            front['services'][name] = {'image': CADDY, 'restart': 'unless-stopped',
                'networks': {network: {'ipv4_address': address}},
                'volumes': [role_config.bind('./' + name + '.caddy', '/etc/caddy/Caddyfile'),
                            role_config.bind('./server.crt', '/tls/server.crt'),
                            role_config.bind('./server.key', '/tls/server.key')]}
            run('docker', 'run', '--rm', '--network', 'none',
                '--volume', str(root / (name + '.caddy')) + ':/etc/caddy/Caddyfile:ro',
                '--volume', str(root) + ':/tls:ro', CADDY,
                'caddy', 'validate', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile')
        path = root / 'compose.json'
        path.write_text(json.dumps(front))
        command = ['docker', 'compose', '--env-file', '/dev/null', '-p', PROJECT, '-f', str(path)]
        context = ssl.create_default_context(cafile=str(root / 'server.crt'))
        def request(name, host=None):
            with socket.create_connection(('127.0.0.1', 19443), timeout=5) as raw:
                with context.wrap_socket(raw, server_hostname=name + '.fixture.invalid') as stream:
                    stream.sendall(f'GET / HTTP/1.1\r\nHost: {host or name + ".fixture.invalid"}\r\nConnection: close\r\n\r\n'.encode())
                    response = b''
                    while True:
                        chunk = stream.recv(4096)
                        if not chunk: return response
                        response += chunk
                        if len(response) > 65536: raise ValueError('Unbounded fixture response')
        try:
            run(*command, 'up', '-d')
            end = time.monotonic() + 60
            while True:
                try:
                    assert b'neighbor-ok' in request('neighbor')
                    assert b'web-ok' in request('chat')
                    assert b'turn-ok' in request('turn')  # TLS route only, not TURN allocation.
                    break
                except (OSError, AssertionError):
                    if time.monotonic() >= end: raise
                    time.sleep(1)
            assert b'421' in request('neighbor', 'chat.fixture.invalid').split(b'\r\n')[0]
            identifier = run(*command, 'ps', '-q', 'ingress').decode().strip()
            before = run('docker', 'inspect', '--format', '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}', identifier)
            run(*command, 'stop', 'web', 'turn')
            assert b'neighbor-ok' in request('neighbor')
            assert run('docker', 'inspect', '--format', '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}', identifier) == before
            for name in ('chat', 'turn'):
                try: request(name)
                except (OSError, ssl.SSLError): pass
                else: raise AssertionError('Unavailable known SNI must not fall back to neighbor')
            result = {'schema': 1, 'caddy_image': CADDY, 'shared_sni_routes': True,
                'strict_legacy_sni_host': True, 'stopped_edge_preserved_neighbor_and_front_process': True,
                'unavailable_known_names_never_fell_back_to_neighbor': True,
                'production_changed': False, 'limits': ['Synthetic TLS endpoints, no TURN allocation or media.',
                'No shared-front reboot, production migration or ACME issuance acceptance.']}
        except BaseException:
            # Only synthetic endpoints exist here; bounded logs explain a
            # routing/parser failure before the fixture is always removed.
            print(run(*command, 'logs', '--tail', '12').decode(), file=sys.stderr)
            raise
        finally:
            run(*command, 'down', '--volumes', '--remove-orphans')
        assert not run('docker', 'ps', '-aq', '--filter', 'label=com.docker.compose.project=' + PROJECT).strip()
        for name in names: assert not run('docker', 'network', 'ls', '-q', '--filter', 'name=^' + name + '$').strip()
        result['fixture_resources_removed'] = True
        print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
