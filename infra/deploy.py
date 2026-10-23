"""Deploy immutable images with a consistent encrypted backup; preserve all volumes."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile
from client_config import client_config

RESTIC = 'restic/restic@sha256:9940e6c7421ab3a21ee9fdc4e91596d04c792b600d31b102696c75cbf3ac4481'


def manifest(path):
    value = json.loads(Path(path).read_text())
    if (not isinstance(value, dict) or set(value) != {'commit', 'schema', 'origin', 'control', 'web'} or
        type(value['schema']) is not int or value['schema'] != 1 or
        not all(isinstance(value[key], str) for key in ('commit', 'origin', 'control', 'web'))):
        raise ValueError('Unsupported release manifest/schema')
    if not re.fullmatch(r'[0-9a-f]{40}', value['commit']): raise ValueError('Invalid commit')
    if client_config(value['origin'])['MATRIX_URL'] != value['origin']: raise ValueError('Noncanonical origin')
    for key in ('control', 'web'):
        if not re.fullmatch(r'ghcr\.io/[a-z0-9._/-]+@sha256:[0-9a-f]{64}', value[key]):
            raise ValueError('Images must use immutable GHCR digests')
    return value


def execute(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def compose_command(release, *args):
    command = ['docker', 'compose', '--env-file', str(release/'infra/runtime/stand.env'),
               '-f', str(release/'infra/compose.yaml')]
    override = release/'infra/runtime/compose.override.yaml'
    if override.is_file(): command.extend(['-f', str(override)])
    return [*command, *args]


def compose(release, env, *args, **kwargs):
    return execute(compose_command(release, *args), env=env, **kwargs)


def backup(root, release, env):
    repository = root/'backups/repository'
    password = root/'runtime/backup-password'
    repository.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not password.exists():
        if repository.exists(): raise RuntimeError('Backup key is missing; refusing to replace it')
        descriptor = os.open(password, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, 'w') as output: output.write(secrets.token_urlsafe(48))
    command = ['docker', 'run', '--rm', '-e', 'RESTIC_PASSWORD_FILE=/password',
        '-v', f'{password}:/password:ro', '-v', f'{repository}:/repository', RESTIC, '-r', '/repository']
    if not repository.exists():
        repository.mkdir(mode=0o700)
        execute([*command, 'init'])
    # Writers stay stopped until this consistent database/media snapshot is complete.
    with tempfile.TemporaryDirectory(prefix='backup-', dir=root/'runtime') as temporary:
        directory = Path(temporary)
        override = root/'runtime/compose.override.yaml'
        if override.is_file(): shutil.copy2(override, directory/'compose.override.yaml')
        dump = directory/'postgres.dump'
        descriptor = os.open(dump, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, 'wb') as output:
            compose(release, env, 'exec', '-T', 'postgres', 'pg_dump', '-U', 'synapse',
                '-d', 'synapse', '--format=custom', stdout=output)
        execute(['docker', 'run', '--rm', '-e', 'RESTIC_PASSWORD_FILE=/password',
            '-v', f'{password}:/password:ro', '-v', f'{repository}:/repository',
            '-v', f'{root}/runtime/stand.env:/snapshot/runtime/stand.env:ro',
            '-v', f'{root}/current.json:/snapshot/current.json:ro',
            '-v', f'{release}:/snapshot/release:ro', '-v', f'{directory}:/snapshot/database:ro',
            '-v', 'voicechat_synapse:/snapshot/synapse:ro', '-v', 'voicechat_control:/snapshot/control:ro',
            '-v', 'voicechat_media-config:/snapshot/media-config:ro',
            '-v', 'voicechat_certificates:/snapshot/certificates:ro',
            '-v', 'voicechat_caddy-config:/snapshot/caddy-config:ro',
            RESTIC, '-r', '/repository', 'backup', '/snapshot', '--tag', 'voicechat'])
    execute([*command, 'check'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--release')
    parser.add_argument('--backup-only', action='store_true',
                        help='Back up the current release with writers stopped, then resume it')
    args = parser.parse_args()
    if args.backup_only == bool(args.release):
        parser.error('Choose either --release or --backup-only')
    root = Path(args.root).resolve()
    # Select current under the same lock as deploy; otherwise a scheduled backup
    # could restart a stale release after a concurrent deployment finishes.
    with (root/'deploy.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        current = root/'current.json'
        old = json.loads(current.read_text()) if current.exists() else None
        if args.backup_only:
            if not old: raise SystemExit('No current release to back up')
            release = Path(old['release']).resolve()
        else:
            release = Path(args.release).resolve()
        deploy(root, release, old, args.backup_only)


def deploy(root, release, old, backup_only=False):
    if not release.is_relative_to(root/'releases'): raise SystemExit('Release must be inside root/releases')
    target = manifest(release/'release.json')
    runtime = root/'runtime'
    if not (runtime/'stand.env').is_file(): raise SystemExit('Bootstrap the persistent runtime/stand.env first')
    runtime.chmod(0o700)
    (runtime/'stand.env').chmod(0o600)
    link = release/'infra/runtime'
    if not link.exists(): link.symlink_to(runtime, target_is_directory=True)
    if link.resolve() != runtime: raise SystemExit('Release runtime must reference the shared runtime directory')
    env = {**os.environ, 'CONTROL_IMAGE': target['control'], 'WEB_IMAGE': target['web']}
    # Validate the configured public origin without printing the interpolated secrets.
    config = subprocess.check_output(compose_command(release, 'config', '--format', 'json'), env=env)
    configured = json.loads(config)['services']['configure']['environment']['PUBLIC_URL']
    if configured != target['origin']: raise SystemExit('Release origin differs from persistent server identity')
    previous = root/'current.json'
    if old and old['manifest']['schema'] != target['schema']:
        raise SystemExit('Schema migration needs a separate maintenance procedure')
    if backup_only and target != old['manifest']:
        raise SystemExit('Current release manifest was modified')
    if shutil.disk_usage(root).free < 2 * 1024**3:
        raise SystemExit('At least 2 GiB free space required before deployment')
    if not backup_only: compose(release, env, 'pull')
    execute(['docker', 'pull', RESTIC])
    running = subprocess.check_output(compose_command(release, 'ps', '-q', 'postgres'), env=env).strip()
    if old and not running: raise SystemExit('Existing database is not running; recover it before updating')
    if running and not old: raise SystemExit('Existing data has no current manifest; record the verified release before automated updates')
    if old:
        prior_release = Path(old['release'])
        prior_env = {**os.environ, 'CONTROL_IMAGE': old['manifest']['control'],
                     'WEB_IMAGE': old['manifest']['web']}
    try:
        if running:
            compose(prior_release, prior_env, 'stop', 'web', 'synapse', 'control', 'turn')
            backup(root, prior_release, prior_env)
        compose(release, env, 'up', '-d', '--wait', '--wait-timeout', '180')
    except Exception:
        if old:
            compose(prior_release, prior_env, 'up', '-d', '--wait', '--wait-timeout', '180')
        raise
    if backup_only:
        print('Backup checked; current release resumed. Copy the encrypted repository off the VPS.')
        return
    record = {'release': str(release), 'manifest': target}
    if old: (root/'previous.json').write_text(json.dumps(old))
    pending = root/'current.pending'
    pending.write_text(json.dumps(record))
    pending.replace(previous)
    print('Deployment healthy; persistent data retained. Back up the Restic password outside the VPS.')


if __name__ == '__main__': main()
