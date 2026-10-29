"""Real shared-front warm-up on the explicitly marked disposable Linux VM.

No production ports, database or user profiles. Synthetic Caddy TLS backends
verify pre-cutover readiness; they do not prove real upstreams or TURN/media.
"""
import hashlib
import json
import os
from pathlib import Path
import socket
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import edge_deploy
import role_deploy
import role_prepare
import role_release
import shared_front
import tls_runtime


def check_tls_backends(directory, edge, manifest, public, inventory, model, run):
    """Use a disposable CA and real strict-PROXY TLS, never disable verification."""
    ca, key, leaf = directory / 'ca.crt', directory / 'server.key', directory / 'server.crt'
    ca_key = directory / 'ca.key'
    for path in (key, ca_key): path.touch(mode=0o600)
    run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
        '-nodes', '-keyout', str(ca_key), '-out', str(ca), '-days', '30', '-subj', '/CN=Disposable Warm CA',
        '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign'])
    csr, extensions = directory / 'server.csr', directory / 'server.ext'
    run(['openssl', 'req', '-new', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
         '-nodes', '-keyout', str(key), '-out', str(csr), '-subj', '/CN=chat.fixture.invalid'])
    extensions.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n'
        'extendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n'
        'subjectAltName=DNS:chat.fixture.invalid,DNS:turn.fixture.invalid\n')
    run(['openssl', 'x509', '-req', '-in', str(csr), '-CA', str(ca), '-CAkey', str(ca_key),
        '-CAcreateserial', '-out', str(leaf), '-days', '14', '-extfile', str(extensions)])
    chain = directory / 'server.chain'; chain.write_bytes(leaf.read_bytes() + ca.read_bytes())
    for service in ('web', 'turn'):
        tls_runtime.publish(edge / 'runtime/tls', public, 'warmfixture', service, chain, key, ca_file=ca)
    record = edge_deploy.record_for(public, inventory, manifest)
    network = model['networks']['edge']['name']
    image = 'caddy@sha256:226d1f059b75399fe19182893c7184591c07b97afc8dfcf44eeb80c9a77a530f'
    names = []
    previous_ca = os.environ.get('SSL_CERT_FILE')
    os.environ['SSL_CERT_FILE'] = str(ca)
    try:
        for service, address, port, hostname in (
                ('web', '10.243.0.3', 8443, 'chat.fixture.invalid'),
                ('turn', '10.243.0.4', 5349, 'turn.fixture.invalid')):
            options = '''    servers :8443 {
        protocols h1 h2
        strict_sni_host on
        listener_wrappers {
            proxy_protocol {
                timeout 2s
                allow 10.243.0.2/32
                fallback_policy reject
            }
            tls
        }
    }
''' if service == 'web' else ''
            body = json.dumps({'schema': 1, 'service_id': 'voicechat', 'edge_id': 'warmfixture',
                               'matrix': True, 'control': True, 'age_ms': 0})
            config = '{\n admin off\n auto_https off\n' + options + '}\n'
            config += f'https://{hostname}:{port} {{\n tls /tls/server.crt /tls/server.key\n respond `{body}` 200\n}}\n'
            path = directory / (service + '.caddy'); path.write_text(config)
            name = 'vc-warm-' + service + '-' + directory.name
            assert not run(['docker', 'ps', '-aq', '--filter', 'name=^' + name + '$']).strip()
            names.append(name)
            run(['docker', 'run', '-d', '--name', name, '--label', 'voicechat.fixture=' + directory.name,
                '--network', network, '--ip', address, '--read-only', '--cap-drop', 'ALL',
                '--cap-add', 'NET_BIND_SERVICE', '--security-opt', 'no-new-privileges:true',
                '--tmpfs', '/data', '--tmpfs', '/config', '--tmpfs', '/tmp',
                '--volume', str(path) + ':/etc/caddy/Caddyfile:ro',
                '--volume', str(chain) + ':/tls/server.crt:ro',
                '--volume', str(key) + ':/tls/server.key:ro', image])
        with managed_state.locked(edge / 'runtime/tls'):
            edge_deploy.healthy(edge, record, warm_port=19443)
        # Identity and upstream readiness must be checked after trusted TLS.
        web = directory / 'web.caddy'
        good = web.read_text(); web.write_text(good.replace('"service_id": "voicechat"', '"service_id": "foreign"'))
        # These fixture Caddies have admin off; recreate only this synthetic web.
        run(['docker', 'restart', names[0]])
        try:
            with managed_state.locked(edge / 'runtime/tls'):
                edge_deploy.healthy(edge, record, warm_port=19443)
        except ValueError as error:
            assert 'identity or upstream' in str(error)
        else: raise AssertionError('A trusted certificate cannot hide a foreign readiness identity')
        web.write_text(good); run(['docker', 'restart', names[0]])
        with managed_state.locked(edge / 'runtime/tls'):
            edge_deploy.healthy(edge, record, warm_port=19443)
    finally:
        for name in names:
            if run(['docker', 'ps', '-aq', '--filter', 'name=^' + name + '$']).strip():
                owner = run(['docker', 'inspect', '--format', '{{index .Config.Labels "voicechat.fixture"}}', name]).decode().strip()
                assert owner == directory.name
                run(['docker', 'rm', '-f', name])
        if previous_ca is None: os.environ.pop('SSL_CERT_FILE', None)
        else: os.environ['SSL_CERT_FILE'] = previous_ca


def main():
    base = Path('/srv/voicechat-edge-fixture')
    if sys.platform != 'linux' or not base.is_dir() or base.is_symlink():
        raise ValueError('Use the marked disposable Linux VM')
    marker = json.loads((base / '.disposable-vm').read_text())
    key = ' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    if marker != {'kind': 'voicechat-disposable-vm', 'ssh_host_key_sha256': hashlib.sha256(key.encode()).hexdigest()}:
        raise ValueError('Disposable VM ownership marker differs from this host')
    run = role_deploy.run
    project = shared_front.PROJECT
    if run(['docker', 'ps', '-aq', '--filter', 'label=com.docker.compose.project=' + project]).strip():
        raise ValueError('Existing shared front must not be adopted by a fixture')
    public = {'schema': 1, 'service_id': 'voicechat', 'matrix_server_name': 'chat.fixture.invalid',
        'canonical_origin': 'https://chat.fixture.invalid', 'web_origins': ['https://chat.fixture.invalid'],
        'edges': [{'id': 'warmfixture', 'origin': 'https://chat.fixture.invalid', 'turn_host': 'turn.fixture.invalid'}]}
    inventory = {'schema': 1, 'service_id': 'voicechat', 'ssh_user': 'root', 'ssh_port': 22,
        'core': {'generation': 1, 'public_ip': '198.51.100.10', 'tunnel_ip': '10.88.0.1', 'ssh_host_key': key},
        'edges': [{'id': 'warmfixture', 'host': 'core', 'shared_tls': {
            'network': 'vc-warm-fixture-legacy', 'subnet': '172.30.43.0/29',
            'legacy_ip': '172.30.43.2', 'ingress_ip': '172.30.43.3'}}]}
    with tempfile.TemporaryDirectory(prefix='front-warm-', dir=base) as temporary:
        directory = Path(temporary)
        front, edge = directory / 'front', directory / 'edge'
        manifest = role_release.make(public, inventory, 'edge', 'a' * 40,
            'ghcr.io/fixture/web@sha256:' + '1' * 64, 'warmfixture', '10.243.0.0/28')
        role_prepare.prepare(edge, public, inventory, manifest, '10.243.0.0/28')
        plan = shared_front.prepare(front, edge, manifest)
        model = json.loads((plan / 'compose.json').read_text())
        for network in model['networks'].values():
            if run(['docker', 'network', 'ls', '-q', '--filter', 'name=^' + network['name'] + '$']).strip():
                raise ValueError('Fixture network already exists')
        # Reserve-check only: Docker must still prove the exact loopback binding.
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 19443))
        interrupted = False
        def execute(args, *, env=None):
            nonlocal interrupted
            result = run(args, env=env)
            if args[:2] == ['docker', 'compose'] and 'up' in args and not interrupted:
                interrupted = True
                raise SystemExit('Injected lost warm-up response')
            return result
        try:
            try: shared_front.warm(front, plan, execute=execute)
            except SystemExit: pass
            else: raise AssertionError('Expected interruption after real up')
            assert managed_state.read(front / 'warm.json')['phase'] == 'applying'
            identifier = run([*shared_front._command(plan), 'ps', '-q', 'ingress']).decode().strip()
            assert identifier
            def identity():
                return run(['docker', 'inspect', '--format', '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}', identifier])
            before = identity()
            assert shared_front.warm(front, plan, execute=execute)['phase'] == 'running'
            assert identity() == before
            assert shared_front.warm(front, plan, execute=execute)['phase'] == 'running'
            assert identity() == before
            with socket.create_connection(('127.0.0.1', 19443), timeout=3): pass
            run([*shared_front._command(plan), 'stop', 'ingress'])
            assert shared_front.warm(front, plan, execute=execute)['phase'] == 'running'
            with socket.create_connection(('127.0.0.1', 19443), timeout=3): pass
            assert not (edge / 'state.json').exists()
            assert set(model['services']) == {'ingress'}
            assert model['services']['ingress']['ports'] == ['127.0.0.1:19443:8443/tcp']
            check_tls_backends(directory, edge, manifest, public, inventory, model, run)
            result = {'schema': 1, 'loopback_listener_only': True,
                'real_compose_interruption_resumed': True, 'repeat_preserved_process': True,
                'owned_stopped_listener_recovered': True,
                'owned_networks_verified': True, 'core_and_edge_not_started': True,
                'trusted_web_and_turn_tls_through_warm_front': True,
                'strict_proxy_web_readiness_checked': True,
                'foreign_readiness_identity_rejected': True,
                'limits': ['Synthetic Caddy readiness and TURN TLS endpoint; no real core, TURN allocation or media.',
                           'No public port cutover or reboot in this probe.']}
        finally:
            run([*shared_front._command(plan), 'down', '--remove-orphans'])
        assert not run(['docker', 'ps', '-aq', '--filter', 'label=com.docker.compose.project=' + project]).strip()
        for network in model['networks'].values():
            assert not run(['docker', 'network', 'ls', '-q', '--filter', 'name=^' + network['name'] + '$']).strip()
        result['fixture_resources_removed'] = True
        print(json.dumps(result))


if __name__ == '__main__': main()
