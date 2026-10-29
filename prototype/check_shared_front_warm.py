"""Real shared-front warm-up on the explicitly marked disposable Linux VM.

No production ports, database or user profiles. There are no TLS backends in
this probe: route/media validation belongs to the separate TLS fixtures.
"""
import hashlib
import json
from pathlib import Path
import socket
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import role_deploy
import role_prepare
import role_release
import shared_front


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
            result = {'schema': 1, 'loopback_listener_only': True,
                'real_compose_interruption_resumed': True, 'repeat_preserved_process': True,
                'owned_stopped_listener_recovered': True,
                'owned_networks_verified': True, 'core_and_edge_not_started': True,
                'limits': ['No TLS backends, media, public port cutover or reboot in this probe.']}
        finally:
            run([*shared_front._command(plan), 'down', '--remove-orphans'])
        assert not run(['docker', 'ps', '-aq', '--filter', 'label=com.docker.compose.project=' + project]).strip()
        for network in model['networks'].values():
            assert not run(['docker', 'network', 'ls', '-q', '--filter', 'name=^' + network['name'] + '$']).strip()
        result['fixture_resources_removed'] = True
        print(json.dumps(result))


if __name__ == '__main__': main()
