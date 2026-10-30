"""One-time legacy to core/cohost migration; never restore a database on rollback.

The ordinary role deployers remain separate. This controller requires one data
host with its canonical edge and the already adopted legacy-certs ingress.
"""
import argparse
from contextlib import ExitStack
import hashlib
import fcntl
import json
import os
from pathlib import Path
import platform
import secrets
import shutil
import stat
import tempfile
import time

import cohost_tls
import cohost_tls_bootstrap
import core_backup_bootstrap
import core_deploy
import deploy as legacy
import edge_deploy
import legacy_backup
import legacy_core
import managed_state
import network_bootstrap
import network_runtime
import node_inventory
import publish_catalog
import release_delivery
import role_boot
import role_bootstrap
import role_deploy
import role_prepare
import role_release
import route_catalog
import shared_cutover
import shared_front
import shared_ingress as ingress
import shared_update
import tls_runtime
import tls_material
import topology
import tunnel_config
from tunnel_runtime import command

PHASES = ('preparing', 'fencing', 'stopping', 'backup', 'push', 'legacy-down', 'network',
          'core', 'edge', 'public', 'finish', 'activate', 'scheduling', 'complete',
          'rollback-stop', 'rollback-data', 'rollback-remove', 'rollback-network',
          'rollback-legacy', 'rollback-finish', 'rolled-back')


def source_files(directory):
    result = {}
    for folder in ('infra', 'prototype'):
        paths = ((directory / folder).iterdir() if folder == 'infra' else
                 (directory / folder / name for name in
                  ('client-policy.json', 'voicechat_policy.py', 'client_policy.py', 'scheduled_messages.py')))
        for path in sorted(paths):
            if path.name in ('runtime', '__pycache__'): continue
            raw = network_bootstrap.existing(path)
            if raw is None or len(raw) > 1024 * 1024: raise ValueError('Invalid frozen migration source')
            result[str(path.relative_to(directory))] = role_release.digest(raw)
    if not 1 <= len(result) <= 256: raise ValueError('Bounded migration source set required')
    return result


def target_for(root, legacy_root, shared_root, public, inventory, candidate, catalog_key, *, subnet, backend_sha256):
    topology.validate(public); node_inventory.validate(inventory, public)
    if not isinstance(backend_sha256, str) or not role_release.SHA.fullmatch(backend_sha256):
        raise ValueError('Build-generated backend fingerprint required')
    topology.fields(candidate, ('schema', 'commit', 'origin', 'control', 'web'))
    if type(candidate['schema']) is not int or candidate['schema'] != 1:
        raise ValueError('Known immutable candidate manifest required')
    if (set(tunnel_config.physical_nodes(inventory)) != {'core'} or len(inventory['edges']) != 1 or
            len(public['edges']) != 1 or inventory['edges'][0].get('host') != 'core' or
            public['edges'][0]['origin'] != public['canonical_origin'] or
            not inventory['edges'][0].get('legacy_turn')):
        raise ValueError('Initial adoption requires one cohost edge with legacy TURN compatibility')
    edge_id = public['edges'][0]['id']
    if node_inventory.shared_tls_profile(inventory, edge_id) is None:
        raise ValueError('Explicit shared TLS profile required for initial adoption')
    if candidate['origin'] != public['canonical_origin']: raise ValueError('Candidate belongs to another origin')
    roots = [Path(value).absolute() for value in (root, legacy_root, shared_root)]
    if (len(set(roots)) != 3 or any(path.resolve() != path for path in roots) or
            any(left in right.parents for left in roots for right in roots if left != right)):
        raise ValueError('Distinct canonical nonnested migration roots required')
    for path in roots: ingress.absolute_path(str(path))
    core = role_release.make(public, inventory, 'core', candidate['commit'], candidate['control'])
    edge = role_release.make(public, inventory, 'edge', candidate['commit'], candidate['web'], edge_id, subnet)
    role_release.require_compatible(core, edge)
    return {'schema': 1, 'root': str(roots[0]), 'legacy_root': str(roots[1]), 'shared_root': str(roots[2]),
            'public': public, 'inventory': inventory, 'core': core, 'edge': edge,
            'catalog_key': catalog_key, 'subnet': subnet, 'backend_sha256': backend_sha256,
            'source_files': source_files(Path(__file__).resolve().parents[1])}




def initial_network(root, inventory, subnet):
    if set(tunnel_config.physical_nodes(inventory)) != {'core'}:
        raise ValueError('Initial adoption may generate only this data host key')
    public_key = tunnel_config.ensure_key(root / 'network.key')
    registry = {'schema':1, 'service_id':inventory['service_id'], 'nodes':{
        'core':{'generation':inventory['core']['generation'], 'public_key':public_key}}}
    intent = {'schema':1,'inventory':inventory,'public_keys':registry,'node':'core',
              'private_key':tunnel_config.read_private(root / 'network.key'),'edge_subnet':subnet}
    network_runtime.components(intent)
    return intent


def existing_network(network, inventory, subnet, previous, *, execute):
    path = network / 'desired.json'
    if not path.exists() and not path.is_symlink(): return None
    saved = managed_state.read(path)
    network_runtime.components(saved)
    if saved['inventory'] != inventory or saved['node'] != 'core' or saved['edge_subnet'] != subnet:
        raise ValueError('Existing network needs its own explicit migration before adoption')
    if previous is not None and not previous['network_preexisting']:
        if network_runtime.fingerprint(saved) != previous['network_fingerprint']:
            raise ValueError('Retained initial network differs from the completed rollback')
    else:
        # An existing installation must already be healthy. Only our completed
        # rollback may leave the same peerless network intentionally retired.
        with role_deploy.network_ready(inventory, 'core', subnet, execute=execute, directory=network):
            pass
    return saved


marker = role_deploy.rollout_marker


def legacy_guard(legacy_root, managed_root, target, *, publish=False):
    """Retire the legacy controller only after the public role commit.

    Old release metadata remains intact for audit/recovery. The existing legacy
    controller rejects this marker before creating runtime paths or using Docker.
    """
    path = legacy_root / 'role-deployment.json'
    expected = {'schema': 1, 'kind': 'roles', 'root': str(managed_root),
                'initial_target': role_release.json_digest(target)}
    if path.exists() or path.is_symlink():
        if managed_state.read(path) != expected:
            raise ValueError('Foreign legacy retirement marker must be preserved')
    elif publish:
        managed_state.persist(path, expected)
    return expected


def private_file(path, raw):
    if not raw or len(raw) > 65536: raise ValueError('Bounded private migration input required')
    old = network_bootstrap.existing(path)
    if old is not None:
        if old != raw or path.stat().st_mode & 0o077: raise ValueError('Staged private input differs from its owner')
        return
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        output.write(raw); output.flush(); os.fsync(output.fileno())
    tls_material.sync_directory(path.parent)


def private_environment(root, expected):
    if core_deploy.runtime_digest(root) != expected: raise ValueError('Legacy runtime changed during migration')
    raw = network_bootstrap.existing(root / 'runtime/stand.env')
    if raw is None or role_release.digest(raw) != expected: raise ValueError('Legacy runtime changed during capture')
    return raw



def public_source(path):
    info = path.lstat()
    if (path.resolve() != path or not stat.S_ISDIR(info.st_mode) or
            info.st_uid != os.geteuid() or info.st_mode & 0o022):
        raise ValueError('Owned public artifact source directory required')


def copy_public(source, destination):
    """Only existing public update artifacts; never copy working data to an edge."""
    public_source(source)
    if destination.resolve() != destination: raise ValueError('Canonical artifact destination required')
    role_prepare.directory(destination, public=True)
    for item in sorted(source.rglob('*')):
        info = item.lstat()
        if info.st_uid != os.geteuid() or info.st_mode & 0o022 or item.is_symlink():
            raise ValueError('Unknown public artifact must not be copied')
        path = destination / item.relative_to(source)
        if stat.S_ISDIR(info.st_mode): role_prepare.directory(path, public=True); continue
        if not stat.S_ISREG(info.st_mode): raise ValueError('Only public regular artifacts may be copied')
        if item.name == '.publish.lock': continue
        def digest(file):
            with file.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()
        if path.exists() or path.is_symlink():
            existing = path.lstat()
            if (path.is_symlink() or not stat.S_ISREG(existing.st_mode) or existing.st_uid != os.geteuid() or
                    existing.st_mode & 0o022 or digest(path) != digest(item)):
                raise ValueError('Existing edge artifact differs from its legacy source')
            continue
        if shutil.disk_usage(path.parent).free < info.st_size + 2 * 1024**3:
            raise ValueError('Public artifact copy must retain 2 GiB free for working data')
        descriptor, temporary = tempfile.mkstemp(prefix='.full-copy-', dir=path.parent)
        try:
            with os.fdopen(descriptor, 'wb') as output, item.open('rb') as original:
                shutil.copyfileobj(original, output); output.flush(); os.fsync(output.fileno())
                os.fchmod(output.fileno(), stat.S_IMODE(info.st_mode))
            os.link(temporary, path)
            tls_material.sync_directory(path.parent)
        finally: Path(temporary).unlink(missing_ok=True)


def policy(baseline, snapshot, *, restore, execute):
    volume = 'voicechat_media-config'
    script = ("import json,sys;from pathlib import Path; raw=sys.stdin.buffer.read(65537);"
              "assert len(raw)<=65536 and isinstance(json.loads(raw),dict);"
              "p=Path('/media/client-policy.json');p.write_bytes(raw);p.chmod(0o600)") if restore else (
              "import json;from pathlib import Path; p=Path('/media/client-policy.json');"
              "raw=p.read_bytes();assert len(raw)<=65536;value=json.loads(raw);"
              "assert isinstance(value,dict);print(json.dumps(value))")
    args = ['docker', 'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL',
            '--security-opt', 'no-new-privileges:true', '--mount',
            'type=volume,source=' + volume + ',target=/media,volume-nocopy' + ('' if restore else ',readonly')]
    args += ['--user', '10001:10001']
    if restore: args += ['--interactive']
    args += ['--entrypoint', 'python3', baseline['images']['configure'], '-B', '-c', script]
    if restore:
        value = managed_state.read(snapshot)
        if not isinstance(value, dict): raise ValueError('Invalid saved legacy policy')
        execute(args, input=json.dumps(value).encode())
    elif snapshot.exists():
        if not isinstance(managed_state.read(snapshot), dict): raise ValueError('Invalid saved legacy policy')
    else: managed_state.persist(snapshot, json.loads(execute(args)))


def configuration_files(arguments):
    return tuple(Path(arguments[index + 1]).resolve() for index, value in enumerate(arguments) if value == '-f')



def legacy_models(root, baseline, previous_attempt=None, *, execute):
    arguments = legacy.compose_command(Path(baseline['record']['release']))
    configurations = [arguments]
    if previous_attempt is not None:
        if not isinstance(previous_attempt,str) or not role_release.SHA.fullmatch(previous_attempt):
            raise ValueError('Exact previous rollback owner required')
        recovery = root / ('attempt-' + previous_attempt) / 'legacy-recovery.json'
        if (not recovery.exists() or recovery.resolve() != recovery or
                recovery.parent.stat().st_uid != os.geteuid() or recovery.parent.stat().st_mode & 0o077 or
                managed_state.read(recovery) != legacy_core.rollback_override(baseline)):
            raise ValueError('Owned legacy recovery override is missing or changed')
        # Compose can retain these labels even after normal up reuses the same
        # container. Accept only our exact prior volume override, never arbitrary -f.
        configurations.append([*arguments,'-f',str(recovery)])
    return [(configuration_files(args),json.loads(execute([*args,'config','--format','json'],
             env=legacy_core.environment(baseline['record'])))) for args in configurations]


def namespace(project, models, *, execute, baseline=None):
    identifiers = execute(['docker', 'ps', '-aq', '--no-trunc', '--filter',
                           'label=com.docker.compose.project=' + project]).decode().split()
    found = {}
    for identifier in identifiers:
        if not role_release.SHA.fullmatch(identifier): raise ValueError('Unknown container identity')
        value = json.loads(execute(['docker', 'inspect', '--format', legacy_core.CONTAINER_TEMPLATE, identifier]))
        name = value['labels'].get('com.docker.compose.service')
        files = tuple(Path(part).resolve() for part in value['labels'].get('com.docker.compose.project.config_files', '').split(',') if part)
        candidates = [model for expected, model in models if expected == files and name in model['services']]
        captured = False
        if not candidates and baseline is not None and project == 'voicechat' and baseline['containers'].get(name) == identifier:
            # Compose keeps original config-files labels when it reuses a
            # container across releases. Only a captured, fully verified legacy
            # ID may use the current baseline model instead of that stale hint.
            expected_files = configuration_files(legacy.compose_command(Path(baseline['record']['release'])))
            candidates = [model for expected, model in models if expected == expected_files and
                          {key:value['image'] for key,value in model['services'].items()} == baseline['images']]
            captured = True
        if len(candidates) != 1 or name in found: raise ValueError('Unknown or duplicate migration container')
        model = candidates[0]; service = model['services'][name]
        if not isinstance(service['image'], str) or not role_release.IMAGE.fullmatch(service['image']):
            raise ValueError('Immutable migration image required')
        image = json.loads(execute(['docker', 'image', 'inspect', '--format',
            '{"id":{{json .Id}},"volumes":{{json (index .Config "Volumes")}}}', service['image']]))
        if value['id'] != identifier or value['image_id'] != image['id']:
            raise ValueError('Migration container binary changed')
        declared = {item['target'] for item in service.get('volumes', [])}
        temporary = {item.split(':', 1)[0] for item in service.get('tmpfs', [])}
        implicit = set(image['volumes'] or {}) - declared - temporary
        if implicit and (name != 'turn' or implicit != {'/var/lib/coturn'}):
            raise ValueError('Unknown migration image volume must be preserved')
        legacy_core._container(service, value, model, running=False, implicit=implicit,
                               restart_policy='fencing', project=project, allow_created=not captured)
        found[name] = value
    return found


def remove_namespace(project, models, *, execute, baseline=None):
    current = namespace(project, models, execute=execute, baseline=baseline)
    identifiers = [value['id'] for value in current.values()]
    if identifiers:
        execute(['docker', 'stop', *identifiers])
        execute(['docker', 'rm', *identifiers])  # Never -v: keep every data object.
    return current




def check_scheduler_slots(system_root, *, run):
    # Initial retries happen before any new timer is installed. Once scheduling
    # starts the public migration is committed and resumes its own later phase.
    for name in (cohost_tls_bootstrap.SERVICE, cohost_tls_bootstrap.TIMER,
                 core_backup_bootstrap.SERVICE, core_backup_bootstrap.TIMER):
        path = system_root / 'etc/systemd/system' / name
        if (path.exists() or path.is_symlink() or path.with_name(name + '.d').exists() or
                run('systemctl','show',name,'--property=LoadState','--value').strip() != 'not-found'):
            raise ValueError('Existing scheduler needs its own explicit adoption before initial migration')


def check_role_boot(root, role, edge_id, *, system_root):
    """Reject occupied boot slots before stopping any legacy writer."""
    name, code, contents, unit, target = role_bootstrap.plan(root, role, edge_id)
    destination = system_root / 'etc/systemd/system' / name
    if destination.with_name(name + '.d').exists():
        raise ValueError('Unknown role boot drop-in must be preserved')
    current_path, pending_path = root/'runtime/boot/current.json', root/'runtime/boot/pending.json'
    current = managed_state.read(current_path) if current_path.exists() or current_path.is_symlink() else None
    if current is not None:
        if role_bootstrap.verify_record(system_root,current) != name or current['root'] != str(root):
            raise ValueError('Boot service belongs to another installation')
    pending = managed_state.read(pending_path) if pending_path.exists() or pending_path.is_symlink() else None
    if pending is not None:
        topology.fields(pending, ('target','previous'))
        if pending['target'] != target or (pending['previous'] != current and current != target):
            raise ValueError('Resume the same pending boot installation first')
    installed = network_bootstrap.existing(destination)
    allowed = {None}
    if current is not None: allowed.add(current['unit_sha256'])
    if pending is not None: allowed.add(role_release.digest(unit))
    if installed is not None and role_release.digest(installed) not in allowed:
        raise ValueError('Unclaimed or modified role boot unit must be preserved')
    role_bootstrap.check_sources(system_root,code,contents)


def disable_role(root, role, edge_id, *, system_root, run):
    name = role_bootstrap.unit_name(role, edge_id)
    if (system_root / 'etc/systemd/system' / (name + '.d')).exists():
        raise ValueError('Unknown role boot drop-in must be preserved')
    receipt_path = root / 'runtime/boot/current.json'
    if not receipt_path.exists() and not receipt_path.is_symlink():
        pending = root / 'runtime/boot/pending.json'
        name, _, _, expected_unit, expected = role_bootstrap.plan(root, role, edge_id)
        destination = system_root / 'etc/systemd/system' / name
        installed = network_bootstrap.existing(destination)
        if pending.exists() or pending.is_symlink():
            if managed_state.read(pending) != {'target':expected,'previous':None}:
                raise ValueError('Foreign pending boot installation must be preserved')
            if installed not in (None, expected_unit):
                raise ValueError('Modified pending boot unit must be preserved')
            if installed is not None: run('systemctl', 'disable', '--now', name)
        elif installed is not None or destination.with_name(name + '.d').exists():
            raise ValueError('Unclaimed boot unit must be preserved')
        return
    receipt = managed_state.read(receipt_path)
    name = role_bootstrap.verify_record(system_root, receipt)
    if receipt['root'] != str(root) or receipt['role'] != role or receipt['edge_id'] != edge_id:
        raise ValueError('Foreign role boot unit must be preserved')
    path = system_root / 'etc/systemd/system' / name
    if role_release.digest(network_bootstrap.existing(path) or b'') != receipt['unit_sha256']:
        raise ValueError('Modified role boot unit must be preserved')
    run('systemctl', 'disable', '--now', name)


def cancel_preparation(root, attempt, *, execute=role_deploy.run, system_root=Path('/')):
    """Archive only an unstarted, empty adoption attempt; never change services.

    This permits a corrected artifact after a pre-maintenance guard failure.
    Anything prepared/fenced requires recovery by its original coordinator.
    """
    root, system_root = Path(root).absolute(), Path(system_root).resolve()
    if root.resolve()!=root or not isinstance(attempt,str) or not role_release.SHA.fullmatch(attempt):
        raise ValueError('Canonical root and exact initial attempt required')
    with managed_state.locked(root):
        path=root/'initial.json';folder=root/('attempt-'+attempt)
        archived=folder/'cancelled-preparation.json'
        if folder.resolve()!=folder or not folder.is_dir() or folder.stat().st_uid!=os.geteuid() or folder.stat().st_mode&0o077:
            raise ValueError('Owned empty preparation directory required')
        pending=path.exists() or path.is_symlink()
        value=managed_state.read(path if pending else archived)
        topology.fields(value,('schema','target','attempt','phase','baseline','source_root',
            'network_preexisting','network_fingerprint','shared_plan','front_plan','previous_roles'))
        if (type(value['schema']) is not int or value['schema']!=1 or value['attempt']!=attempt or
                value['phase']!='preparing' or value['network_preexisting'] is not False or
                any(value[key] is not None for key in ('network_fingerprint','shared_plan','front_plan','previous_roles'))):
            raise ValueError('Only a fresh unstarted preparation may be cancelled')
        if {p.name for p in folder.iterdir()} != (set() if pending else {'cancelled-preparation.json'}):
            raise ValueError('Preparation has effects; resume the original coordinator')
        for item in (root/'current.json',root/'core',root/'edges',root/'network.key',system_root/'var/lib/voicechat-network'):
            if item.exists() or item.is_symlink():raise ValueError('Prepared roles/network must be recovered, never cancelled')
        target=value['target'];old=Path(target['legacy_root']);shared=Path(target['shared_root'])
        if target['root']!=str(root) or old.resolve()!=old or shared.resolve()!=shared or len({root,old,shared})!=3:
            raise ValueError('Initial cancellation roots changed')
        source=Path(value['source_root'])
        if source.resolve()!=source or source.parent!=root/'bundles' or not role_release.SHA.fullmatch(source.name):
            raise ValueError('Original immutable source delivery required')
        record=managed_state.read(source/'delivery.json')
        if record['archive_sha256']!=source.name or record['backend']!=target['backend_sha256']:
            raise ValueError('Original source receipt changed')
        release_delivery.verify(source,record)
        if source_files(source)!=target['source_files']:raise ValueError('Original migration source changed')
        with legacy_core.locked(old),managed_state.locked(shared):
            if legacy_core._inspect_locked(old,execute=execute)!=value['baseline']:
                raise ValueError('Legacy state changed; explicit recovery required')
            pointer=managed_state.read(shared/'current.json')
            # Cancellation verifies the recorded historical operator; it must not
            # require installing today's operator before abandoning preparation.
            serving,_=ingress.read_plan(shared,shared/'plans'/pointer['plan'],system_root=system_root,current_sources=False)
            if (serving['mode']!='legacy-certs' or serving['edge_root']!=str(root/'edges'/target['edge']['edge_id']) or
                    serving['public']!=target['public'] or serving['node']!=target['inventory']['core']):
                raise ValueError('Public ingress changed; cancellation is unsafe')
            if pending:
                os.rename(path,archived)
                tls_material.sync_directory(folder);tls_material.sync_directory(root)
        return {'schema':1,'cancelled':'unstarted-preparation','attempt':attempt,'source':str(source)}


def migrate(root, legacy_root, shared_root, public, inventory, candidate, envelope, catalog_key, *,
            backend_sha256, subnet='10.241.0.0/28', retry=False, execute=role_deploy.run, run=command,
            system_root=Path('/'), ca_file=None):
    target = target_for(root, legacy_root, shared_root, public, inventory, candidate, catalog_key, subnet=subnet, backend_sha256=backend_sha256)
    verified = route_catalog.verify(envelope, catalog_key, public)
    if verified.topology != public: raise ValueError('Publish exactly the prepared public topology')
    root, old_root, shared = (Path(target[key]) for key in ('root', 'legacy_root', 'shared_root'))
    system_root = Path(system_root).resolve()
    edge_id = target['edge']['edge_id']
    core, edge = root / 'core', root / 'edges' / edge_id
    network = system_root / 'var/lib/voicechat-network'
    host = system_root / 'etc/ssh/ssh_host_ed25519_key.pub'
    actual_key = ' '.join(ingress.read_environment(host).decode().split()[:2])
    if node_inventory.host_key(actual_key) != inventory['core']['ssh_host_key']:
        raise ValueError('This SSH host does not match the migration inventory')
    local_sockets = ('unix:///var/run/docker.sock', 'unix:///run/docker.sock')
    if os.environ.get('DOCKER_HOST') not in (None, '', *local_sockets):
        raise ValueError('Initial migration requires the local rootful Docker daemon')
    endpoint = execute(['docker','context','inspect','--format','{{(index .Endpoints "docker").Host}}']).decode().strip()
    if endpoint not in local_sockets: raise ValueError('Initial migration requires the local rootful Docker daemon')
    with managed_state.locked(root), legacy_core.locked(old_root), ExitStack() as publications:
        for name in ('android-updates','macos-updates'):
            directory = old_root / 'runtime' / name
            if not directory.exists(): role_prepare.directory(directory, public=True)
            public_source(directory)
            descriptor = os.open(directory / '.publish.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
            lock = publications.enter_context(os.fdopen(descriptor, 'r+b'))
            info = os.fstat(lock.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
                raise ValueError('Unknown public update lock')
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = root / 'initial.json'
        journal = managed_state.read(path) if path.exists() or path.is_symlink() else None
        previous = None
        retirement = old_root / 'role-deployment.json'
        if journal is None and (retirement.exists() or retirement.is_symlink()):
            raise ValueError('Retired legacy installation requires its original migration journal')
        legacy_guard(old_root, root, target)
        if journal is not None:
            topology.fields(journal, ('schema', 'target', 'attempt', 'phase', 'baseline', 'source_root',
                                     'network_preexisting', 'network_fingerprint', 'shared_plan', 'front_plan', 'previous_roles'))
            if type(journal['schema']) is not int or journal['schema'] != 1 or journal['phase'] not in PHASES:
                raise ValueError('Invalid initial migration journal')
            if not isinstance(journal['attempt'], str) or not role_release.SHA.fullmatch(journal['attempt']):
                raise ValueError('Invalid initial migration owner')
            if type(journal['network_preexisting']) is not bool:
                raise ValueError('Explicit original network ownership required')
            for key in ('network_fingerprint','shared_plan','front_plan'):
                if journal[key] is not None and (not isinstance(journal[key],str) or not role_release.SHA.fullmatch(journal[key])):
                    raise ValueError('Invalid initial migration pointer')
            if journal['phase'] == 'rolled-back' and retry:
                previous, journal = journal, None
            elif journal['target'] != target:
                raise ValueError('Resume the same frozen migration artifact, or explicitly retry a completed rollback')
            elif journal['phase'] == 'complete':
                current = managed_state.read(root / 'current.json')
                if current['target'] != target: raise ValueError('Use the normal role rollout for an updated installation')
                legacy_guard(old_root, root, target, publish=True)
                return current
            elif journal['phase'] == 'rolled-back':
                raise ValueError('Initial migration rolled back; retry explicitly with a fresh attempt')
        if journal is None:
            if (root / 'current.json').exists() or (root / 'current.json').is_symlink():
                raise ValueError('Managed installation exists; use the normal role rollout')
            baseline = legacy_core._inspect_locked(old_root, execute=execute)
            legacy_core.require_compatible(baseline, target['core'])
            saved = existing_network(network, inventory, subnet, previous, execute=execute)
            journal = {'schema': 1, 'target': target, 'attempt': secrets.token_hex(32), 'phase': 'preparing',
                       'baseline': baseline, 'source_root': str(Path(__file__).resolve().parents[1]),
                       'network_preexisting': previous['network_preexisting'] if previous else saved is not None,
                       'network_fingerprint': network_runtime.fingerprint(saved) if saved else None,
                       'shared_plan': None, 'front_plan': None,
                       'previous_roles': {key:previous['target'][key] for key in ('core','edge')} if previous else None}
            if previous: journal['previous_roles']['attempt'] = previous['attempt']
            managed_state.persist(path, journal)
        baseline, attempt = journal['baseline'], journal['attempt']
        release = Path(baseline['record']['release'])
        if (baseline['root'] != str(old_root) or release.resolve() != release or release.parent != old_root / 'releases' or
                legacy_core._json(old_root / 'current.json') != baseline['record'] or
                legacy.manifest(release / 'release.json') != baseline['record']['manifest'] or
                core_deploy.runtime_digest(old_root) != baseline['runtime_sha256'] or
                legacy_core._sources(old_root,release) != baseline['source_sha256']):
            raise ValueError('Frozen legacy baseline changed; explicit recovery required')
        core_deploy.validate_data_identity(baseline['data_identity'])
        legacy_core.require_compatible(baseline,target['core'])
        attempt_root = root / ('attempt-' + attempt)
        role_prepare.directory(attempt_root)
        policy_snapshot = attempt_root / 'client-policy.json'
        recovery = attempt_root / 'legacy-recovery.json'

        def phase(value):
            nonlocal journal
            journal = {**journal, 'phase': value}
            managed_state.persist(path, journal)

        def old_compose(*args):
            return execute(legacy.compose_command(Path(baseline['record']['release']), *args),
                           env=legacy_core.environment(baseline['record']))

        old_models = legacy_models(root,baseline,journal['previous_roles']['attempt'] if journal['previous_roles'] else None,
                                   execute=execute)
        if journal['phase'] == 'preparing':
            namespace('voicechat',old_models,execute=execute,baseline=baseline)
            # Source-only manager upgrade owns its lock; no writer has stopped.
            shared_update.install(shared, execute=execute, system_root=system_root)
        with managed_state.locked(shared):
            serving = managed_state.read(shared / 'current.json')
            serving_target, _ = ingress.read_plan(shared, shared / 'plans' / serving['plan'], system_root=system_root)
            if (serving_target['edge_root'] != str(edge) or serving_target['public'] != public or
                    serving_target['node'] != inventory['core'] or serving_target['edge_id'] != edge_id):
                raise ValueError('Migration differs from the existing cohost installation')
            if journal['phase'] == 'preparing':
                if serving_target['mode'] != 'legacy-certs': raise ValueError('Prepare the legacy certificate sinks first')
                if legacy_core._inspect_locked(old_root, execute=execute) != baseline:
                    raise ValueError('Legacy baseline changed before preparing adoption')
                check_scheduler_slots(system_root,run=run)
                role_prepare.directory(root / 'edges')
                role_prepare.prepare(core, public, inventory, target['core'])
                role_prepare.prepare(edge, public, inventory, target['edge'], subnet)
                core_state = core_deploy.read_state(core)
                edge_state = edge_deploy.read_state(edge,edge_id)
                if (core_state['current'] is not None or core_state['pending'] is not None or
                        core_state['previous'] is not None or core_state['data_identity'] not in (None,baseline['data_identity'])):
                    raise ValueError('Existing core state needs an explicit managed migration')
                expected_old_edge = journal['previous_roles']['edge'] if journal['previous_roles'] else None
                if edge_state['pending'] is not None or (edge_state['current'] is not None and
                        edge_state['current']['manifest'] != expected_old_edge):
                    raise ValueError('Existing edge state needs its own rollout or adoption')
                if execute(['docker','ps','-aq','--filter','label=com.docker.compose.project=voicechat-edge-'+edge_id]).strip():
                    raise ValueError('Existing edge containers need an explicit adoption before initial migration')
                for directory, role, identifier in ((core,'core',None),(edge,'edge',edge_id)):
                    check_role_boot(directory,role,identifier,system_root=system_root)
                private_file(core / 'runtime/stand.env', private_environment(old_root, baseline['runtime_sha256']))
                core_record = core_deploy.record_for(core, inventory, target['core'])
                configuration = core_deploy.configuration(core, core_record, execute=execute)
                secret = configuration['services']['configure']['environment']['TURN_SECRET']
                if not isinstance(secret, str) or not 32 <= len(secret) <= 4096 or '\n' in secret:
                    raise ValueError('Bounded TURN secret required')
                private_file(edge / 'runtime/turn-secret', secret.encode())
                for directory, manifest in ((core, target['core']), (edge, target['edge'])):
                    expected_marker = marker(directory, manifest, attempt)
                    with managed_state.locked(directory):
                        existing = role_deploy.pending_rollout(directory)
                        previous_roles = journal['previous_roles']
                        prior = marker(directory, previous_roles[manifest['role']], previous_roles['attempt']) if previous_roles else None
                        if existing not in (None, prior, expected_marker): raise ValueError('Another full rollout owns the role')
                        managed_state.persist(directory / 'runtime/full-rollout.json', expected_marker)
                for name in ('android-updates', 'macos-updates'):
                    copy_public(old_root / 'runtime' / name, edge / 'runtime' / name)
                captured = cohost_tls._capture_locked(shared, execute=execute, system_root=system_root, ca_file=ca_file)
                with managed_state.locked(edge):
                    for service in ('web', 'turn'):
                        material = shared / 'certificates' / captured['generations'][service]
                        tls_runtime.publish(edge / 'runtime/tls', public, edge_id, service,
                            material / (service + '.crt'), material / (service + '.key'), ca_file=ca_file)
                catalog = edge / 'runtime/catalog'
                publish_catalog.publish(catalog, envelope, catalog_key, public,
                                        initialize=not (catalog / 'routes.json').exists())
                business = execute(['git', '--no-pager', '-C', serving_target['repo'], 'show',
                                    serving['baseline']['head'] + ':deploy/Caddyfile']).decode()
                shared_target = {**serving_target, 'mode': 'shared',
                                 'shared_tls': node_inventory.shared_tls_profile(inventory, edge_id)}
                plan = ingress._store_plan_locked(shared, shared_target, ingress.configuration(business, shared_target),
                                                  system_root=system_root)
                front = shared_front.prepare(shared / 'front', edge, target['edge'])
                with managed_state.locked(shared / 'front'):
                    shared_front._preflight_locked(shared / 'front',front,execute=execute,system_root=system_root)
                journal = {**journal, 'shared_plan': plan.name, 'front_plan': front.name}
                core_deploy.compose(core, core_record, 'pull', '--policy', 'missing', execute=execute)
                edge_deploy.compose(edge, edge_deploy.record_for(public, inventory, target['edge']),
                                    'pull', '--policy', 'missing', execute=execute)
                execute(['docker', 'pull', legacy.RESTIC])
                if shutil.disk_usage(root).free < 2 * 1024**3: raise ValueError('At least 2 GiB free space required')
                phase('fencing')

            core_record = core_deploy.record_for(core, inventory, target['core'])
            edge_record = edge_deploy.record_for(public, inventory, target['edge'])
            plan, front = shared / 'plans' / journal['shared_plan'], shared / 'front/plans' / journal['front_plan']
            public_committed = serving['plan'] == journal['shared_plan'] and serving_target['mode'] == 'shared'
            if public_committed and journal['phase'] not in ('finish','activate','scheduling','complete'):
                phase('finish')
            for directory, manifest in ((core,target['core']), (edge,target['edge'])):
                if journal['phase'] not in ('activate','scheduling','complete') or role_deploy.pending_rollout(directory) is not None:
                    role_deploy.require_rollout_owner(directory, attempt, manifest)

            def models():
                values = list(old_models)
                release = role_deploy.release_path(core, core_record)
                values.append(((release / 'infra/compose.core.json',), core_deploy.configuration(core, core_record, execute=execute)))
                edge_release = role_deploy.release_path(edge, edge_record)
                edge_values = [((edge_release / 'infra/compose.edge.json',), json.loads(
                    edge_deploy.compose(edge, edge_record, 'config', '--format', 'json', execute=execute)))]
                return values, edge_values

            def pg_ready():
                core_models, _ = models()
                current = namespace('voicechat', core_models, execute=execute, baseline=baseline)
                if 'postgres' not in current:
                    if core_deploy.data_identity(core, core_record, execute=execute) != baseline['data_identity']:
                        raise ValueError('Refusing to initialize missing adoption data')
                    exists = execute(['docker','network','ls','-q','--filter','name=^voicechat_default$']).strip()
                    legacy_bridge = False
                    if exists:
                        info = json.loads(execute(['docker','network','inspect','--format',
                            '{"labels":{{json .Labels}},"options":{{json .Options}}}', 'voicechat_default']))
                        if info['labels'].get('com.docker.compose.project') != 'voicechat':
                            raise ValueError('Foreign PostgreSQL bridge must be preserved')
                        name = (info['options'] or {}).get('com.docker.network.bridge.name')
                        old_name = core_models[0][1]['networks']['default'].get('driver_opts', {}).get('com.docker.network.bridge.name')
                        new_name = node_inventory.core_bridge(inventory)
                        if name not in (old_name,new_name): raise ValueError('Unknown data bridge must be preserved')
                        legacy_bridge = name == old_name
                    if legacy_bridge: old_compose('up','-d','--no-deps','--wait','--wait-timeout','180','postgres')
                    else: core_deploy.compose(core, core_record, 'up', '-d', '--no-deps', '--wait',
                                              '--wait-timeout', '180', 'postgres', execute=execute)
                else: execute(['docker', 'start', current['postgres']['id']])
                deadline = time.monotonic() + 60
                while True:
                    current = namespace('voicechat', core_models, execute=execute, baseline=baseline)
                    if current.get('postgres', {}).get('state', {}).get('Health', {}).get('Status') == 'healthy': break
                    if time.monotonic() >= deadline: raise TimeoutError('Owned PostgreSQL did not recover')
                    time.sleep(.5)

            def rollback():
                core_deploy.require_backup_idle(old_root, execute=execute)
                if journal['phase'] == 'rollback-stop':
                    disable_role(core, 'core', None, system_root=system_root, run=run)
                    disable_role(edge, 'edge', edge_id, system_root=system_root, run=run)
                    core_models, _ = models()
                    current = namespace('voicechat', core_models, execute=execute, baseline=baseline)
                    writers = [item['id'] for name, item in current.items() if name != 'postgres']
                    if writers: execute(['docker', 'stop', *writers])
                    pg_ready(); phase('rollback-data')
                if journal['phase'] == 'rollback-data':
                    core_deploy.migrate_push_routes(core, core_record, attempt, baseline['data_identity'],
                                                    reverse=True, execute=execute, rollout_attempt=attempt)
                    if policy_snapshot.exists(): policy(baseline, policy_snapshot, restore=True, execute=execute)
                    phase('rollback-remove')
                if journal['phase'] == 'rollback-remove':
                    core_models, edge_models = models()
                    remove_namespace('voicechat-edge-' + edge_id, edge_models, execute=execute)
                    remove_namespace('voicechat', core_models, execute=execute, baseline=baseline)
                    if execute(['docker', 'network', 'ls', '-q', '--filter', 'name=^voicechat_default$']).strip():
                        owner = json.loads(execute(['docker','network','inspect','--format','{{json .Labels}}','voicechat_default']))
                        if owner.get('com.docker.compose.project') != 'voicechat': raise ValueError('Foreign data bridge must be preserved')
                        execute(['docker','network','rm','voicechat_default'])
                    with managed_state.locked(core):
                        state = core_deploy.read_state(core)
                        for value in (state['current'], state['pending']['target'] if state['pending'] else None):
                            if value not in (None, core_record): raise ValueError('Unexpected core deployment during rollback')
                        managed_state.persist(core / 'state.json', {'schema':1,'current':None,'previous':None,
                            'pending':None,'data_identity':baseline['data_identity']})
                    phase('rollback-network')
                if journal['phase'] == 'rollback-network':
                    saved = network / 'desired.json'
                    if saved.exists() and not journal['network_preexisting']:
                        intent = managed_state.read(saved)
                        network_bootstrap.retire_initial(system_root, network_runtime.fingerprint(intent), run=run)
                    if journal['network_preexisting']:
                        intent = managed_state.read(saved)
                        if network_runtime.fingerprint(intent) != journal['network_fingerprint']:
                            raise ValueError('Original network changed during adoption rollback')
                        network_runtime.reconcile(network, intent, run=run)
                        network_bootstrap.install(system_root, run=run, shared_host=True)
                    phase('rollback-legacy')
                if journal['phase'] == 'rollback-legacy':
                    managed_state.persist(recovery, legacy_core.rollback_override(baseline))
                    arguments = legacy.compose_command(Path(baseline['record']['release']))
                    execute([*arguments, '-f', str(recovery), 'up', '-d', '--pull', 'never', '--wait', '--wait-timeout','180'],
                            env=legacy_core.environment(baseline['record']))
                    old_compose('up', '-d', '--pull','never','--wait','--wait-timeout','180')
                    phase('rollback-finish')
                if journal['phase'] == 'rollback-finish':
                    restored = legacy_core._inspect_locked(old_root, execute=execute)
                    for key in ('record','runtime_sha256','source_sha256','data_identity','implicit_volumes'):
                        if restored[key] != baseline[key]: raise ValueError('Legacy rollback identity changed')
                    legacy_backup.restore(attempt_root / 'backup', old_root, system_root=system_root, run=run)
                    phase('rolled-back')

            if journal['phase'].startswith('rollback-'):
                rollback()
                raise RuntimeError('Interrupted initial rollback completed; retry explicitly')
            if journal['phase'] == 'fencing':
                legacy_backup.retire(attempt_root / 'backup', old_root, system_root=system_root, run=run)
                legacy_core._fence_restart_locked(old_root, baseline, execute=execute)
                phase('stopping')
            try:
                if journal['phase'] == 'stopping':
                    old_compose('stop','web','synapse','control','turn')
                    pg_ready()
                    policy(baseline, policy_snapshot, restore=False, execute=execute)
                    phase('backup')
                if journal['phase'] == 'backup':
                    legacy.backup(old_root, Path(baseline['record']['release']), legacy_core.environment(baseline['record']))
                    phase('push')
                if journal['phase'] == 'push':
                    core_deploy.migrate_push_routes(core, core_record, attempt, baseline['data_identity'],
                                                    execute=execute, rollout_attempt=attempt)
                    phase('legacy-down')
                if journal['phase'] == 'legacy-down':
                    core_models, _ = models()
                    namespace('voicechat', core_models, execute=execute, baseline=baseline)
                    old_compose('down')  # All named and anonymous data volumes remain.
                    phase('network')
                if journal['phase'] == 'network':
                    if not (network / 'desired.json').exists():
                        network_bootstrap.directory(system_root, 'var/lib/voicechat-network', create=True)
                        network.chmod(0o700)
                        intent = initial_network(root, inventory, subnet)
                        network_runtime.reconcile(network, intent, run=run)
                    intent = managed_state.read(network / 'desired.json')
                    if intent['inventory'] != inventory or intent['node'] != 'core' or intent['edge_subnet'] != subnet:
                        raise ValueError('Network intent changed during initial adoption')
                    fingerprint = network_runtime.fingerprint(intent)
                    journal = {**journal, 'network_fingerprint': fingerprint}; managed_state.persist(path,journal)
                    retired = network / 'boot-install/initial-rollback.json'
                    if not retired.exists(): network_runtime.reconcile(network, intent, run=run)
                    network_bootstrap.install(system_root, run=run, shared_host=True,
                                              restore_initial=fingerprint if retired.exists() else None)
                    for directory, manifest in ((core,target['core']),(edge,target['edge'])):
                        role_bootstrap.install(directory,manifest['role'],manifest['edge_id'],system_root=system_root,run=run)
                    phase('core')
                if journal['phase'] == 'core':
                    with managed_state.locked(core):
                        state = core_deploy.read_state(core)
                        if state['current'] is None:
                            if state['pending'] not in (None, {'target':core_record,'phase':'applying'}):
                                raise ValueError('Another core initialization is pending')
                            if core_deploy.data_identity(core,core_record,execute=execute)!=baseline['data_identity']:
                                raise ValueError('Legacy data identity changed before adoption')
                            managed_state.persist(core/'state.json',{'schema':1,'current':None,'previous':None,
                                'pending':{'target':core_record,'phase':'applying'},'data_identity':baseline['data_identity']})
                        elif state['current'] != core_record: raise ValueError('Unexpected committed core during adoption')
                    if state['current'] is not None and state['pending'] is None:
                        role_boot.start(core,'core',execute=execute,network_directory=network,rollout_attempt=attempt)
                    core_deploy.deploy(core,public,inventory,target['core'],execute=execute,rollout_attempt=attempt)
                    phase('edge')
                if journal['phase'] == 'edge':
                    shared_front.warm(shared/'front',front,execute=execute,system_root=system_root)
                    warm_port=managed_state.read(front/'plan.json')['warm_port']
                    def warm_health(directory, record, **kwargs):
                        return edge_deploy.healthy(directory,record,warm_port=warm_port,**kwargs)
                    edge_deploy.deploy(edge,public,inventory,target['edge'],target['core'],subnet=subnet,
                        execute=execute,check_health=warm_health,rollout_attempt=attempt)
                    cohost_tls._refresh_locked(shared,execute=execute,system_root=system_root,
                                               ca_file=ca_file,rollout_attempt=attempt)
                    phase('public')
                if journal['phase'] == 'public':
                    shared_cutover._activate_locked(shared,plan,front,execute=execute,system_root=system_root)
                    phase('finish')
            except Exception:
                if managed_state.read(shared/'current.json')['plan']==journal['shared_plan']:
                    phase('finish')  # Public commit is forward-only.
                else:
                    phase('rollback-stop'); rollback()
                raise
            if journal['phase'] == 'finish':
                legacy_guard(old_root, root, target, publish=True)
                for directory, role, identifier in ((core,'core',None),(edge,'edge',edge_id)):
                    role_boot.start(directory,role,identifier,execute=execute,network_directory=network,rollout_attempt=attempt)
                cohost_tls._refresh_locked(shared,execute=execute,system_root=system_root,
                                           ca_file=ca_file,rollout_attempt=attempt)
                publish_catalog.publish(edge/'runtime/catalog',envelope,catalog_key,public)
                edge_deploy.healthy(edge,edge_record,execute=execute)
                current = {'schema':1,'kind':'roles','target':target,'core_root':str(core),'edge_root':str(edge),
                           'data_identity':baseline['data_identity'],'legacy_root':str(old_root)}
                managed_state.persist(root/'current.json',current)
                phase('activate')
            if journal['phase'] == 'activate':
                for directory, manifest in ((core,target['core']),(edge,target['edge'])):
                    with managed_state.locked(directory):
                        value=role_deploy.pending_rollout(directory)
                        if value is not None:
                            if value!=marker(directory,manifest,attempt):raise ValueError('Foreign full fence must be preserved')
                            (directory/'runtime/full-rollout.json').unlink()
                            tls_material.sync_directory(directory/'runtime')
                    role_bootstrap.activate(directory,manifest['role'],manifest['edge_id'])
                phase('scheduling')
            if journal['phase'] == 'scheduling':
                cohost_tls_bootstrap._install_locked(shared,execute=execute,run=run,system_root=system_root)
                core_backup_bootstrap.install(core,public,inventory,subnet=subnet,system_root=system_root,run=run)
                phase('complete')
            return managed_state.read(root/'current.json')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('root','legacy-root','shared-root','topology','inventory','candidate','catalog','catalog-key-file'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--backend-file', type=Path, default=Path(__file__).resolve().parents[1] / 'backend.sha256')
    parser.add_argument('--edge-subnet', default='10.241.0.0/28')
    parser.add_argument('--retry',action='store_true')
    parser.add_argument('--ca-file',type=Path,help='Explicit trusted CA for an isolated fixture')
    args=parser.parse_args()
    if platform.system()!='Linux' or os.geteuid()!=0:raise SystemExit('Initial migration requires the selected Linux host as root')
    for tool in ('docker','openssl','wg','wg-quick','nft','ip','systemctl'):
        if shutil.which(tool) is None:raise SystemExit('Provision the required host tool first: '+tool)
    public=topology.load(args.topology)
    migrate(args.root,args.legacy_root,args.shared_root,public,node_inventory.load(args.inventory,public),
        legacy.manifest(args.candidate),route_catalog.read_envelope(args.catalog),
        args.catalog_key_file.read_text().strip(),backend_sha256=args.backend_file.read_text().strip(),
        retry=args.retry,ca_file=args.ca_file,subnet=args.edge_subnet)
    print('Initial core/cohost migration committed; user data stayed on this host.')


if __name__=='__main__':main()
