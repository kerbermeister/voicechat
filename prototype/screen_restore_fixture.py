#!/usr/bin/env python3
"""Full local Compose restore drill, with new projects/volumes and test-only data."""
import json
import io
import base64
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import tarfile
import traceback

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'infra'))
import deploy


def quiet(args, **kwargs):
    kwargs.setdefault('stdout', subprocess.DEVNULL)
    kwargs.setdefault('stderr', subprocess.DEVNULL)
    return subprocess.run(args, check=True, **kwargs)


def main():
    deploy.execute = quiet
    with tempfile.TemporaryDirectory(prefix='voicechat-screen-restore-') as directory:
        root = Path(directory)
        release = root/'release'
        archive = subprocess.check_output(['git', 'archive', 'HEAD'], cwd=ROOT)
        with tarfile.open(fileobj=io.BytesIO(archive)) as source_archive:
            source_archive.extractall(release, filter='data')
        shutil.copy2(ROOT/'infra/deploy.py', release/'infra/deploy.py')
        runtime = root/'runtime'
        # Bootstrap creates private random credentials, a new immutable test identity,
        # and a mail sink. No existing runtime or production volume is read.
        quiet([sys.executable, str(release/'infra/bootstrap.py'), '--url', 'http://localhost:7364',
               '--server-name', 'screen-restore-fixture.local'],
              env={**os.environ, 'SMTP_HOST': 'mailpit', 'SMTP_PORT': '1025',
                   'SMTP_USER': '', 'SMTP_PASSWORD': '', 'SMTP_FROM': ''})
        shutil.move(release/'infra/runtime', runtime)
        (release/'infra/runtime').symlink_to(runtime, target_is_directory=True)
        env_file = runtime/'stand.env'
        values = dict(line.split('=', 1) for line in env_file.read_text().splitlines())
        values = {k: v.strip("'") for k, v in values.items()}
        image = subprocess.check_output(['docker', 'image', 'inspect', 'voicechat-screen-control:test',
                                         '--format', '{{.Id}}'], text=True).strip()
        values.update(CONTROL_IMAGE=image, HTTPS_PORT='7365')
        env_file.write_text(''.join(f"{k}='{v}'\n" for k, v in values.items()))
        override = {'services': {'control': {'environment': {
            'VOICECHAT_ORIGINS': 'http://localhost:7363,http://localhost:7364'}}}}
        (runtime/'compose.override.yaml').write_text(json.dumps(override))
        record = {'scope': 'local drill, not a published release manifest', 'control': image}
        (root/'current.json').write_text(json.dumps(record))
        suffix = secrets.token_hex(5)
        source = {**os.environ, 'COMPOSE_PROJECT_NAME': 'voicechat-screen-source-'+suffix}
        target = {**os.environ, 'COMPOSE_PROJECT_NAME': 'voicechat-screen-target-'+suffix}
        current = source

        def compose(env, *args, **kwargs):
            return deploy.compose(release, env, *args, **kwargs)

        def output(env, *args):
            return subprocess.check_output(deploy.compose_command(release, *args),
                                           env=env, text=True, stderr=subprocess.DEVNULL).strip()

        def config(env):
            return json.loads(output(env, 'config', '--format', 'json'))

        def control(code):
            return output(current, 'exec', '-T', 'control', 'python3', '-c', code)

        def state():
            return json.loads(control("import sys,json;sys.path.insert(0,'prototype');"
                "from screen_status import status;print(json.dumps(status('.prototype/calls/calls.sqlite')))"))

        def flag(value):
            control("from pathlib import Path;p=Path('.prototype/screen-enabled');"
                    f"p.write_text('{value}');p.chmod(0o600)")

        def sql(env):
            return output(env, 'exec', '-T', 'postgres', 'psql', '-U', 'synapse', '-d', 'synapse',
                '-At', '-c', "SELECT count(*) FROM users; SELECT count(*) FROM events WHERE type='m.room.encrypted';")

        try:
            compose(source, 'up', '-d', '--wait', '--wait-timeout', '180')
            assert config(source)['services']['configure']['environment']['LOCAL_STAND'] == '1'
            flag(1)
            info = {'api_port': 7364, 'api_path': '/api', 'matrix_url': 'http://localhost:7364',
                    'registration_url': 'http://localhost:8088',
                    'livekit_url': 'ws://localhost:7364', 'image_id': image,
                    'registration_secret': values['REGISTRATION_SECRET'],
                    'sfu_secret': values['LIVEKIT_SECRET']}
            print(json.dumps(info), flush=True)
            for line in sys.stdin:
                action = line.strip()
                extra = {}
                if action == 'backup_restore':
                    assert state()['sessions'].get('active') == 1
                    expected = sql(source)
                    assert all(int(v) > 0 for v in expected.splitlines())
                    compose(source, 'stop', 'web', 'synapse', 'control', 'turn')
                    deploy.backup(root, release, source)
                    restic = ['docker', 'run', '--rm', '-e', 'RESTIC_PASSWORD_FILE=/password',
                        '-v', f'{runtime}/backup-password:/password:ro',
                        '-v', f'{root}/backups/repository:/repository:ro', deploy.RESTIC, '-r', '/repository', '--no-lock']
                    snapshots = json.loads(subprocess.check_output([*restic, 'snapshots', '--json'], stderr=subprocess.DEVNULL))
                    assert len(snapshots) == 1
                    restored = root/'restored'
                    restored.mkdir(mode=0o700)
                    quiet(['docker', 'run', '--rm', '-e', 'RESTIC_PASSWORD_FILE=/password',
                        '-v', f'{runtime}/backup-password:/password:ro',
                        '-v', f'{root}/backups/repository:/repository:ro', '-v', f'{restored}:/restore',
                        deploy.RESTIC, '-r', '/repository', '--no-lock', 'restore', snapshots[0]['id'], '--target', '/restore'])
                    python = config(source)['services']['configure']['image']
                    source_volumes, target_volumes = config(source)['volumes'], config(target)['volumes']
                    assert {v['name'] for v in source_volumes.values()}.isdisjoint(v['name'] for v in target_volumes.values())
                    compose(source, 'down')  # Keep original volumes for independent cleanup.
                    recovered_runtime = root/'recovered-runtime'
                    recovered_runtime.mkdir(mode=0o700)
                    recovered_env = restored/'snapshot/runtime/stand.env'
                    assert recovered_env.read_bytes() == env_file.read_bytes()
                    shutil.copy2(recovered_env, recovered_runtime/'stand.env')
                    (recovered_runtime/'stand.env').chmod(0o600)
                    shutil.copy2(restored/'snapshot/database/compose.override.yaml', recovered_runtime/'compose.override.yaml')
                    recovered_release = root/'recovered-release'
                    shutil.copytree(restored/'snapshot/release', recovered_release, symlinks=True)
                    (recovered_release/'infra/runtime').unlink()
                    (recovered_release/'infra/runtime').symlink_to(recovered_runtime, target_is_directory=True)
                    release = recovered_release
                    for volume in target_volumes.values():
                        quiet(['docker', 'volume', 'create', volume['name']])
                    mounts = [item for name in ('synapse', 'control', 'media-config', 'certificates', 'caddy-config')
                              for item in ('-v', target_volumes[name]['name']+':/volumes/'+name)]
                    check = r"""
from pathlib import Path
import hashlib,json,os,shutil,sqlite3
snapshot=Path('/restore/snapshot')
assert not (snapshot/'runtime/backup-password').exists()
for name in ('synapse','control','media-config','certificates','caddy-config'):
 src,dst=snapshot/name,Path('/volumes')/name
 shutil.copytree(src,dst,dirs_exist_ok=True)
 for path in [src,*src.rglob('*')]:
  target=dst/path.relative_to(src);s=path.stat()
  os.chown(target,s.st_uid,s.st_gid);target.chmod(s.st_mode & 0o777)
 for path in src.rglob('*'):
  if path.is_file():assert hashlib.sha256(path.read_bytes()).digest()==hashlib.sha256((dst/path.relative_to(src)).read_bytes()).digest()
databases=list((snapshot/'control').rglob('*.sqlite'))
assert len(databases)>=3
for path in databases:
 with sqlite3.connect('file:'+str(path)+'?mode=ro',uri=True) as db:
  assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
with sqlite3.connect('file:'+str(snapshot/'control/calls/calls.sqlite')+'?mode=ro',uri=True) as db:
 assert db.execute("SELECT count(*) FROM screen_sessions WHERE state='active'").fetchone()[0]==1
key=hashlib.sha256((snapshot/'synapse/voicechat.signing.key').read_bytes()).hexdigest()
flag=Path('/volumes/control/screen-enabled');flag.write_text('0');os.chown(flag,10001,10001);flag.chmod(0o600)
print(json.dumps({'signing_key_sha256':key,'sqlite_databases':len(databases),'snapshot_active_screen':1}))
"""
                    checked = json.loads(subprocess.check_output(['docker', 'run', '--rm',
                        '-v', f'{restored}:/restore:ro', *mounts, python, 'python3', '-c', check], stderr=subprocess.DEVNULL))
                    compose(target, 'up', '-d', '--no-deps', '--wait', '--wait-timeout', '60', 'postgres')
                    read = subprocess.Popen(['docker', 'run', '--rm', '-v', f'{restored}:/restore:ro',
                        python, 'python3', '-c', "from pathlib import Path;import sys;sys.stdout.buffer.write(Path('/restore/snapshot/database/postgres.dump').read_bytes())"],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                    try:
                        compose(target, 'exec', '-T', 'postgres', 'pg_restore', '-U', 'synapse', '-d', 'synapse',
                                '--exit-on-error', '--single-transaction', stdin=read.stdout)
                    finally:
                        read.stdout.close()
                        assert read.wait() == 0
                    assert sql(target) == expected
                    compose(target, 'up', '-d', '--wait', '--wait-timeout', '180')
                    current = target
                    restored_state = state()
                    assert not restored_state['sessions'].get('active') and restored_state['pending_commands'] == 0
                    assert restored_state['retired_rooms'] == 0
                    digest = output(target, 'exec', '-T', 'synapse', 'python', '-c',
                        "from pathlib import Path;import hashlib;print(hashlib.sha256(Path('/data/voicechat.signing.key').read_bytes()).hexdigest())")
                    assert digest == checked['signing_key_sha256']
                    extra = {**checked, 'postgres_counts_match': True, 'file_trees_match_before_start': True,
                             'restic_checked': True, 'disjoint_source_and_restore_volumes': True,
                             'restored_feature_off': True, 'restored_leases_revoked': True,
                             'release_and_runtime_loaded_from_backup': True}
                elif action == 'screen_on':
                    flag(1)
                elif action == 'screen_off':
                    flag(0)
                elif action.startswith('audit '):
                    audit = json.loads(action[6:])
                    media_keys = [base64.b64decode(k, validate=True) for k in audit['keys']]
                    media_keys += [k.encode() for k in audit['keys']]
                    assert media_keys and all(media_keys)
                    snapshot = root/'restored/snapshot'
                    files = list((snapshot/'control').rglob('*.sqlite*'))
                    extra['audit_clean'] = all(not any(key in path.read_bytes() for key in media_keys) for path in files)
                    # A custom pg_dump may be compressed; inspect expanded SQL, not
                    # merely the compressed archive bytes.
                    sql_bytes = subprocess.check_output(['docker', 'run', '--rm',
                        '-v', f'{root}/restored:/restore:ro', config(target)['services']['postgres']['image'],
                        'pg_restore', '--file=-', '/restore/snapshot/database/postgres.dump'], stderr=subprocess.DEVNULL)
                    extra['audit_clean'] &= not any(key in sql_bytes for key in media_keys)
                    extra['audit_clean'] &= all(audit['jwt'].encode() not in path.read_bytes()
                                                for path in (snapshot/'control').rglob('*.sqlite*'))
                elif action.startswith('absent '):
                    generation = action[7:]
                    assert generation.startswith('screen-') and len(generation) < 200
                    control("import json,time,urllib.request,sys;sys.path.insert(0,'prototype');from token_server import jwt;"
                        "token=jwt({'iss':'prototype','exp':int(time.time())+30,'video':{'roomList':True}});"
                        "request=urllib.request.Request('http://127.0.0.1:7880/twirp/livekit.RoomService/ListRooms',"
                        "json.dumps({'names':["+repr(generation)+"]}).encode(),"
                        "{'Authorization':'Bearer '+token,'Content-Type':'application/json'});"
                        "assert not json.load(urllib.request.urlopen(request,timeout=3)).get('rooms')")
                elif action == 'close':
                    break
                elif action != 'status':
                    raise ValueError('Unknown restore action')
                print(json.dumps({**info, **state(), **extra}), flush=True)
        finally:
            # Names are unique to this invocation. Never down/prune shared projects.
            for env in (target, source):
                compose(env, 'down', '-v', '--remove-orphans')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'restore_error': type(error).__name__,
                          'frames': [(f.name, f.lineno) for f in traceback.extract_tb(error.__traceback__)]}), file=sys.stderr)
        raise SystemExit('Screen restore fixture failed: '+type(error).__name__) from None
