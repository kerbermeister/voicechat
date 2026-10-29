"""Deploy a prepared core with stopped-writer backup and durable code rollback.

Legacy adoption, incompatible storage upgrades and the multi-host orchestrator
are separate operations. A failed first initialization keeps its intent and data
for same-target retry; it never deletes volumes or adopts an unknown database.
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import stat
import shutil
import urllib.request

import deploy as legacy
import managed_state
import node_inventory
import role_deploy
import role_prepare
import role_bootstrap
import role_release
import topology

PHASES = ('prepared', 'stopping', 'backed-up', 'applying', 'rollback', 'managed-rollback')


def runtime_digest(root):
    descriptor = os.open(root / 'runtime/stand.env', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError('Core runtime environment must be an owned private regular file')
        content = source.read(65537)
    if not content or len(content) > 65536: raise ValueError('Invalid core runtime environment size')
    return hashlib.sha256(content).hexdigest()


def record_for(root, inventory, manifest):
    role_release.validate(manifest)
    if manifest['role'] != 'core': raise ValueError('Core manifest required')
    return {'manifest': manifest, 'address': inventory['core']['tunnel_ip'], 'runtime_sha256': runtime_digest(root)}


def validate_record(value):
    topology.fields(value, ('manifest', 'address', 'runtime_sha256'))
    manifest = role_release.validate(value['manifest'])
    node_inventory.ipv4(value['address'], tunnel=True)
    if manifest['role'] != 'core' or not isinstance(value['runtime_sha256'], str) or not role_release.SHA.fullmatch(value['runtime_sha256']):
        raise ValueError('Invalid core deployment record')
    return value


def read_state(root):
    path = root / 'state.json'
    if not path.exists() and not path.is_symlink():
        return {'schema': 1, 'current': None, 'previous': None, 'pending': None, 'data_identity': None}
    value = managed_state.read(path)
    topology.fields(value, ('schema', 'current', 'previous', 'pending', 'data_identity'))
    if type(value['schema']) is not int or value['schema'] != 1: raise ValueError('Unknown core deployment state')
    if value['data_identity'] is not None: validate_data_identity(value['data_identity'])
    if value['current'] is not None and value['data_identity'] is None:
        raise ValueError('Committed core has no recorded data identity')
    for name in ('current', 'previous'):
        if value[name] is not None: validate_record(value[name])
    if value['pending'] is not None:
        pending = value['pending']
        topology.fields(pending, ('target', 'phase'))
        validate_record(pending['target'])
        if pending['phase'] not in PHASES: raise ValueError('Unknown pending core phase')
    return value


def environment(record):
    return {**os.environ, 'CONTROL_IMAGE': record['manifest']['images']['control'],
            'COMPOSE_PROJECT_NAME': 'voicechat', 'COMPOSE_DISABLE_ENV_FILE': 'true'}


def compose(root, record, *arguments, execute=role_deploy.run):
    release = role_deploy.release_path(root, record)
    return execute(legacy.compose_command(release, *arguments, core=True), env=environment(record))


def configuration(root, record, *, execute=role_deploy.run):
    value = json.loads(compose(root, record, 'config', '--format', 'json', execute=execute))
    services = value['services']
    if set(services) != {'configure', 'postgres', 'synapse', 'control'}:
        raise ValueError('Unexpected core services')
    if any(services[name]['image'] != image for name, image in record['manifest']['images'].items()):
        raise ValueError('Core images differ from the verified manifest')
    if any(services[name].get('restart') != 'no' for name in ('postgres', 'synapse', 'control')):
        raise ValueError('Core startup must be ordered by its role boot gate')
    settings = services['configure']['environment']
    identity = record['manifest']['identity']
    if settings.get('PUBLIC_URL') != identity['canonical_origin'] or settings.get('MATRIX_SERVER_NAME') != identity['matrix_server_name']:
        raise ValueError('Persistent runtime cannot change the core identity')
    if any(value['volumes'][name]['name'] != 'voicechat_' + name for name in
           ('postgres', 'synapse', 'control', 'media-config', 'turn-config')):
        raise ValueError('Core volume namespace changed')
    return value


def validate_data_identity(value):
    topology.fields(value, ('postgres_system_identifier', 'signing_sha256'))
    if (not isinstance(value['postgres_system_identifier'], str) or
            not re.fullmatch(r'[1-9][0-9]{0,19}', value['postgres_system_identifier']) or
            not isinstance(value['signing_sha256'], str) or not role_release.SHA.fullmatch(value['signing_sha256'])):
        raise ValueError('Invalid core data identity')
    return value


def data_identity(root, record, *, execute=role_deploy.run):
    config = configuration(root, record, execute=execute)
    return volume_identity(record['manifest']['images'], config['volumes'],
                           record['manifest']['identity']['matrix_server_name'], execute=execute)


def volume_identity(images, volumes, server_name, *, execute=role_deploy.run):
    """Read existing data through pinned, isolated, read-only metadata probes."""
    topology.hostname(server_name)
    for name in ('postgres', 'configure'):
        if not isinstance(images[name], str) or not role_release.IMAGE.fullmatch(images[name]):
            raise ValueError('Immutable metadata probe image required')
    for volume in volumes.values():
        name = volume['name']
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', name):
            raise ValueError('Invalid metadata volume identity')
        if execute(['docker', 'volume', 'ls', '-q', '--filter', 'name=^' + name + '$']).strip() != name.encode():
            raise ValueError('A committed core volume is missing; restore it before starting')
    # Metadata probes must not join the application bridge or register service
    # aliases. They have read-only volumes and bypass database initialization.
    postgres = volumes['postgres']['name']
    synapse = volumes['synapse']['name']
    sandbox = ['docker', 'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL',
               '--security-opt', 'no-new-privileges:true', '--memory', '64m', '--pids-limit', '32']
    raw = execute([*sandbox, '--user', 'postgres', '--env', 'LC_ALL=C', '--mount',
        f'type=volume,source={postgres},target=/data,readonly,volume-nocopy', '--entrypoint',
        'pg_controldata', images['postgres'], '/data'])
    match = re.search(rb'^Database system identifier:\s+([1-9][0-9]{0,19})\s*$', raw, re.M)
    if match is None: raise ValueError('PostgreSQL cluster identity unavailable')
    script = """import hashlib, json
from pathlib import Path
with Path('/matrix/voicechat.signing.key').open('rb') as stream: key = stream.read(4097)
if not 0 < len(key) <= 4096: raise ValueError('Invalid Matrix signing key size')
with Path('/matrix/.voicechat-server-name').open() as stream: name = stream.read(254)
print(json.dumps({'server_name': name, 'sha256': hashlib.sha256(key).hexdigest()}))
"""
    value = json.loads(execute([*sandbox, '--user', '991:991', '--env', 'PYTHONDONTWRITEBYTECODE=1',
        '--mount', f'type=volume,source={synapse},target=/matrix,readonly,volume-nocopy',
        '--entrypoint', 'python3', images['configure'], '-c', script]))
    if value.get('server_name') != server_name:
        raise ValueError('Matrix data belongs to another server')
    return validate_data_identity({'postgres_system_identifier': match.group(1).decode(), 'signing_sha256': value['sha256']})


def migrate_push_routes(root, record, attempt, identity, *, reverse=False, execute=role_deploy.run, rollout_attempt=None):
    """URL-only maintenance before adoption or rollback, with verified backup upstream.

    Caller owns the full migration/legacy lock and verified stopped-writer backup.
    This also fences the core, checks the actual PostgreSQL and stopped writers,
    and keeps the database password on this host through private process stdin.
    """
    root = Path(root).absolute()
    if root.resolve() != root or not isinstance(attempt, str) or not role_release.SHA.fullmatch(attempt):
        raise ValueError('Canonical core root and unique migration attempt required')
    if type(reverse) is not bool: raise ValueError('Explicit migration direction required')
    validate_record(record); validate_data_identity(identity)
    with managed_state.locked(root):
        role_deploy.require_rollout_owner(root, rollout_attempt, record['manifest'])
        require_no_backup(root)
        if runtime_digest(root) != record['runtime_sha256']:
            raise ValueError('Core runtime changed before pusher migration')
        release = role_deploy.release_path(root, record)
        if 'infra/push_route_migration.py' not in record['manifest']['files']:
            raise ValueError('Verified core migration source required')
        config = configuration(root, record, execute=execute)
        for name in ('synapse', 'control'):
            identifiers = execute(['docker', 'ps', '-aq', '--no-trunc', '--filter',
                'label=com.docker.compose.project=voicechat', '--filter',
                'label=com.docker.compose.service=' + name]).decode().split()
            if len(identifiers) > 1 or any(not re.fullmatch(r'[a-f0-9]{64}', value) for value in identifiers):
                raise ValueError('Unknown core writer ownership')
            if identifiers and json.loads(execute(['docker', 'inspect', '--format', '{{json .State.Running}}', identifiers[0]])) is not False:
                raise ValueError('Stop all Synapse/control writers before pusher migration')
        identifiers = execute(['docker', 'ps', '-q', '--no-trunc', '--filter',
            'label=com.docker.compose.project=voicechat', '--filter',
            'label=com.docker.compose.service=postgres']).decode().split()
        if len(identifiers) != 1 or not re.fullmatch(r'[a-f0-9]{64}', identifiers[0]):
            raise ValueError('One running owned PostgreSQL required for pusher migration')
        template = ('{"id":{{json .Id}},"image":{{json .Config.Image}},"image_id":{{json .Image}},"labels":{{json .Config.Labels}},'
                    '"mounts":{{json .Mounts}},"state":{{json .State}},"networks":{{json .NetworkSettings.Networks}}}')
        postgres = json.loads(execute(['docker', 'inspect', '--format', template, identifiers[0]]))
        mount = [item for item in postgres['mounts'] if item.get('Destination') == '/var/lib/postgresql/data']
        image_id = execute(['docker', 'image', 'inspect', '--format', '{{.Id}}', record['manifest']['images']['postgres']]).decode().strip()
        if (postgres['id'] != identifiers[0] or postgres['image'] != record['manifest']['images']['postgres'] or
                postgres['image_id'] != image_id or not re.fullmatch(r'sha256:[a-f0-9]{64}', image_id) or
                postgres['labels'].get('com.docker.compose.project') != 'voicechat' or
                postgres['labels'].get('com.docker.compose.service') != 'postgres' or
                not postgres['state']['Running'] or postgres['state'].get('Health', {}).get('Status') != 'healthy' or
                set(postgres['networks']) != {'voicechat_default'} or len(mount) != 1 or
                mount[0].get('Type') != 'volume' or mount[0].get('RW') is not True or
                mount[0].get('Name') != config['volumes']['postgres']['name']):
            raise ValueError('PostgreSQL image, data mount or network ownership changed')
        if data_identity(root, record, execute=execute) != identity:
            raise ValueError('Core data identity changed before pusher migration')
        journal = root / 'runtime/adoption-push'
        role_prepare.directory(journal)
        journal /= attempt; role_prepare.directory(journal)
        journal /= 'reverse' if reverse else 'forward'; role_prepare.directory(journal)
        source = str(release / 'infra') + ':/operator:ro'
        sandbox = ['docker', 'run', '--rm', '--read-only', '--cap-drop', 'ALL',
                   '--security-opt', 'no-new-privileges:true', '--memory', '128m', '--pids-limit', '32',
                   '--env', 'PYTHONDONTWRITEBYTECODE=1']
        # The data-owner reader cannot traverse the root-private operator tree.
        # Keep it stdlib-only and return only this database credential.
        reader = """import json,os,stat,sys
def unique_object(pairs):
 value={}
 for key,item in pairs:
  if key in value:raise ValueError('Duplicate generated configuration field')
  value[key]=item
 return value
fd=os.open('/data/homeserver.yaml',os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
with os.fdopen(fd,'rb') as stream:
 info=os.fstat(stream.fileno());raw=stream.read(65537)
if not stat.S_ISREG(info.st_mode) or info.st_uid!=991 or info.st_mode&0o077 or len(raw)>65536:
 raise ValueError('Private generated Synapse configuration required')
value=json.loads(raw,object_pairs_hook=unique_object)
database=value.get('database',{});args=database.get('args',{})
if (value.get('server_name')!=sys.argv[1] or database.get('name')!='psycopg2' or
 set(args)-{'user','password','database','host','port','cp_min','cp_max'} or
 args.get('user')!='synapse' or args.get('database')!='synapse' or args.get('host')!='postgres' or args.get('port',5432)!=5432):
 raise ValueError('Only the owned local Synapse database may be migrated')
password=args.get('password')
if not isinstance(password,str) or not 1<=len(password)<=4096:raise ValueError('Invalid database credential')
print(json.dumps({'password':password}))
"""
        private = execute([*sandbox, '--network', 'none', '--user', '991:991',
            '--mount', 'type=volume,source=' + config['volumes']['synapse']['name'] + ',target=/data,readonly,volume-nocopy',
            '--entrypoint', 'python3', record['manifest']['images']['configure'], '-B', '-c',
            reader, record['manifest']['identity']['matrix_server_name']])
        driver = """import json,sys
from pathlib import Path
import psycopg2
from topology import fields,unique_object
from push_route_migration import migrate,restore_public
raw=sys.stdin.buffer.read(32769)
if len(raw)>32768:raise ValueError('Oversized database credential')
value=json.loads(raw,object_pairs_hook=unique_object);fields(value,('password',))
if not isinstance(value['password'],str) or not 1<=len(value['password'])<=4096:raise ValueError('Invalid database credential')
connection=psycopg2.connect(user='synapse',dbname='synapse',host='postgres',port=5432,
 password=value['password'],connect_timeout=5)
try:
 operation=restore_public if sys.argv[3]=='reverse' else migrate
 count=operation(connection,Path('/journal'),sys.argv[1],sys.argv[2])
finally:connection.close()
print(json.dumps({'updated':count}))
"""
        raw = execute([*sandbox, '--interactive', '--network', 'voicechat_default',
            '--user', str(os.geteuid()) + ':' + str(os.getegid()), '--volume', source,
            '--volume', str(journal) + ':/journal', '--entrypoint', 'python3', record['manifest']['images']['synapse'],
            '-B', '-c', "import sys;sys.path.insert(0,'/operator');" + driver,
            record['manifest']['identity']['canonical_origin'], record['address'], 'reverse' if reverse else 'forward'], input=private)
        result = json.loads(raw, object_pairs_hook=topology.unique_object)
        topology.fields(result, ('updated',))
        if type(result['updated']) is not int or result['updated'] < 0: raise ValueError('Invalid migration result')
        if data_identity(root, record, execute=execute) != identity:
            raise ValueError('Core data identity changed during pusher migration')
        return result['updated']


def healthy(root, record, *, execute=role_deploy.run):
    identifiers = compose(root, record, 'ps', '-q', 'postgres', 'synapse', 'control', execute=execute).decode().split()
    if len(identifiers) != 3: raise ValueError('Core services are missing')
    states = execute(['docker', 'inspect', '--format', '{{json .State}}', *identifiers])
    values = [json.loads(line) for line in states.splitlines()]
    if len(values) != 3 or any(value.get('Status') != 'running' or value.get('Health', {}).get('Status') != 'healthy' for value in values):
        raise ValueError('Core services are not healthy')
    # Do not use HTTP_PROXY or follow redirects when checking a private core.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    for port, path in ((8088, '/_matrix/client/versions'), (8090, '/health')):
        with opener.open(f'http://{record["address"]}:{port}{path}', timeout=5) as response:
            if response.status != 200 or len(response.read(65537)) > 65536:
                raise ValueError('Private core readiness failed')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs): return None


def policy_path(root, target):
    directory = root / 'runtime/core-deploy'
    role_prepare.directory(directory)
    directory /= role_release.json_digest(target['manifest'])
    role_prepare.directory(directory)
    return directory / 'client-policy.json'


def save_policy(root, old, target, *, execute):
    path = policy_path(root, target)
    if path.exists() or path.is_symlink():
        if not isinstance(managed_state.read(path), dict): raise ValueError('Invalid saved client policy')
        return
    raw = compose(root, old, 'run', '--rm', '--no-deps', '-T', '--entrypoint', 'cat',
                  'configure', '/media/client-policy.json', execute=execute)
    value = json.loads(raw)
    if len(raw) > 65536 or not isinstance(value, dict): raise ValueError('Invalid prior client policy')
    managed_state.persist(path, value)


def restore_policy(root, old, target, *, execute):
    value = managed_state.read(policy_path(root, target))
    if not isinstance(value, dict): raise ValueError('Invalid saved client policy')
    # The one-shot container reads the private snapshot directly; no shell,
    # credentials, or policy payload enter process arguments or public logs.
    source = str(policy_path(root, target))
    script = "from pathlib import Path; p=Path('/media/client-policy.json'); p.write_bytes(Path('/prior-policy.json').read_bytes()); p.chmod(0o600)"
    compose(root, old, 'run', '--rm', '--no-deps', '-T', '--volume', source + ':/prior-policy.json:ro',
            '--entrypoint', 'python3', 'configure', '-c', script, execute=execute)


def require_backup_idle(root, *, execute=role_deploy.run):
    """A lost SSH process may leave its Docker Restic child reading volumes.

    Never resume/configure writers while that repository is still mounted by
    a running container. Ignore other projects' repositories; do not kill a
    backup, delete its locks or manufacture a successful snapshot.
    """
    repository = Path(root) / 'backups/repository'
    if not repository.exists() and not repository.is_symlink(): return
    if repository.resolve() != repository or not repository.is_dir():
        raise ValueError('Canonical core backup repository required')
    identifiers = execute(['docker','ps','-q','--no-trunc']).decode().split()
    if not identifiers: return
    if len(identifiers) > 1024 or any(not re.fullmatch(r'[a-f0-9]{64}',item) for item in identifiers):
        raise ValueError('Unexpected backup container inspection response')
    rows = execute(['docker','inspect','--format','{{json .Mounts}}',*identifiers]).decode().splitlines()
    if len(rows) != len(identifiers): raise ValueError('Incomplete backup container inspection')
    for row in rows:
        mounts = json.loads(row)
        if not isinstance(mounts,list) or any(not isinstance(item,dict) for item in mounts):
            raise ValueError('Invalid backup container mounts')
        if any(item.get('Type') == 'bind' and item.get('Source') == str(repository) for item in mounts):
            raise ValueError('A backup container still uses this repository; wait and resume the owned operation')


def start_configured(root, record, *, execute=role_deploy.run):
    require_backup_idle(root, execute=execute)
    # up --wait alone races a fast successful one-shot. Check its exit code
    # explicitly before dependent writers are allowed to start.
    compose(root, record, 'up', '-d', '--no-deps', 'configure', execute=execute)
    compose(root, record, 'wait', 'configure', execute=execute)
    compose(root, record, 'up', '-d', '--wait', '--wait-timeout', '180', execute=execute)


def start_committed(root, record, *, execute=role_deploy.run):
    """Recover existing committed services without replaying configure."""
    require_backup_idle(root, execute=execute)
    compose(root, record, 'up', '-d', '--no-deps', '--wait', '--wait-timeout', '180', 'postgres', execute=execute)
    compose(root, record, 'up', '-d', '--no-deps', '--wait', '--wait-timeout', '180', 'synapse', 'control', execute=execute)


def backup(root, old):
    legacy.backup(root, role_deploy.release_path(root, old), environment(old), core=True)


def require_no_backup(root):
    path = root / 'runtime/backup.json'
    if path.exists() or path.is_symlink():
        raise ValueError('Resume the pending core backup before deployment or startup')


def backup_current(root, public, inventory, *, subnet='10.241.0.0/28', execute=role_deploy.run,
                   check_network=role_deploy.network_ready, check_health=healthy, create_backup=backup,
                   check_boot=role_bootstrap.ready, identify_data=data_identity,
                   activate_monitor=role_bootstrap.activate):
    """Back up the committed core with stopped writers and crash-resumable recovery.

    The deployment pointers and policy are unchanged. An interrupted attempt
    fences boot recovery until this operation resumes the same verified record.
    """
    root = Path(root).absolute()
    if root.resolve() != root: raise ValueError('Core root must not traverse symlinks')
    with role_bootstrap.monitor_after(root, 'core', activate=activate_monitor), managed_state.locked(root), check_network(inventory, 'core', subnet, execute=execute):
        role_deploy.require_rollout_owner(root)
        installation = root / 'runtime/backup-boot/pending.json'
        if installation.exists() or installation.is_symlink():
            raise ValueError('Finish the pending core backup timer installation')
        check_boot(root, 'core')
        state = read_state(root)
        record = state['current']
        if record is None or state['pending'] is not None:
            raise ValueError('A committed core without pending deployment is required for backup')
        if runtime_digest(root) != record['runtime_sha256']:
            raise ValueError('Core runtime changed since the committed release')
        release = role_deploy.release_path(root, record)
        role_release.verify_configuration(record['manifest'], public, inventory)
        configuration(root, record, execute=execute)
        if identify_data(root, record, execute=execute) != state['data_identity']:
            raise ValueError('Core data identity changed before backup')
        path = root / 'runtime/backup.json'
        identity = role_release.json_digest({'record': record, 'data_identity': state['data_identity']})
        if path.exists() or path.is_symlink():
            intent = managed_state.read(path)
            topology.fields(intent, ('schema', 'core_sha256', 'phase', 'succeeded'))
            if (type(intent['schema']) is not int or intent['schema'] != 1 or intent['core_sha256'] != identity or
                    intent['phase'] not in ('stopping', 'resuming') or
                    (intent['phase'] == 'stopping' and intent['succeeded'] is not None) or
                    (intent['phase'] == 'resuming' and type(intent['succeeded']) is not bool)):
                raise ValueError('Resume the same valid core backup intent')
        else:
            check_health(root, record, execute=execute)
            if shutil.disk_usage(root).free < 2 * 1024**3:
                raise ValueError('At least 2 GiB free space required before core backup')
            execute(['docker', 'pull', legacy.RESTIC])
            intent = {'schema': 1, 'core_sha256': identity, 'phase': 'stopping', 'succeeded': None}
            managed_state.persist(path, intent)

        def resume():
            if identify_data(root, record, execute=execute) != state['data_identity']:
                raise ValueError('Core data identity changed during backup')
            # Never run configure, another release or a restore to resume writers.
            require_backup_idle(root, execute=execute)
            compose(root, record, 'up', '-d', '--no-deps', '--no-build', '--pull', 'never',
                    '--wait', '--wait-timeout', '180', 'postgres', 'synapse', 'control', execute=execute)
            check_health(root, record, execute=execute)
            if identify_data(root, record, execute=execute) != state['data_identity']:
                raise ValueError('Core data identity changed after backup recovery')
            path.unlink()
            descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(descriptor)
            finally: os.close(descriptor)

        if intent['phase'] == 'stopping':
            try:
                compose(root, record, 'stop', 'synapse', 'control', execute=execute)
                create_backup(root, record)
            except Exception:
                intent.update(phase='resuming', succeeded=False)
                managed_state.persist(path, intent)
                resume()
                raise
            intent.update(phase='resuming', succeeded=True)
            managed_state.persist(path, intent)
        resume()
        if not intent['succeeded']:
            raise RuntimeError('Interrupted failed backup recovered; retry backup explicitly')
    return record


def deploy(root, public, inventory, manifest, *, subnet='10.241.0.0/28', execute=role_deploy.run,
           check_network=role_deploy.network_ready, check_health=healthy, create_backup=backup, check_boot=role_bootstrap.ready, identify_data=data_identity, activate_monitor=role_bootstrap.activate, rollout_attempt=None):
    root = Path(root).absolute()
    if root.resolve() != root: raise ValueError('Core root must not traverse symlinks')
    target = record_for(root, inventory, manifest)
    with role_bootstrap.monitor_after(root, 'core', activate=activate_monitor), managed_state.locked(root), check_network(inventory, 'core', subnet, execute=execute):
        role_deploy.require_rollout_owner(root, rollout_attempt, manifest)
        require_no_backup(root)
        check_boot(root, 'core')
        release = role_deploy.release_path(root, target)
        role_release.verify_bundle(release, manifest, public, inventory, subnet)
        if shutil.disk_usage(root).free < 2 * 1024**3:
            raise ValueError('At least 2 GiB free space required before core deployment')
        state = read_state(root)
        old, pending = state['current'], state['pending']
        if pending is not None and pending['phase'] == 'managed-rollback':
            raise ValueError('Resume the owned managed core rollback before deployment')
        if old:
            role_deploy.release_path(root, old)
            if any(old['manifest'][name] != manifest[name] for name in ('service_id', 'identity', 'contracts', 'node_sha256')) or any(old[name] != target[name] for name in ('address', 'runtime_sha256')):
                raise ValueError('Core identity, runtime secrets or host changed; explicit migration required')
            if any(old['manifest']['images'][name] != manifest['images'][name] for name in ('postgres', 'synapse')):
                raise ValueError('Database engine upgrade requires explicit compatibility and restore procedure')
        if state['data_identity'] is not None and identify_data(root, old or target, execute=execute) != state['data_identity']:
            raise ValueError('Core data identity changed; explicit recovery is required')
        configuration(root, target, execute=execute)
        if pending and pending['target'] != target: raise ValueError('Resume the same pending core release')
        if old is None and (pending is None or pending['phase'] != 'applying'):
            config = configuration(root, target, execute=execute)
            if compose(root, target, 'ps', '-a', '-q', execute=execute).strip():
                raise ValueError('Existing core containers require explicit adoption')
            if execute(['docker', 'network', 'ls', '-q', '--filter', 'name=^voicechat_default$']).strip():
                raise ValueError('Existing core network requires explicit adoption')
            for name in config['volumes'].values():
                if execute(['docker', 'volume', 'ls', '-q', '--filter', 'name=^' + name['name'] + '$']).strip():
                    raise ValueError('Existing core volumes require explicit adoption')
        if not pending:
            if old is not None:
                check_health(root, old, execute=execute)
                if old == target: return target
            state = {**state, 'pending': {'target': target, 'phase': 'prepared'}}
            managed_state.persist(root / 'state.json', state)
        def phase(value):
            nonlocal state
            state = {**state, 'pending': {'target': target, 'phase': value}}
            managed_state.persist(root / 'state.json', state)
        def stop(record):
            compose(root, record, 'stop', 'synapse', 'control', execute=execute)
        def up(record):
            start_configured(root, record, execute=execute)
        def verify_previous_identity():
            if identify_data(root, old, execute=execute) != state['data_identity']:
                raise ValueError('Rollback data identity changed; explicit recovery is required')
        def rollback():
            require_backup_idle(root, execute=execute)
            stop(target)
            restore_policy(root, old, target, execute=execute)
            up(old)
            check_health(root, old, execute=execute)
            verify_previous_identity()
            managed_state.persist(root / 'state.json', {**state, 'pending': None})
        if state['pending']['phase'] == 'rollback':
            if old is None: raise ValueError('Cannot roll back an uninitialized core')
            rollback()
            raise RuntimeError('Interrupted core rollback completed; retry the candidate explicitly')
        if state['pending']['phase'] == 'prepared':
            compose(root, target, 'pull', '--policy', 'missing', execute=execute)
            if old: execute(['docker', 'pull', legacy.RESTIC])
            # A new attempt must capture current operator settings, rather than
            # reuse a policy snapshot left by a previous completed rollback.
            if old:
                path = policy_path(root, target)
                if path.exists() or path.is_symlink():
                    managed_state.read(path)
                    path.unlink()
                    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
                    try: os.fsync(descriptor)
                    finally: os.close(descriptor)
            phase('stopping')
        try:
            if state['pending']['phase'] == 'stopping':
                if old:
                    stop(old)
                    save_policy(root, old, target, execute=execute)
                    create_backup(root, old)
                phase('backed-up')
            if state['pending']['phase'] == 'backed-up': phase('applying')
            up(target)
            check_health(root, target, execute=execute)
            identity = identify_data(root, target, execute=execute)
            if state['data_identity'] is not None and identity != state['data_identity']:
                raise ValueError('Deployment changed the core data identity')
        except Exception:
            if old:
                # Before a policy snapshot exists, configure has not run yet.
                if policy_path(root, target).exists():
                    phase('rollback')
                    rollback()
                else:
                    up(old)
                    check_health(root, old, execute=execute)
                    verify_previous_identity()
                    managed_state.persist(root / 'state.json', {**state, 'pending': None})
            # Initial failure keeps applying/stopping intent and all created data.
            raise
        managed_state.persist(root / 'state.json', {'schema': 1, 'current': target,
            'previous': old if old != target else state['previous'], 'pending': None, 'data_identity': identity})
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('root', 'topology', 'inventory'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--backup-only', action='store_true')
    parser.add_argument('--edge-subnet', default='10.241.0.0/28')
    args = parser.parse_args()
    if args.backup_only == bool(args.manifest):
        parser.error('Choose either --manifest or --backup-only')
    public = topology.load(args.topology)
    inventory = node_inventory.load(args.inventory, public)
    if args.backup_only:
        backup_current(args.root, public, inventory, subnet=args.edge_subnet)
        print('Core backup checked; committed writers and monitoring resumed.')
    else:
        deploy(args.root, public, inventory, role_release.load(args.manifest), subnet=args.edge_subnet)
        print('Core healthy; current/previous committed. Persistent data retained.')


if __name__ == '__main__': main()
