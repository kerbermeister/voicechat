"""Synthetic business Caddy fixture for check_shared_front_warm.py --cutover.

Run only through that marked disposable VM harness. Uses VM ports 80/443,
disposable certs/data, and removes only the preflighted fixture resources.
"""
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import edge_deploy
import managed_state
import role_config
import shared_config
import shared_cutover
import shared_ingress as ingress
import shared_update


def exercise(directory, edge, manifest, public, inventory, run, *, after_commit=None):
    root, repo = directory / 'shared', directory / 'repo'
    front_plan = root / 'front/plans' / managed_state.read(root / 'front/warm.json')['plan']
    wrapper = Path('/usr/local/sbin/voicechat-shared-deploy')
    if wrapper.exists() or wrapper.is_symlink(): raise ValueError('Fixture must not replace an existing ingress manager')
    for arguments in (['docker', 'ps', '-aq'], ['docker', 'network', 'ls', '-q'], ['docker', 'volume', 'ls', '-q']):
        if run([*arguments, '--filter', 'label=com.docker.compose.project=deploy']).strip():
            raise ValueError('Existing business resources must not be adopted by the fixture')
    for volume in ('deploy_caddy_data', 'deploy_caddy_config'):
        if run(['docker', 'volume', 'ls', '-q', '--filter', 'name=^' + volume + '$']).strip():
            raise ValueError('Existing Caddy volumes must not be adopted by the fixture')
    containers = run(['docker', 'ps', '-q']).decode().split()
    for identifier in containers:
        ports = json.loads(run(['docker', 'inspect', '--format', '{{json .HostConfig.PortBindings}}', identifier])) or {}
        if any(item['HostPort'] in ('80', '443') for bindings in ports.values() for item in (bindings or [])):
            raise ValueError('VM public HTTP/TLS ports are already occupied')
    deploy = repo / 'deploy'; deploy.mkdir(parents=True)
    ca = directory / 'ca.crt'
    business = '''{$DOMAIN} {
    tls /data/fixture.crt /data/fixture.key
    reverse_proxy frontend:80
}
'''
    (deploy / 'Caddyfile').write_text(business)
    (deploy / 'upstream.py').write_text('''from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'synthetic-upstream')
HTTPServer(('0.0.0.0', 80), Handler).serve_forever()
''')
    stub = {'image': role_config.pinned_image('configure'), 'entrypoint': ['python3', '/upstream.py'],
            'volumes': ['./upstream.py:/upstream.py:ro'], 'environment': {'PYTHONDONTWRITEBYTECODE': '1'}}
    model = {'name': 'deploy', 'services': {
        'caddy': {'image': ingress.CADDY_IMAGE, 'restart': 'unless-stopped',
            'environment': {'DOMAIN': '${DOMAIN:?}'}, 'ports': ['80:80', '443:443'],
            'volumes': ['./Caddyfile:/etc/caddy/Caddyfile:ro', 'caddy_data:/data', 'caddy_config:/config'],
            'depends_on': ['frontend', 'voicechat-web']},
        'frontend': stub, 'voicechat-web': stub}, 'volumes': {'caddy_data': {}, 'caddy_config': {}}}
    source = deploy / 'docker-compose.yml'; source.write_text(json.dumps(model))
    environment = deploy / '.env'
    environment.write_text('DOMAIN=neighbor.fixture.invalid\n'); environment.chmod(0o600)
    original_environment = environment.read_bytes()
    run(['git', '-C', str(repo), 'init', '-b', 'main'])
    run(['git', '-C', str(repo), 'add', 'deploy/Caddyfile', 'deploy/docker-compose.yml', 'deploy/upstream.py'])
    run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'fixture'])
    remote = directory / 'business.git'
    run(['git', 'clone', '--bare', str(repo), str(remote)])
    run(['git', '-C', str(repo), 'remote', 'add', 'origin', str(remote)])
    (deploy / 'Caddyfile').write_text(ingress.legacy_config(business, public))
    command = ['docker', 'compose', '--env-file', str(environment), '--project-name', 'deploy', '-f', str(source)]
    def https(host, path='/'):
        return ['curl', '--fail', '--silent', '--show-error', '--max-time', '10', '--output', '/dev/null',
            '--noproxy', '*', '--cacert', str(ca), '--resolve', host + ':443:127.0.0.1', 'https://' + host + path]
    def legacy_health(target, baseline, *, execute):
        execute(https(baseline['domain']))
        execute(https('chat.fixture.invalid', '/_matrix/client/versions'))
    def business_health(target, baseline, *, execute): execute(https(baseline['domain']))
    def execute(args, *, env=None):
        # This fixture stores an explicit manual cert in the already-owned data
        # volume. Provisioning validation needs that read-only fixture mount.
        if args[:2] == ['docker', 'run'] and 'validate' in args and '--mount' not in args:
            index = args.index(ingress.CADDY_IMAGE)
            args = [*args[:index], '--mount', 'type=volume,source=deploy_caddy_data,target=/data,readonly,volume-nocopy', *args[index:]]
        return run(args, env=env)
    try:
        print('Cutover fixture: preparing private certificate volumes', file=sys.stderr, flush=True)
        for name in ('caddy_data', 'caddy_config'):
            run(['docker', 'volume', 'create', '--label', 'com.docker.compose.project=deploy',
                 '--label', 'com.docker.compose.volume=' + name, 'deploy_' + name])
        script = ("from pathlib import Path\n"
            "for source,target,mode in (('/chain','/data/fixture.crt',0o644),('/key','/data/fixture.key',0o600)):\n"
            "    path=Path(target);path.write_bytes(Path(source).read_bytes());path.chmod(mode)\n")
        run(['docker', 'run', '--rm', '--network', 'none',
            '--mount', 'type=volume,source=deploy_caddy_data,target=/data',
            '--volume', str(directory / 'server.chain') + ':/chain:ro',
            '--volume', str(directory / 'server.key') + ':/key:ro',
            '--entrypoint', 'python3', role_config.pinned_image('configure'), '-c', script])
        run([*command, 'up', '-d', '--wait', '--wait-timeout', '60'])
        deadline = time.monotonic() + 60
        while True:
            try:
                legacy_health(None, {'domain': 'neighbor.fixture.invalid'}, execute=execute)
                break
            except (OSError, RuntimeError):
                if time.monotonic() >= deadline: raise
                time.sleep(.5)
        print('Cutover fixture: adopting legacy ingress', file=sys.stderr, flush=True)
        legacy = ingress.stage(root, repo, edge, public, inventory, 'warmfixture', business)
        ingress.adopt_legacy(root, legacy, execute=execute, health=legacy_health)
        shared_update.install(root, execute=execute, health=legacy_health)
        print('Cutover fixture: preparing certificate sinks', file=sys.stderr, flush=True)
        certificates = ingress.stage(root, repo, edge, public, inventory, 'warmfixture', business, mode='legacy-certs')
        shared_config.prepare_certificates(root, certificates, execute=execute, health=legacy_health)
        target = ingress.stage(root, repo, edge, public, inventory, 'warmfixture', business, mode='shared')
        edge_record = edge_deploy.record_for(public, inventory, manifest)
        managed_state.persist(edge / 'state.json', {'schema': 1, 'current': edge_record, 'previous': None, 'pending': None})
        caddy = shared_update._ids(managed_state.read(root / 'current.json'), execute)
        neighbors = ingress.snapshot({'deploy'}, excluding=caddy, execute=execute)
        class Faults:
            boundary = None
            fail_public = True
        faults = Faults()
        def fault_execute(args, *, env=None):
            result = execute(args, env=env)
            if args[:2] == ['docker', 'compose'] and 'up' in args:
                point = 'caddy' if args[-1] == 'caddy' else 'front'
                if faults.boundary == point:
                    faults.boundary = None
                    raise SystemExit('Injected lost ' + point + ' recreation response')
            return result
        def edge_health(root, record, *, execute, warm_port=None):
            edge_deploy.healthy(root, record, execute=execute, warm_port=warm_port)
            if warm_port is None and faults.fail_public:
                raise ValueError('Injected public readiness failure after real TLS')
        def activate():
            return shared_cutover.activate(root, target, front_plan, execute=fault_execute,
                check_edge=edge_health, check_business=business_health)
        for point in ('caddy', 'front'):
            print('Cutover fixture: interruption and rollback at ' + point, file=sys.stderr, flush=True)
            faults.boundary = point
            try: activate()
            except SystemExit: pass
            else: raise AssertionError('Expected interruption at ' + point)
            assert (root / 'configuration.json').exists()
            try: activate()
            except ValueError as error: assert 'Injected public readiness' in str(error)
            else: raise AssertionError('Expected actual cutover rollback')
            assert managed_state.read(root / 'current.json')['plan'] == certificates.name
            assert managed_state.read(root / 'front/warm.json')['phase'] == 'running'
            assert not (root / 'configuration.json').exists()
            legacy_health(None, {'domain': 'neighbor.fixture.invalid'}, execute=execute)
            assert ingress.snapshot({'deploy'}, excluding=shared_update._ids(managed_state.read(root / 'current.json'), execute), execute=execute) == neighbors
        faults.fail_public = False
        print('Cutover fixture: committing public ingress', file=sys.stderr, flush=True)
        result = activate()
        assert result['plan'] == target.name and set(result['ports']) == {'80/tcp'}
        assert managed_state.read(root / 'front/warm.json')['phase'] == 'public'
        before = ingress.snapshot({'deploy', 'voicechat-shared-front'}, execute=execute)
        activate()
        assert ingress.snapshot({'deploy', 'voicechat-shared-front'}, execute=execute) == before
        shared_update.update(root, execute=execute, health=business_health)
        assert ingress.snapshot({'deploy', 'voicechat-shared-front'}, execute=execute) == before
        assert environment.read_bytes() == original_environment + (legacy / 'compose.env-line').read_bytes()
        assert not (root / 'configuration.json').exists()
        extra = after_commit(directory, edge, public, inventory, run) if after_commit else {}
        return {'loopback_listener_only': False, 'real_public_port_cutover': True,
            'operator_sha256': managed_state.read(root / 'manager.json')['operator']['operator_sha256'],
            'caddy_recreation_interruption_resumed': True, 'front_recreation_interruption_resumed': True,
            'actual_failed_cutover_restored_legacy_https': True, 'unrelated_upstream_processes_preserved': True,
            'committed_cutover_repeat_preserved_processes': True, 'business_manager_shared_mode_noop_verified': True,
            'limits': ['Marked disposable VM ports 80/443 and synthetic business/API/TURN TLS backends.',
                       'No production migration, real core database, TURN allocation/media or reboot.'], **extra}
    except BaseException:
        print(run([*command, 'logs', '--tail', '20']).decode(), file=sys.stderr, flush=True)
        raise
    finally:
        try:
            if wrapper.exists() or wrapper.is_symlink():
                if (root / 'manager.json').exists(): operator = managed_state.read(root / 'manager.json')['operator']
                else:
                    current = managed_state.read(root / 'current.json')
                    operator = managed_state.read(root / 'plans' / current['plan'] / 'plan.json')['target']['operator']
                assert not wrapper.is_symlink() and wrapper.read_bytes() == shared_update._wrapper(root, operator)
                wrapper.unlink()
        finally:
            run([*command, 'down', '--volumes', '--remove-orphans'])
        for arguments in (['docker', 'ps', '-aq'], ['docker', 'network', 'ls', '-q'], ['docker', 'volume', 'ls', '-q']):
            assert not run([*arguments, '--filter', 'label=com.docker.compose.project=deploy']).strip()
