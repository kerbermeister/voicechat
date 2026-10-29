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
import re

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import role_config
import role_bootstrap
import shared_ingress
import shared_update
import topology


def run(*arguments):
    result = subprocess.run(arguments, capture_output=True, timeout=120)
    if result.returncode: raise RuntimeError('Disposable ingress fixture command failed: ' + result.stderr.decode()[-3000:])
    return result.stdout


def main(*, adoption=False, update=False, initial_operator=None):
    if sys.platform != 'linux' or os.geteuid() != 0: raise ValueError('Disposable Linux root VM required')
    public_key = ' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    marker = json.loads((ROOT / '.disposable-vm').read_text())
    if marker != {'kind': 'voicechat-disposable-vm', 'ssh_host_key_sha256': hashlib.sha256(public_key.encode()).hexdigest()}:
        raise ValueError('Disposable VM marker does not match this host')
    if initial_operator is not None:
        initial_operator = Path(initial_operator).absolute()
        if (not update or initial_operator.resolve() != initial_operator or initial_operator.name != 'infra' or
                not re.fullmatch(r'[a-f0-9]{64}', initial_operator.parent.name) or
                initial_operator.parent.parent != Path('/opt/voicechat/operators') or
                {path.name for path in initial_operator.iterdir()} != set(role_bootstrap.MANAGER_SOURCES)):
            raise ValueError('Reviewed historical 27-file manager package required for --update')
        hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in initial_operator.iterdir()}
        if hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest() != initial_operator.parent.name:
            raise ValueError('Historical operator source identity changed')
    wrapper = Path('/usr/local/sbin/voicechat-shared-deploy')
    if update and (wrapper.exists() or wrapper.is_symlink()): raise ValueError('Existing manager must not be replaced by a fixture')
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
        if update:
            remote, incoming = directory / 'remote.git', directory / 'incoming'
            run('git', 'clone', '--bare', str(repo), str(remote))
            run('git', '-C', str(repo), 'remote', 'add', 'origin', str(remote))
            run('git', 'clone', str(remote), str(incoming))
            run('git', '-C', str(incoming), 'config', 'user.name', 'Fixture')
            run('git', '-C', str(incoming), 'config', 'user.email', 'fixture@example.invalid')
        secret = 'synthetic-private-value-not-for-export'
        environment = deploy / '.env'
        original = ('DOMAIN=neighbor.fixture.invalid\nJWT_SECRET=' + secret + '\n').encode()
        environment.write_bytes(original); environment.chmod(0o600)
        legacy = shared_ingress.legacy_config(business, public).encode()
        (deploy / 'Caddyfile').write_bytes(legacy)
        def historical(action):
            # Run the actual previous sealed sources in a fresh interpreter;
            # never mix old and current Python modules in one import cache.
            script = '''import json,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import shared_ingress,shared_update
value=json.loads(sys.stdin.read())
root=Path(value['root'])
if value['action']=='stage':
 result=str(shared_ingress.stage(root,value['repo'],value['edge'],value['public'],value['inventory'],'a',value['business']))
elif value['action']=='inspect': result=shared_ingress.inspect_legacy_plan(root,Path(value['plan']))
elif value['action']=='adopt': result=shared_ingress.adopt_legacy(root,Path(value['plan']))
elif value['action']=='install': result=shared_update.install(root)
else: raise ValueError('Unknown fixture operation')
print(json.dumps(result))
'''
            value = {'action': action, 'root': str(shared), 'repo': str(repo), 'edge': str(edge),
                     'public': public, 'inventory': inventory, 'business': business,
                     'plan': str(plan) if action != 'stage' else None}
            process = subprocess.run(['python3', '-B', '-c', script, str(initial_operator)],
                input=json.dumps(value).encode(), capture_output=True, timeout=300,
                env={**os.environ, 'CURL_CA_BUNDLE': str(directory / 'fixture-ca.pem')})
            if process.returncode: raise RuntimeError('Historical synthetic operator failed: ' + process.stderr.decode()[-2500:])
            assert secret.encode() not in process.stdout + process.stderr
            return json.loads(process.stdout)
        plan = (Path(historical('stage')) if initial_operator else
                shared_ingress.stage(shared, repo, edge, public, inventory, 'a', business))
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
            baseline = historical('inspect') if initial_operator else shared_ingress.inspect_legacy_plan(shared, plan)
            after = historical('inspect') if initial_operator else shared_ingress.inspect_legacy_plan(shared, plan)
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
                failures = () if initial_operator else (RuntimeError('lost Docker response'), SystemExit('process died'))
                for failure in failures:
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
                committed = historical('adopt') if initial_operator else shared_ingress.adopt_legacy(shared, plan, execute=execute)
                managed_id = run(*command, '-f', str(shared / 'runtime/compose.override.yaml'), 'ps', '-q', 'caddy').decode().strip()
                assert (historical('adopt') if initial_operator else shared_ingress.adopt_legacy(shared, plan, execute=execute)) == committed
                assert managed_id == run(*command, '-f', str(shared / 'runtime/compose.override.yaml'), 'ps', '-q', 'caddy').decode().strip()
                assert (deploy / 'Caddyfile').read_bytes() == legacy
                assert original in environment.read_bytes() and environment.stat().st_mode & 0o777 == 0o600
                assert secret not in json.dumps(committed)
                result.update(real_directory_mount_adoption=True, lost_response_automatic_rollback=True,
                    process_death_recovered_before_retry=True, authenticated_https_routes_after_all_recreations=True,
                    neighboring_processes_and_data_volume_names_preserved=True, committed_retry_did_not_restart_caddy=True)
                result['limits'] = ['Synthetic Git/env/upstreams and internal certificates; no external ACME, shared port cutover or production migration.',
                                    'Public content-addressed operator package retained; no manager wrapper or systemd unit activated.']
                if initial_operator:
                    del result['lost_response_automatic_rollback'], result['process_death_recovered_before_retry']
                    result['historical_adoption_faults_not_repeated'] = True
                if update:
                    if initial_operator:
                        previous = historical('install')
                        upgrade_before = shared_ingress.snapshot({'deploy', 'voicechat'}, execute=execute)
                    receipt = shared_update.install(shared, execute=execute)
                    if initial_operator:
                        assert previous['operator']['operator_sha256'] == initial_operator.parent.name
                        assert receipt['operator']['operator_sha256'] != initial_operator.parent.name
                        assert shared_ingress.snapshot({'deploy', 'voicechat'}, execute=execute) == upgrade_before
                        plan = shared / 'plans' / json.loads((shared / 'current.json').read_text())['plan']
                        result.update(actual_historical_operator_source_upgrade=True,
                            previous_operator_sha256=initial_operator.parent.name,
                            upgraded_operator_sha256=receipt['operator']['operator_sha256'],
                            manager_source_upgrade_preserved_all_container_processes=True)
                    wrapper_bytes = wrapper.read_bytes()
                    assert receipt['wrapper_sha256'] == hashlib.sha256(wrapper_bytes).hexdigest()
                    def publish(name):
                        run('git', '-C', str(incoming), 'add', '.')
                        run('git', '-C', str(incoming), 'commit', '-m', name)
                        run('git', '-C', str(incoming), 'push', 'origin', 'main')
                        return run('git', '-C', str(incoming), 'rev-parse', 'HEAD').decode().strip()
                    def installed_update():
                        process = subprocess.run([str(wrapper), 'avito-update'],
                            env={**os.environ, 'CURL_CA_BUNDLE': str(ca)}, capture_output=True, timeout=300)
                        if process.returncode:
                            raise RuntimeError('Installed synthetic manager failed: ' + process.stderr.decode()[-2500:])
                        assert secret.encode() not in process.stdout + process.stderr
                    def processes():
                        ids = run(*command, '-f', str(shared / 'runtime/compose.override.yaml'), 'ps', '-q').decode().split()
                        return sorted(run('docker', 'inspect', '--format', '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}', *ids).decode().splitlines())
                    before = processes()
                    workflow = incoming / '.github/workflows/deploy.yml'
                    workflow.parent.mkdir(parents=True)
                    workflow.write_text('name: fixture-delegate\non: workflow_dispatch\n')
                    workflow_revision = publish('workflow-only fixture')
                    installed_update()
                    assert processes() == before
                    assert json.loads((shared / 'current.json').read_text())['baseline']['head'] == workflow_revision
                    revised = business.replace('    reverse_proxy frontend:80', '    header X-Fixture shared-manager\n    reverse_proxy frontend:80')
                    (incoming / 'deploy/Caddyfile').write_text(revised)
                    route_revision = publish('business Caddy route fixture')
                    installed_update()
                    assert processes() == before
                    headers = run('curl', '--fail', '--silent', '--show-error', '--noproxy', '*', '--cacert', str(ca),
                        '--max-time', '10', '--resolve', 'neighbor.fixture.invalid:443:127.0.0.1',
                        '--dump-header', '-', '--output', '/dev/null', 'https://neighbor.fixture.invalid/').lower()
                    assert b'x-fixture: shared-manager' in headers
                    assert json.loads((shared / 'current.json').read_text())['baseline']['head'] == route_revision
                    # Interrupt after a real fast-forward checkout. Invoke the
                    # actual installed package to resume its saved target.
                    (incoming / 'docs').mkdir()
                    (incoming / 'docs/fixture.txt').write_text('synthetic checkpoint\n')
                    recovered_revision = publish('interrupted checkout fixture')
                    killed = False
                    def die_after_merge(arguments, *, env=None):
                        nonlocal killed
                        output = execute(arguments, env=env)
                        if arguments[0] == 'git' and 'merge' in arguments and not killed:
                            killed = True
                            raise SystemExit('synthetic manager process died')
                        return output
                    try:
                        shared_update.update(shared, execute=die_after_merge)
                        raise AssertionError('Manager interruption was not injected')
                    except SystemExit: pass
                    assert killed and (shared / 'update.json').exists()
                    installed_update()
                    assert not (shared / 'update.json').exists() and processes() == before
                    assert json.loads((shared / 'current.json').read_text())['baseline']['head'] == recovered_revision
                    installed_update()
                    assert processes() == before
                    # Lose the response after Caddy has accepted a real reload.
                    # The controller must restore the previous routes, keep the
                    # target pending and let the installed command retry it.
                    revised = revised.replace('shared-manager', 'shared-manager-retried')
                    (incoming / 'deploy/Caddyfile').write_text(revised)
                    reload_revision = publish('lost reload response fixture')
                    lost_reload = False
                    def fail_after_reload(arguments, *, env=None):
                        nonlocal lost_reload
                        output = execute(arguments, env=env)
                        if arguments[:2] == ['docker', 'compose'] and 'reload' in arguments and not lost_reload:
                            lost_reload = True
                            raise RuntimeError('synthetic lost reload response')
                        return output
                    try:
                        shared_update.update(shared, execute=fail_after_reload)
                        raise AssertionError('Reload failure was not injected')
                    except RuntimeError: pass
                    assert lost_reload and (shared / 'update.json').exists()
                    assert b'header X-Fixture shared-manager\n' in (shared / 'runtime/caddy/Caddyfile').read_bytes()
                    assert processes() == before
                    installed_update()
                    assert not (shared / 'update.json').exists() and processes() == before
                    assert json.loads((shared / 'current.json').read_text())['baseline']['head'] == reload_revision
                    # Exercise the normal application pull/up path with public
                    # pinned fixture images and one real service recreation.
                    proposed = json.loads((incoming / 'deploy/docker-compose.yml').read_text())
                    proposed['services']['frontend']['cpus'] = 0.75
                    (incoming / 'deploy/docker-compose.yml').write_text(json.dumps(proposed))
                    app_revision = publish('application compose fixture')
                    old_frontend = run(*command, 'ps', '-q', 'frontend').decode().strip()
                    installed_update()
                    new_frontend = run(*command, 'ps', '-q', 'frontend').decode().strip()
                    assert new_frontend != old_frontend
                    after_application = processes()
                    assert sorted(row for row in before if not row.startswith(old_frontend)) == sorted(
                        row for row in after_application if not row.startswith(new_frontend))
                    assert json.loads((shared / 'current.json').read_text())['baseline']['head'] == app_revision
                    installed_update()
                    assert processes() == after_application
                    assert environment.read_bytes() == original + (plan / 'compose.env-line').read_bytes()
                    assert not run('git', '-C', str(repo), 'diff', '--name-only', 'HEAD').strip()
                    assert wrapper.read_bytes() == wrapper_bytes
                    result.update(installed_immutable_manager_cli=True, workflow_only_deploy_preserved_all_processes=True,
                        business_caddy_update_reloaded_without_process_restart=True, interrupted_git_checkout_resumed_by_installed_cli=True,
                        business_git_clean_and_environment_bytes_preserved=True, lost_reload_response_restored_known_routes=True,
                        installed_cli_retried_pending_reload=True, application_pull_and_service_recreate_preserved_other_processes=True)
                    result['source_sha256']['infra/shared_update.py'] = hashlib.sha256((ROOT / 'infra/shared_update.py').read_bytes()).hexdigest()
                    if initial_operator:
                        result['source_sha256']['infra/shared_config.py'] = hashlib.sha256((ROOT / 'infra/shared_config.py').read_bytes()).hexdigest()
                    result['limits'] = ['Synthetic Git/env/upstreams, public pinned images and internal certificates; no application schema migration, external ACME, shared port cutover or production migration.',
                                        'Public immutable operator packages retained; fixture manager wrapper removed; no systemd unit activated.']
                    if initial_operator:
                        result['limits'].append('Initial adoption used the actual historical operator; its previously proven fault drills were not repeated. Current certificate activation was not exercised.')
                    wrapper.unlink()
        except BaseException:
            print(run(*command, 'logs', '--tail', '12').decode(), file=sys.stderr)
            raise
        finally:
            if update and wrapper.exists():
                expected_wrappers = {shared_update._wrapper(shared, json.loads((plan / 'plan.json').read_text())['target']['operator'])}
                current = shared / 'current.json'
                if current.exists():
                    recorded = shared / 'plans' / json.loads(current.read_text())['plan'] / 'plan.json'
                    expected_wrappers.add(shared_update._wrapper(shared, json.loads(recorded.read_text())['target']['operator']))
                if wrapper.read_bytes() not in expected_wrappers: raise ValueError('Unexpected fixture wrapper edit; preserve for inspection')
                wrapper.unlink()
            run(*command, 'down', '--volumes', '--remove-orphans')
    for arguments in (['docker', 'ps', '-aq'], ['docker', 'network', 'ls', '-q'], ['docker', 'volume', 'ls', '-q']):
        assert not run(*arguments, '--filter', 'label=com.docker.compose.project=deploy').strip()
    result['fixture_resources_removed'] = True
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adopt', action='store_true')
    parser.add_argument('--update', action='store_true')
    parser.add_argument('--initial-operator', type=Path)
    args = parser.parse_args()
    main(adoption=args.adopt or args.update, update=args.update, initial_operator=args.initial_operator)
