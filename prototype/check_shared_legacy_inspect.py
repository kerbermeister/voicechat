"""Real read-only ingress preflight on a marked disposable Linux VM.

Uses synthetic Git/env/upstreams and internal Caddy certificates. Temporarily
publishes VM ports 80/443; refuses an existing deploy project or its Caddy volumes.
--adopt also exercises actual recreation, rollback and process-death recovery.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import role_config
import shared_ingress
import topology


def run(*arguments):
    result = subprocess.run(arguments, capture_output=True, timeout=120)
    if result.returncode: raise RuntimeError('Disposable ingress fixture command failed: ' + result.stderr.decode()[-3000:])
    return result.stdout


def main(*, adoption=False):
    if sys.platform != 'linux' or os.geteuid() != 0: raise ValueError('Disposable Linux root VM required')
    public_key = ' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    marker = json.loads((ROOT / '.disposable-vm').read_text())
    if marker != {'kind': 'voicechat-disposable-vm', 'ssh_host_key_sha256': hashlib.sha256(public_key.encode()).hexdigest()}:
        raise ValueError('Disposable VM marker does not match this host')
    for arguments in (['docker', 'ps', '-aq'], ['docker', 'network', 'ls', '-q'], ['docker', 'volume', 'ls', '-q']):
        if run(*arguments, '--filter', 'label=com.docker.compose.project=deploy').strip():
            raise ValueError('Existing deploy project must never be adopted by this fixture')
    for name in ('deploy_caddy_data', 'deploy_caddy_config'):
        if run('docker', 'volume', 'ls', '-q', '--filter', 'name=^' + name + '$').strip():
            raise ValueError('Existing Caddy volume must never be adopted by this fixture')
    public = topology.load(ROOT / 'infra/single-vps.example.json')
    public.update(service_id='voicechat-shared-inspect-fixture', canonical_origin='https://chat.fixture.invalid',
        matrix_server_name='chat.fixture.invalid', web_origins=['https://chat.fixture.invalid'],
        edges=[{'id': 'a', 'origin': 'https://chat.fixture.invalid', 'turn_host': 'turn.fixture.invalid'}])
    inventory = json.loads((ROOT / 'infra/single-node-inventory.example.json').read_text())
    inventory['service_id'] = public['service_id']; inventory['core']['ssh_host_key'] = public_key
    business = '''{
    local_certs
    skip_install_trust
}
{$DOMAIN} {
    reverse_proxy frontend:80
}
'''
    with tempfile.TemporaryDirectory(prefix='voicechat-legacy-inspect-') as temporary:
        directory = Path(temporary)
        repo, shared, edge = directory / 'repo', directory / 'shared', directory / 'future-edge'
        deploy = repo / 'deploy'; deploy.mkdir(parents=True)
        (deploy / 'Caddyfile').write_text(business)
        (deploy / 'upstream.py').write_text('''from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'synthetic-upstream')
HTTPServer(('0.0.0.0', 80), Handler).serve_forever()
''')
        stub = {'image': role_config.pinned_image('configure'), 'entrypoint': ['python3', '/upstream.py'],
            'volumes': ['./upstream.py:/upstream.py:ro'], 'mem_limit': '64m', 'cpus': 1,
            'environment': {'PYTHONDONTWRITEBYTECODE': '1', 'PRIVATE_VALUE': '${JWT_SECRET:?}'}}
        model = {'services': {'caddy': {'image': shared_ingress.CADDY_IMAGE, 'restart': 'unless-stopped',
            'ports': ['80:80', '443:443'], 'environment': {'DOMAIN': '${DOMAIN:?}'},
            'volumes': ['./Caddyfile:/etc/caddy/Caddyfile:ro', 'caddy_data:/data', 'caddy_config:/config'],
            'depends_on': ['frontend', 'voicechat-web'], 'mem_limit': '128m', 'cpus': 1},
            'frontend': stub, 'voicechat-web': stub}, 'volumes': {'caddy_data': {}, 'caddy_config': {}}}
        (deploy / 'docker-compose.yml').write_text(json.dumps(model))
        run('git', '-C', str(repo), 'init', '-b', 'main')
        run('git', '-C', str(repo), 'add', 'deploy/Caddyfile', 'deploy/docker-compose.yml', 'deploy/upstream.py')
        run('git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'fixture')
        secret = 'synthetic-private-value-not-for-export'
        environment = deploy / '.env'
        original = ('DOMAIN=neighbor.fixture.invalid\nJWT_SECRET=' + secret + '\n').encode()
        environment.write_bytes(original); environment.chmod(0o600)
        legacy = shared_ingress.legacy_config(business, public).encode()
        (deploy / 'Caddyfile').write_bytes(legacy)
        plan = shared_ingress.stage(shared, repo, edge, public, inventory, 'a', business)
        command = ['docker', 'compose', '--project-directory', str(deploy), '--project-name', 'deploy',
                   '--env-file', str(environment), '-f', str(deploy / 'docker-compose.yml')]
        try:
            run(*command, 'up', '-d')
            identifier = run(*command, 'ps', '-q', 'caddy').decode().strip()
            end = time.monotonic() + 90
            while True:
                try:
                    run('docker', 'exec', identifier, 'wget', '-q', '-O', '-', '-T', '5', '-Y', 'off', 'http://127.0.0.1:2019/config/')
                    break
                except RuntimeError:
                    if time.monotonic() >= end: raise
                    time.sleep(1)
            baseline = shared_ingress.inspect_legacy_plan(shared, plan)
            after = shared_ingress.inspect_legacy_plan(shared, plan)
            assert baseline == after and baseline['caddy_id'] == identifier
            assert len(baseline['neighbors']) == 2
            assert environment.read_bytes() == original and (deploy / 'Caddyfile').read_bytes() == legacy
            assert not (shared / 'runtime').exists() and not edge.exists()
            assert secret not in json.dumps(baseline)
            result = {'schema': 1, 'production_changed': False, 'real_caddy_git_environment_preflight': True,
                'active_and_on_disk_caddy_configs_matched_plan': True, 'image_ports_networks_and_volume_identity_verified': True,
                'environment_git_and_container_processes_unchanged': True, 'raw_credentials_absent_from_result': True,
                'source_sha256': {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in
                    ('infra/shared_ingress.py', 'infra/role_bootstrap.py', 'prototype/check_shared_legacy_inspect.py')},
                'limits': ['Read-only preflight on synthetic Git/env/upstreams and internal certificates; no live adoption or port cutover.',
                           'Public content-addressed operator package retained; no service unit activated.']}
            if adoption:
                # Trust this fixture's public CA only for its curl invocations;
                # never install it in the VM or host trust store.
                ca = directory / 'fixture-ca.pem'
                end = time.monotonic() + 90
                while True:
                    try:
                        ca.write_bytes(run('docker', 'exec', identifier, 'cat', '/data/caddy/pki/authorities/local/root.crt'))
                        for hostname in ('neighbor.fixture.invalid', 'chat.fixture.invalid'):
                            run('curl', '--fail', '--silent', '--show-error', '--noproxy', '*', '--cacert', str(ca),
                                '--max-time', '5', '--resolve', hostname + ':443:127.0.0.1', 'https://' + hostname + '/')
                        break
                    except RuntimeError:
                        if time.monotonic() >= end: raise
                        time.sleep(1)
                def execute(arguments, *, env=None):
                    if arguments[0] == 'curl': arguments = [*arguments, '--cacert', str(ca)]
                    result = subprocess.run(arguments, env=env, capture_output=True, timeout=120)
                    if result.returncode: raise RuntimeError('Synthetic adoption command failed; private diagnostics retained in VM')
                    return result.stdout
                for failure in (RuntimeError('lost Docker response'), SystemExit('process died')):
                    injected = False
                    def fail_after_up(arguments, *, env=None):
                        nonlocal injected
                        output = execute(arguments, env=env)
                        if not injected and arguments[:2] == ['docker', 'compose'] and 'up' in arguments and str(shared / 'runtime/compose.override.yaml') in arguments:
                            injected = True
                            raise failure
                        return output
                    try:
                        shared_ingress.adopt_legacy(shared, plan, execute=fail_after_up)
                        raise AssertionError('Injected failure was not exercised')
                    except type(failure): pass
                    assert injected
                    if isinstance(failure, SystemExit):
                        assert (shared / 'pending.json').exists()
                        try:
                            shared_ingress.adopt_legacy(shared, plan, execute=execute)
                            raise AssertionError('Recovery must precede a fresh adoption')
                        except ValueError as error:
                            assert 'Interrupted legacy adoption recovered' in str(error)
                    assert environment.read_bytes() == original
                    assert not (shared / 'pending.json').exists() and not (shared / 'current.json').exists()
                committed = shared_ingress.adopt_legacy(shared, plan, execute=execute)
                managed_id = run(*command, '-f', str(shared / 'runtime/compose.override.yaml'), 'ps', '-q', 'caddy').decode().strip()
                assert shared_ingress.adopt_legacy(shared, plan, execute=execute) == committed
                assert managed_id == run(*command, '-f', str(shared / 'runtime/compose.override.yaml'), 'ps', '-q', 'caddy').decode().strip()
                assert (deploy / 'Caddyfile').read_bytes() == legacy
                assert original in environment.read_bytes() and environment.stat().st_mode & 0o777 == 0o600
                assert secret not in json.dumps(committed)
                result.update(real_directory_mount_adoption=True, lost_response_automatic_rollback=True,
                    process_death_recovered_before_retry=True, authenticated_https_routes_after_all_recreations=True,
                    neighboring_processes_and_data_volume_names_preserved=True, committed_retry_did_not_restart_caddy=True)
                result['limits'] = ['Synthetic Git/env/upstreams and internal certificates; no external ACME, shared port cutover or production migration.',
                                    'Public content-addressed operator package retained; no manager wrapper or systemd unit activated.']
        except BaseException:
            print(run(*command, 'logs', '--tail', '12').decode(), file=sys.stderr)
            raise
        finally:
            run(*command, 'down', '--volumes', '--remove-orphans')
    for arguments in (['docker', 'ps', '-aq'], ['docker', 'network', 'ls', '-q'], ['docker', 'volume', 'ls', '-q']):
        assert not run(*arguments, '--filter', 'label=com.docker.compose.project=deploy').strip()
    result['fixture_resources_removed'] = True
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adopt', action='store_true')
    main(adoption=parser.parse_args().adopt)
