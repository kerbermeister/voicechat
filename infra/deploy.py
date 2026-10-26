"""Deploy immutable images with a consistent encrypted backup; preserve all volumes."""
import argparse
import fcntl
import hashlib
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
    config = json.loads(subprocess.check_output(
        compose_command(release, 'config', '--format', 'json'), env=env))
    # Resolve actual names, including an isolated Compose project or external volumes.
    volumes = config['volumes']
    mounts = [item for name in ('synapse', 'control', 'media-config', 'certificates', 'caddy-config')
              for item in ('-v', f"{volumes[name]['name']}:/snapshot/{name}:ro")]
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
            *mounts,
            RESTIC, '-r', '/repository', 'backup', '/snapshot', '--tag', 'voicechat'])
    execute([*command, 'check'])


def backend_config(configuration, release):
    value = {**configuration, 'services': {name: service for name, service in
             configuration['services'].items() if name != 'web'}}
    # Compose resolves bind mounts under each immutable release directory.
    normalized = json.dumps(value, sort_keys=True).replace(str(release), '$RELEASE')
    return hashlib.sha256(normalized.encode()).hexdigest()


def release_record(release, target, configuration):
    record = {'release': str(release), 'manifest': target}
    fingerprint = release/'backend.sha256'
    if fingerprint.exists():
        value = fingerprint.read_text().strip()
        if not re.fullmatch(r'[0-9a-f]{64}', value):
            raise ValueError('Invalid backend source fingerprint')
        record.update(backend=value, backend_config=backend_config(configuration, release))
    return record


def require_backend_healthy(release, env):
    services = ('postgres', 'synapse', 'control', 'turn')
    identifiers = subprocess.check_output(
        compose_command(release, 'ps', '-a', '-q', *services), env=env).decode().split()
    if len(identifiers) != len(services):
        raise RuntimeError('Backend services are missing; refusing web-only deployment')
    output = subprocess.check_output(
        ['docker', 'inspect', '--format', '{{json .State}}', *identifiers], env=env)
    states = [json.loads(line) for line in output.splitlines()]
    if len(states) != len(services) or any(
            state.get('Status') != 'running' or
            state.get('Health', {}).get('Status', 'healthy') != 'healthy' for state in states):
        raise RuntimeError('Backend services are not healthy; refusing web-only deployment')


def web_deploy(root, release, old, target, env, configuration):
    record = release_record(release, target, configuration)
    if (not old or not record.get('backend') or
            configuration['services'].get('web', {}).get('image') != target['web'] or
            any(old.get(key) != record.get(key) for key in ('backend', 'backend_config')) or
            any(old['manifest'][key] != target[key] for key in ('schema', 'origin', 'control'))):
        raise SystemExit('Backend/configuration changed or baseline missing; use a full deployment')
    prior_release = Path(old['release'])
    prior_env = {**os.environ, 'CONTROL_IMAGE': old['manifest']['control'],
                 'WEB_IMAGE': old['manifest']['web']}
    require_backend_healthy(prior_release, prior_env)
    compose(release, env, 'pull', 'web')
    try:
        compose(release, env, 'up', '-d', '--no-deps', '--wait', '--wait-timeout', '180', 'web')
        require_backend_healthy(prior_release, prior_env)
    except Exception:
        compose(prior_release, prior_env, 'up', '-d', '--no-deps', '--wait', '--wait-timeout', '180', 'web')
        raise
    (root/'previous.json').write_text(json.dumps(old))
    pending = root/'current.pending'
    pending.write_text(json.dumps(record))
    pending.replace(root/'current.json')
    print('Web deployment healthy; backend containers and persistent data unchanged.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--release')
    parser.add_argument('--backup-only', action='store_true',
                        help='Back up the current release with writers stopped, then resume it')
    parser.add_argument('--web-only', action='store_true', help='Update only web after verifying the backend baseline')
    args = parser.parse_args()
    if args.web_only and args.backup_only:
        parser.error('--web-only cannot be combined with --backup-only')
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
        deploy(root, release, old, args.backup_only, args.web_only)


def deploy(root, release, old, backup_only=False, web_only=False):
    if not release.is_relative_to(root/'releases'): raise SystemExit('Release must be inside root/releases')
    target = manifest(release/'release.json')
    runtime = root/'runtime'
    (runtime/'android-updates').mkdir(mode=0o755, parents=True, exist_ok=True)
    (runtime/'macos-updates').mkdir(mode=0o755, parents=True, exist_ok=True)
    if not (runtime/'stand.env').is_file(): raise SystemExit('Bootstrap the persistent runtime/stand.env first')
    runtime.chmod(0o700)
    (runtime/'stand.env').chmod(0o600)
    link = release/'infra/runtime'
    if not link.exists(): link.symlink_to(runtime, target_is_directory=True)
    if link.resolve() != runtime: raise SystemExit('Release runtime must reference the shared runtime directory')
    env = {**os.environ, 'CONTROL_IMAGE': target['control'], 'WEB_IMAGE': target['web']}
    # Validate the configured public origin without printing the interpolated secrets.
    config = subprocess.check_output(compose_command(release, 'config', '--format', 'json'), env=env)
    configuration = json.loads(config)
    configured = configuration['services']['configure']['environment']['PUBLIC_URL']
    if configured != target['origin']: raise SystemExit('Release origin differs from persistent server identity')
    record = release_record(release, target, configuration)
    previous = root/'current.json'
    if old and old['manifest']['schema'] != target['schema']:
        raise SystemExit('Schema migration needs a separate maintenance procedure')
    if backup_only and target != old['manifest']:
        raise SystemExit('Current release manifest was modified')
    if shutil.disk_usage(root).free < 2 * 1024**3:
        raise SystemExit('At least 2 GiB free space required before deployment')
    if web_only:
        web_deploy(root, release, old, target, env, configuration)
        return
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
    if old: (root/'previous.json').write_text(json.dumps(old))
    pending = root/'current.pending'
    pending.write_text(json.dumps(record))
    pending.replace(previous)
    print('Deployment healthy; persistent data retained. Back up the Restic password outside the VPS.')


if __name__ == '__main__': main()
