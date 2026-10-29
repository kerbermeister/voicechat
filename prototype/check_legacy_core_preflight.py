"""Read a real synthetic legacy Compose baseline on the marked disposable VM.

No production data, credentials or image export. Uses cached fixture control and
web images, creates one test account, and removes only preflighted own resources.
"""
import argparse
import hashlib
import hmac
import json
import os
import re
from pathlib import Path
import secrets
import shutil
import sys
import subprocess
import tempfile
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import deploy
import legacy_core
import managed_state
import role_deploy
import role_release
import role_prepare
import core_deploy
import role_bootstrap


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control-image', required=True)
    parser.add_argument('--web-image', required=True)
    parser.add_argument('--legacy-source', type=Path, help='Verified exact Git source staged on this disposable VM')
    parser.add_argument('--candidate-control-image')
    parser.add_argument('--initial-cohost',action='store_true',help='Exercise the complete journaled migration instead of individual legacy primitives')
    parser.add_argument('--fault-drills',action='store_true',help='Inject full rollback and committed-response losses')
    parser.add_argument('--managed-backend',help='Pause after initial adoption for real normal SSH drills, using this source fingerprint')
    args = parser.parse_args()
    if (args.fault_drills or args.managed_backend) and not args.initial_cohost:parser.error('Drills require --initial-cohost')
    base = Path('/srv/voicechat-edge-fixture')
    if sys.platform != 'linux' or os.geteuid() != 0 or not base.is_dir() or base.is_symlink():
        raise ValueError('Use the marked disposable Linux VM')
    key = ' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    if json.loads((base / '.disposable-vm').read_text()) != {
            'kind': 'voicechat-disposable-vm', 'ssh_host_key_sha256': hashlib.sha256(key.encode()).hexdigest()}:
        raise ValueError('Disposable VM marker differs from this host')
    if subprocess.check_output(['systemctl','show','--property=SystemState','--value']).strip()!=b'running':
        raise ValueError('A healthy systemd host is required before creating fixture resources')
    def run(arguments, *, env=None, input=None):
        process = subprocess.run(arguments, env=env, input=input, capture_output=True, timeout=300)
        if process.returncode:
            path = ROOT / 'private-command-error.log'
            with path.open('wb') as output:
                os.fchmod(output.fileno(), 0o600)
                output.write(process.stderr)
            raise RuntimeError('Legacy fixture command failed; private stderr saved')
        if len(process.stdout) > 1024 * 1024: raise ValueError('Oversized fixture command output')
        return process.stdout
    for arguments in (['docker', 'ps', '-aq', '--filter', 'label=com.docker.compose.project=voicechat'],
                      ['docker', 'volume', 'ls', '-q', '--filter', 'name=^voicechat_'],
                      ['docker', 'network', 'ls', '-q', '--filter', 'name=^voicechat_default$']):
        if run(arguments).strip(): raise ValueError('Existing legacy resources must not be adopted by a fixture')
    boot_unit = Path('/etc/systemd/system/voicechat-core.service')
    if boot_unit.exists() or boot_unit.is_symlink(): raise ValueError('Existing core boot unit must not be adopted by a fixture')
    source = ROOT
    source_record = None
    if args.legacy_source is not None:
        source = args.legacy_source.absolute()
        if source.resolve() != source or source.parent != base or not source.is_dir():
            raise ValueError('Canonical staged disposable source required')
        source_record = managed_state.read(source / 'source.json')
        if (source_record['schema'] != 1 or not re.fullmatch(r'[a-f0-9]{40}', source_record['commit']) or
                not role_release.SHA.fullmatch(source_record['backend'])):
            raise ValueError('Invalid staged Git identity')
        for name, expected in source_record['files'].items():
            path = source / name
            if (Path(name).parts[0] not in ('infra','prototype') or len(Path(name).parts) != 2 or
                    path.resolve() != path or not path.is_file() or
                    hashlib.sha256(path.read_bytes()).hexdigest() != expected):
                raise ValueError('Staged Git source hash differs')
    for image in (args.control_image, args.web_image, args.candidate_control_image or args.control_image): run(['docker', 'image', 'inspect', image])
    nonce = uuid.uuid4().hex[:10]
    neighbor = 'vc-legacy-neighbor-' + nonce
    root = Path(tempfile.mkdtemp(prefix='legacy-preflight-', dir=base))
    root.chmod(0o700)
    runtime = root / 'runtime'; runtime.mkdir(mode=0o700)
    (root / 'deploy.lock').touch(mode=0o644)
    for name in ('android-updates', 'macos-updates'): (runtime / name).mkdir(mode=0o755)
    release = root / 'releases' / (source_record['commit'] if source_record else 'a' * 40)
    release.mkdir(parents=True)
    for folder in ('infra', 'prototype'):
        destination = release / folder; destination.mkdir(mode=0o755)
        for item in (source / folder).iterdir():
            if item.is_file() and not item.is_symlink():
                if source_record is not None and str(item.relative_to(source)) not in source_record['files']:
                    raise ValueError('Unrecorded staged Git source')
                target = destination / item.name
                target.write_bytes(item.read_bytes()); target.chmod(0o644)
    (release / 'infra/runtime').symlink_to(runtime)
    origin, server_name = 'https://chat.fixture.invalid', 'chat.fixture.invalid'
    values = {'LOCAL_STAND': '0', 'MATRIX_SERVER_NAME': server_name, 'PUBLIC_URL': origin,
        'PUBLIC_IP': '192.0.2.10', 'BIND': '127.0.0.1', 'HTTP_PORT': '18080', 'HTTPS_PORT': '18443',
        'SITE': ':80', 'SMTP_HOST': 'smtp.example.invalid', 'SMTP_PORT': '587',
        **{name: secrets.token_hex(32) for name in ('POSTGRES_PASSWORD', 'LIVEKIT_SECRET', 'POLICY_SECRET',
                                                  'REGISTRATION_SECRET', 'MACAROON_SECRET', 'TURN_SECRET')}}
    (runtime / 'stand.env').write_text(''.join(key + '=' + value + '\n' for key, value in values.items()))
    (runtime / 'stand.env').chmod(0o600)
    override = runtime / 'compose.override.yaml'
    original = '''services:
  web:
    ports: !override []
    networks:
      default: {}
      neighbor:
        aliases: [voicechat-web]
networks:
  neighbor:
    external: true
    name: ''' + neighbor + '\n'
    override.write_text(original); override.chmod(0o600)
    manifest = {'schema': 1, 'commit': source_record['commit'] if source_record else 'a' * 40, 'origin': origin,
                'control': args.control_image, 'web': args.web_image}
    (release / 'release.json').write_text(json.dumps(manifest))
    # Exact Git fingerprint when staged; the runtime/accounts remain synthetic.
    (release / 'backend.sha256').write_text(source_record['backend'] if source_record else
        hashlib.sha256(b'synthetic-legacy-preflight').hexdigest())
    env = legacy_core.environment({'manifest': manifest})
    def compose(*arguments): return run(deploy.compose_command(release, *arguments), env=env)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def api(path, body=None, token=None):
        headers = {'Content-Type': 'application/json'}
        if token: headers['Authorization'] = 'Bearer ' + token
        request = urllib.request.Request('http://127.0.0.1:8088' + path,
            None if body is None else json.dumps(body).encode(), headers)
        with opener.open(request, timeout=20) as response: return json.load(response)
    baseline = None
    owned_unit = None
    network_scope = None
    if args.initial_cohost:
        from initial_cohost_network import isolated_network
        scope = isolated_network(root)
        scope.__enter__()
        network_scope = scope
    try:
        run(['docker', 'network', 'create', '--label', 'voicechat.fixture=' + nonce, neighbor])
        # Fixture images are already cached; do not request registry credentials.
        compose('up', '-d', '--pull', 'never', '--wait', '--wait-timeout', '180')
        model = json.loads(compose('config', '--format', 'json'))
        record = deploy.release_record(release, manifest, model)
        (root / 'current.json').write_text(json.dumps(record))
        challenge = api('/_synapse/admin/v1/register')['nonce']
        username, password = 'legacy_preflight', secrets.token_urlsafe(24)
        mac = hmac.new(values['REGISTRATION_SECRET'].encode(),
            '\0'.join((challenge, username, password, 'notadmin')).encode(), hashlib.sha1).hexdigest()
        api('/_synapse/admin/v1/register', {'nonce': challenge, 'username': username,
            'password': password, 'admin': False, 'mac': mac})
        session = api('/_matrix/client/v3/login', {'type': 'm.login.password', 'user': username, 'password': password})
        api('/_matrix/client/v3/pushers/set', {'app_id': 'dev.voicechat.web',
            'pushkey': 'synthetic-' + nonce, 'kind': 'http', 'app_display_name': 'VoiceChat fixture',
            'device_display_name': 'fixture', 'lang': 'en', 'append': False,
            'data': {'url': origin + '/_matrix/push/v1/notify', 'format': 'event_id_only'}},
            token=session['access_token'])
        before = (root / 'current.json').read_bytes()
        baseline = legacy_core.inspect(root, execute=run)
        if args.initial_cohost:
            from check_initial_cohost import exercise
            result = {'schema':1, **exercise(root,baseline,neighbor,session,
                control_image=args.candidate_control_image or args.control_image,
                web_image=args.web_image,run=run,fault_drills=args.fault_drills,managed_backend=args.managed_backend),
                'legacy_source_commit':source_record['commit'] if source_record else None,
                'legacy_control_image':args.control_image}
        else:
            identity = api('/_matrix/client/v3/account/whoami', token=session['access_token'])
            if identity['user_id'] != session['user_id'] or identity['device_id'] != session['device_id']:
                raise AssertionError('Read-only preflight lost the synthetic account')
            if (root / 'current.json').read_bytes() != before: raise AssertionError('Preflight changed the baseline pointer')
            override.write_text(original.replace('services:\n', 'services:\n  control:\n    environment:\n      VOICECHAT_LAB: "1"\n', 1))
            try: legacy_core.inspect(root, execute=run)
            except ValueError as error:
                if 'recorded backend baseline' not in str(error): raise
            else: raise AssertionError('Changed runtime override must not be adopted')
            override.write_text(original)
            saved_network = managed_state.read(Path('/var/lib/voicechat-network/desired.json'))
            inventory = {**saved_network['inventory'], 'edges': [{'id': 'a', 'host': 'core'}]}
            public = {'schema': 1, 'service_id': inventory['service_id'], 'canonical_origin': origin,
                'matrix_server_name': server_name, 'web_origins': [origin],
                'edges': [{'id': 'a', 'origin': origin, 'turn_host': 'turn.fixture.invalid'}]}
            core = root / 'managed-core'
            target = role_release.make(public, inventory, 'core', 'b' * 40, args.candidate_control_image or args.control_image)
            legacy_core.require_compatible(baseline, target)
            role_prepare.prepare(core, public, inventory, target)
            shutil.copyfile(runtime / 'stand.env', core / 'runtime/stand.env')
            (core / 'runtime/stand.env').chmod(0o600)
            target_record = core_deploy.record_for(core, inventory, target)
            attempt = 'c' * 64
            try: core_deploy.migrate_push_routes(core, target_record, attempt, baseline['data_identity'], execute=run)
            except ValueError as error:
                if 'Stop all Synapse/control' not in str(error): raise
            else: raise AssertionError('Migration must reject active writers')
            marker = {'schema':1, 'operation':'full-rollout', 'root':str(core), 'attempt':attempt,
                      'target':role_release.json_digest(target),
                      'owner':role_release.json_digest(managed_state.read(core/'role.json'))}
            managed_state.persist(core/'runtime/full-rollout.json',marker)
            # A real Type=notify unit must exit successfully under planned full
            # maintenance, without starting a role or entering a restart loop.
            role_bootstrap.install(core,'core')
            owned_unit = role_bootstrap.plan(core,'core',None)[3]
            run(['systemctl','reset-failed','voicechat-core.service'])
            run(['systemctl','start','voicechat-core.service'])
            deadline = time.monotonic() + 15
            while True:
                boot = dict(line.split('=',1) for line in run(['systemctl','show','voicechat-core.service',
                    '--property=ActiveState,Result,ExecMainStatus,NRestarts']).decode().splitlines() if '=' in line)
                if boot.get('ActiveState') in ('inactive','failed') or time.monotonic() >= deadline: break
                time.sleep(.1)
            if boot != {'ActiveState':'inactive','Result':'success','ExecMainStatus':'0','NRestarts':'0'}:
                raise AssertionError('Full maintenance did not suppress role boot without restarts: '+json.dumps(boot))
            identifiers = list(baseline['containers'].values())
            def processes():
                return run(['docker','inspect','--format','{{.Id}} {{.State.StartedAt}} {{.RestartCount}}',*identifiers])
            before_restart_fence = processes()
            lost = True
            def lost_reply(arguments, **kwargs):
                nonlocal lost
                value = run(arguments, **kwargs)
                if arguments[:2]==['docker','update'] and lost:
                    lost=False;raise SystemExit('Lost actual restart policy reply')
                return value
            try: legacy_core.fence_restart(root,baseline,execute=lost_reply)
            except SystemExit: pass
            else: raise AssertionError('Expected lost restart policy response')
            legacy_core.fence_restart(root,baseline,execute=run)
            if processes()!=before_restart_fence: raise AssertionError('Restart fencing changed a legacy process')
            compose('stop', 'web', 'synapse', 'control', 'turn')
            stopped = legacy_core.inspect(root, require_running=False, restart_policy='fenced', execute=run)
            if stopped['data_identity'] != baseline['data_identity']:
                raise AssertionError('Stopped-writer preflight changed the database/signing identity')
            compose('stop','postgres')
            if legacy_core.inspect(root,require_running=False,restart_policy='fenced',execute=run)!=baseline:
                raise AssertionError('Stopped-database fenced resume changed legacy identity')
            run(['docker','start',baseline['containers']['postgres']])
            deadline=time.monotonic()+60
            while json.loads(run(['docker','inspect','--format','{{json .State.Health.Status}}',baseline['containers']['postgres']]))!='healthy':
                if time.monotonic()>=deadline:raise TimeoutError('Fixture PostgreSQL did not recover')
                time.sleep(.5)
            # The maintenance caller holds the legacy lock and verifies its backup.
            with legacy_core.locked(root):
                deploy.backup(root, release, env)
                change_host = '''import json,sys
    from pathlib import Path
    path=Path('/data/homeserver.yaml');value=json.loads(path.read_text())
    value['database']['args']['host']=sys.argv[1];path.write_text(json.dumps(value))
    '''
                def database_host(host):
                    run(['docker','run','--rm','--read-only','--network','none','--cap-drop','ALL',
                        '--security-opt','no-new-privileges:true','--user','991:991',
                        '--mount','type=volume,source=voicechat_synapse,target=/data,volume-nocopy',
                        '--entrypoint','python3',baseline['images']['configure'],'-B','-c',change_host,host])
                database_host('foreign.example.invalid')
                try: core_deploy.migrate_push_routes(core, target_record, attempt, baseline['data_identity'], execute=run, rollout_attempt=attempt)
                except RuntimeError: pass
                else: raise AssertionError('Foreign database target must be rejected before SQL')
                database_host('postgres')
                def migrate(reverse=False):
                    return core_deploy.migrate_push_routes(core, target_record, attempt,
                        baseline['data_identity'], reverse=reverse, execute=run, rollout_attempt=attempt)
                if migrate()!=1 or migrate()!=1: raise AssertionError('Forward driver/resume did not find the test pusher')
                def pusher():
                    return json.loads(compose('exec','-T','postgres','psql','-U','synapse','-d','synapse','-At','-c',
                        "SELECT data FROM pushers WHERE app_id='dev.voicechat.web' AND kind='http' ORDER BY id").decode())
                if pusher()['url']!='http://'+target_record['address']+':8090/_matrix/push/v1/notify':
                    raise AssertionError('Pusher did not move to the private gateway')
                compose('exec','-T','postgres','psql','-U','synapse','-d','synapse','-c',
                    "UPDATE pushers SET data=jsonb_set(data::jsonb,'{fixture_marker}','\"current\"'::jsonb)::text WHERE app_id='dev.voicechat.web' AND kind='http'")
                if migrate(reverse=True)!=1: raise AssertionError('Current-row reverse driver did not find the test pusher')
                current=pusher()
                if current['url']!=origin+'/_matrix/push/v1/notify' or current.get('fixture_marker')!='current':
                    raise AssertionError('Reverse migration lost current pusher metadata')
                if core_deploy.data_identity(core,target_record,execute=run)!=baseline['data_identity']:
                    raise AssertionError('SQL maintenance changed persistent identity')
            # Recreate legacy containers without deleting data, then prove that the
            # temporary original-volume binding also survives a normal legacy up.
            rollback = core / 'runtime/legacy-recovery.json'
            managed_state.persist(rollback, legacy_core.rollback_override(baseline))
            compose('down')
            run([*deploy.compose_command(release), '-f', str(rollback), 'up', '-d', '--pull', 'never',
                 '--wait', '--wait-timeout', '180'], env=env)
            compose('up', '-d', '--pull', 'never', '--wait', '--wait-timeout', '180')
            restored = legacy_core.inspect(root, execute=run)
            if restored['data_identity'] != baseline['data_identity'] or restored['implicit_volumes'] != baseline['implicit_volumes']:
                raise AssertionError('Legacy recreation lost persistent database/key/TURN runtime identity')
            identity = api('/_matrix/client/v3/account/whoami', token=session['access_token'])
            if identity['user_id'] != session['user_id'] or identity['device_id'] != session['device_id']:
                raise AssertionError('Legacy recreation lost account/device access')
            if (root / 'current.json').read_bytes() != before:
                raise AssertionError('Legacy recreation forged the release baseline')
            result = {'schema': 1, 'production_changed': False,
                'actual_restart_policy_fence_lost_reply_resume_preserved_processes':True,
                'fenced_stopped_database_identity_checked_then_restarted':True,
                'actual_systemd_full_maintenance_exited_successfully_with_zero_restarts':True,
                'real_legacy_six_services_seven_declared_and_coturn_implicit_volumes_verified': True,
                'real_readonly_probe_preserved_account_device_and_pointer': True,
                'actual_changed_compose_override_rejected': True,
                'actual_stopped_writer_preflight_preserved_data_identity': True,
                'cohost_web_external_alias_and_no_public_ports_verified': True,
                'actual_stopped_writer_backup_before_sql_driver': True,
                'active_writer_and_foreign_database_target_refused': True,
                'actual_pusher_forward_resume_and_current_metadata_reverse': True,
                'legacy_recreation_preserved_account_device_database_signing_and_coturn_runtime': True,
                'normal_legacy_up_after_temporary_volume_binding_preserved_runtime': True,
                'legacy_source_commit': source_record['commit'] if source_record else None,
                'legacy_source_files': source_record['files'] if source_record else None,
                'legacy_control_image': args.control_image,
                'candidate_control_image': args.candidate_control_image or args.control_image,
                'limits': [('Exact staged legacy Git source with source-built legacy control; synthetic accounts/configuration.'
                            if source_record else 'Synthetic legacy Compose from current repository sources, cached source-built control and web images.'),
                           'No production baseline adoption, core/edge transition or physical device acceptance.']}
    finally:
        if boot_unit.exists() or boot_unit.is_symlink():
            if owned_unit is None or boot_unit.is_symlink() or boot_unit.read_bytes()!=owned_unit:
                raise ValueError('Unknown core boot unit must be preserved')
            run(['systemctl','disable','--now','voicechat-core.service'])
            boot_unit.unlink();run(['systemctl','daemon-reload'])
        override.write_text(original)
        compose('down', '--volumes', '--remove-orphans')
        if baseline is not None:
            for volumes in baseline['implicit_volumes'].values():
                for volume in volumes.values():
                    if run(['docker','volume','ls','-q','--filter','name=^'+volume+'$']).strip():
                        labels=json.loads(run(['docker','volume','inspect','--format','{{json .Labels}}',volume]))
                        if 'com.docker.volume.anonymous' not in (labels or {}):
                            raise ValueError('Unknown implicit runtime volume must be preserved')
                        run(['docker','volume','rm',volume])
        label = run(['docker', 'network', 'inspect', '--format', '{{index .Labels "voicechat.fixture"}}', neighbor]).decode().strip()
        if label != nonce: raise ValueError('Unknown neighbor network must be preserved')
        run(['docker', 'network', 'rm', neighbor])
        if network_scope is not None:
            network_scope.__exit__(None,None,None)
        shutil.rmtree(root)
    if run(['docker', 'volume', 'ls', '-q', '--filter', 'name=^voicechat_']).strip():
        raise AssertionError('Fixture volumes were not removed')
    result['fixture_resources_removed'] = True
    (ROOT/'.prototype').mkdir(mode=0o700,exist_ok=True)
    (ROOT/'.prototype/legacy-core-preflight-evidence.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))


if __name__ == '__main__': main()
