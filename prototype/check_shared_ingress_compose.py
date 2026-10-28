"""Validate shared Caddy overrides with Compose, without starting any services."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
import shared_ingress


def run(*arguments):
    result = subprocess.run(arguments, capture_output=True, timeout=60)
    if result.returncode: raise RuntimeError('Compose fixture command failed; no runtime output exposed')
    return result.stdout


def check(base):
    source = base.read_bytes()
    with tempfile.TemporaryDirectory(prefix='vc-shared-compose-') as temporary:
        root = Path(temporary)
        (root / 'base.yaml').write_bytes(source)
        environment = root / 'fixture.env'
        environment.write_text('DOMAIN=neighbor.fixture.invalid\nIMAGE_PREFIX=ghcr.io/fixture/avito\n'
                               'JWT_SECRET=synthetic-fixture-only\nADMIN_PASSWORD=synthetic-fixture-only\n')
        environment.chmod(0o600)
        config = root / 'managed-config'
        config.mkdir()
        command = ['docker', 'compose', '--env-file', str(environment), '--project-name',
                   'deploy', '-f', str(root / 'base.yaml')]
        baseline = json.loads(run(*command, 'config', '--format', 'json'))
        for shared in (None, {'network': 'vc-shared-compose-fixture', 'subnet': '172.30.42.0/29',
                             'legacy_ip': '172.30.42.2', 'ingress_ip': '172.30.42.3'}):
            override = root / 'override.yaml'
            override.write_text(shared_ingress.compose_override(str(config), shared=shared))
            value = json.loads(run(*command, '-f', str(override), 'config', '--format', 'json'))
            services = value['services']
            assert {key: service for key, service in services.items() if key != 'caddy'} == {
                key: service for key, service in baseline['services'].items() if key != 'caddy'}
            caddy = services['caddy']
            assert caddy['image'] == shared_ingress.CADDY_IMAGE
            assert caddy['environment'] == baseline['services']['caddy']['environment']
            ports = {(port['target'], str(port['published'])) for port in caddy['ports']}
            assert ports == ({(80, '80')} if shared else {(80, '80'), (443, '443')})
            mounts = {mount['target']: mount for mount in caddy['volumes']}
            assert set(mounts) == {'/etc/caddy', '/data', '/config'}
            assert mounts['/etc/caddy']['source'] == str(config) and mounts['/etc/caddy']['read_only']
            assert mounts['/etc/caddy']['bind']['create_host_path'] is False
            for name, target in (('caddy_data', '/data'), ('caddy_config', '/config')):
                assert mounts[target]['source'] == name
                assert value['volumes'][name] == baseline['volumes'][name]
                assert value['volumes'][name]['name'] == 'deploy_' + name
            assert set(caddy['networks']) == ({'default', 'shared-tls'} if shared else {'default'})
            if shared:
                network = value['networks']['shared-tls']
                assert network['name'] == shared['network'] and network['external'] is True
                assert not network.get('ipam')  # Compose 5.5 normalizes an empty mapping.
                assert caddy['networks']['shared-tls']['ipv4_address'] == shared['legacy_ip']
    return {'schema': 1, 'compose_version': run('docker', 'compose', 'version', '--short').decode().strip(),
            'legacy_and_shared_override_validated': True, 'business_service_definitions_unchanged': True,
            'existing_caddy_volume_names_preserved': True, 'leaf_mount_removed': True,
            'production_changed': False, 'services_started': False, 'fixture_resources_removed': True,
            'base_compose_sha256': hashlib.sha256(source).hexdigest(),
            'source_sha256': {'infra/shared_ingress.py': hashlib.sha256(Path(shared_ingress.__file__).read_bytes()).hexdigest(),
                              'prototype/check_shared_ingress_compose.py': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()},
            'limits': ['Compose config validation only; no host adoption, reload, TLS issuance or port cutover.']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-compose', type=Path, required=True)
    print(json.dumps(check(parser.parse_args().base_compose), indent=2))
