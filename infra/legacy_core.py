"""Inspect the existing single-host baseline before explicit core adoption.

Read-only: use the existing legacy deploy lock, inspect exact immutable images,
mounts and network/port ownership, then read persistent database/signing identity.
Never return interpolated runtime credentials or accept an unknown release pointer.
"""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import stat

import core_deploy
import deploy as legacy
import network_bootstrap
import role_deploy
import role_release
import topology

SERVICES = ('configure', 'postgres', 'synapse', 'control', 'turn', 'web')
VOLUMES = ('postgres', 'synapse', 'control', 'media-config', 'turn-config', 'certificates', 'caddy-config')


def _json(path):
    raw = network_bootstrap.existing(path)
    if raw is None or len(raw) > 65536: raise ValueError('Missing or oversized legacy metadata')
    return json.loads(raw, object_pairs_hook=topology.unique_object)


@contextmanager
def locked(root):
    root = Path(root).absolute()
    if root.resolve() != root: raise ValueError('Canonical legacy root required')
    for path in (root, root / 'runtime'):
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError('Legacy root and runtime must be owned private directories')
    descriptor = os.open(root / 'deploy.lock', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor) as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ValueError('Legacy deploy lock must be an owned non-writable-by-others file')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield root


def environment(record):
    return {**os.environ, 'CONTROL_IMAGE': record['manifest']['control'], 'WEB_IMAGE': record['manifest']['web'],
            'COMPOSE_PROJECT_NAME': 'voicechat', 'COMPOSE_DISABLE_ENV_FILE': 'true'}


def _port_range(value):
    if type(value) is int: value = str(value)
    if not isinstance(value, str) or not re.fullmatch(r'[1-9][0-9]{0,4}(?:-[1-9][0-9]{0,4})?', value):
        raise ValueError('Invalid legacy port declaration')
    bounds = [int(part) for part in value.split('-')]
    first, last = bounds[0], bounds[-1]
    if not 1 <= first <= last <= 65535 or last - first > 255:
        raise ValueError('Unsupported legacy port range')
    return range(first, last + 1)


def _ports(service, actual):
    expected = set()
    for item in service.get('ports', []):
        target, published = _port_range(item['target']), _port_range(item['published'])
        if len(target) != len(published): raise ValueError('Ambiguous legacy port range')
        for inside, outside in zip(target, published):
            expected.add((str(inside) + '/' + item.get('protocol', 'tcp'), str(outside), item.get('host_ip') or '*'))
    found = set()
    for port, bindings in (actual or {}).items():
        for binding in bindings or []:
            address = binding['HostIp'] or '0.0.0.0'
            if address in ('0.0.0.0', '::') and (port, binding['HostPort'], '*') in expected: address = '*'
            found.add((port, binding['HostPort'], address))
    if found != expected: raise ValueError('Legacy container port bindings differ from its baseline')


def _container(service, current, model, *, running, implicit=(), restart_policy='legacy'):
    if (current['image'] != service['image'] or current['labels'].get('com.docker.compose.project') != 'voicechat' or
            current['readonly'] != service.get('read_only', False)):
        raise ValueError('Legacy container image, project or filesystem contract changed')
    restart = service.get('restart', 'no')
    allowed = {'no'} if restart_policy == 'fenced' else {restart, 'no'} if restart_policy == 'fencing' else {restart}
    if (current['restart']['Name'] or 'no') not in allowed or current['restart']['MaximumRetryCount'] != 0:
        raise ValueError('Legacy container restart contract changed')
    for name in ('cap_add', 'cap_drop'):
        normalize = lambda values: {value.removeprefix('CAP_') for value in (values or [])}
        if normalize(current[name]) != normalize(service.get(name)):
            raise ValueError('Legacy container capabilities changed')
    if set(current['security_opt'] or []) != set(service.get('security_opt', [])):
        raise ValueError('Legacy container security options changed')
    state = current['state']
    if running and (not state['Running'] or ('healthcheck' in service and state.get('Health', {}).get('Status') != 'healthy')):
        raise ValueError('Existing legacy services must be running and healthy')
    if not running and state['Status'] not in ('running', 'exited'):
        raise ValueError('Unknown legacy container lifecycle state')
    networks = {model['networks'][key]['name'] for key in service.get('networks', {'default': {}})}
    if set(current['networks']) != networks and (state['Running'] or current['networks']):
        raise ValueError('Unknown legacy network attachment must not be discarded')
    declared = {item['target']: item for item in service.get('volumes', [])}
    tmpfs = dict((item.split(':', 1) + [''])[:2] for item in service.get('tmpfs', []))
    if (current['tmpfs'] or {}) != tmpfs: raise ValueError('Legacy temporary mounts changed')
    if len(declared) != len(service.get('volumes', [])):
        raise ValueError('Duplicated legacy mount declaration')
    mounts = {item['Destination']: item for item in current['mounts']}
    if len(mounts) != len(current['mounts']) or set(mounts) - declared.keys() - tmpfs.keys() - set(implicit):
        raise ValueError('Unknown legacy mount must not be removed')
    for destination in mounts.keys() & tmpfs.keys():
        if mounts[destination].get('Type') != 'tmpfs' or mounts[destination].get('RW') is not True:
            raise ValueError('Unknown legacy mount must not replace a temporary filesystem')
    for destination, definition in declared.items():
        mounted = mounts.get(destination, {})
        if mounted.get('Type') != definition['type'] or mounted.get('RW') != (not definition.get('read_only', False)):
            raise ValueError('Legacy mount permissions or type changed')
        if definition['type'] == 'volume':
            if mounted.get('Name') != model['volumes'][definition['source']]['name']:
                raise ValueError('Legacy data volume identity changed')
        elif definition['type'] == 'bind':
            if mounted.get('Source') != definition['source']:
                raise ValueError('Legacy source mount changed')
        else: raise ValueError('Unsupported legacy mount type')
    anonymous = {}
    for destination in implicit:
        mounted = mounts.get(destination, {})
        name = mounted.get('Name')
        if (mounted.get('Type') != 'volume' or mounted.get('RW') is not True or
                not isinstance(name, str) or not re.fullmatch(r'[a-f0-9]{64}', name)):
            raise ValueError('Image-declared legacy runtime must use its owned anonymous volume')
        anonymous[destination] = name
    _ports(service, current['ports'])
    return anonymous


def _sources(root, release):
    hashes = {}
    for directory in ('infra', 'prototype'):
        path = network_bootstrap.directory(release, directory)
        for source in sorted(path.iterdir()):
            if source.name in ('runtime', '__pycache__'): continue
            if source.suffix in ('.py', '.json', '.yaml', '.service', '.conf', '.Dockerfile'):
                raw = network_bootstrap.existing(source)
                if raw is None or len(raw) > 1024 * 1024: raise ValueError('Invalid legacy source snapshot')
                hashes[str(source.relative_to(release))] = role_release.digest(raw)
            elif source.is_dir(): raise ValueError('Unknown legacy source package directory')
    override = network_bootstrap.existing(root / 'runtime/compose.override.yaml')
    hashes['runtime/compose.override.yaml'] = role_release.digest(override) if override is not None else None
    return role_release.json_digest(hashes)


def inspect(root, *, execute=role_deploy.run, require_running=True, restart_policy='legacy'):
    with locked(root) as root:
        return _inspect_locked(root, execute=execute, require_running=require_running, restart_policy=restart_policy)


def _inspect_locked(root, *, execute=role_deploy.run, require_running=True, restart_policy='legacy'):
    """Caller holds the existing legacy deploy lock for the entire maintenance."""
    if restart_policy not in ('legacy', 'fencing', 'fenced'):
        raise ValueError('Unknown legacy restart fence profile')
    root = Path(root)
    record = _json(root / 'current.json')
    topology.fields(record, ('release', 'manifest', 'backend', 'backend_config'))
    if any(not isinstance(record[key], str) or not role_release.SHA.fullmatch(record[key])
           for key in ('backend', 'backend_config')):
        raise ValueError('Verified legacy backend baseline required')
    release = Path(record['release'])
    if release.resolve() != release or release.parent != root / 'releases' or not release.is_dir():
        raise ValueError('Legacy release must remain inside its canonical releases directory')
    network_bootstrap.directory(root, 'releases/' + release.name + '/infra')
    manifest = _json(release / 'release.json')
    if legacy.manifest(release / 'release.json') != manifest or manifest != record['manifest'] or release.name != manifest['commit']:
        raise ValueError('Legacy release pointer or immutable manifest changed')
    runtime = core_deploy.runtime_digest(root)
    model = json.loads(execute(legacy.compose_command(release, 'config', '--format', 'json'), env=environment(record)))
    if (model.get('name') != 'voicechat' or set(model['services']) != set(SERVICES) or
            set(model['volumes']) != set(VOLUMES) or any(model['volumes'][key]['name'] != 'voicechat_' + key for key in VOLUMES)):
        raise ValueError('Unknown legacy service or volume namespace requires explicit migration')
    if legacy.release_record(release, manifest, model) != record:
        raise ValueError('Legacy configuration or recorded backend baseline changed')
    settings = model['services']['configure']['environment']
    if settings['PUBLIC_URL'] != manifest['origin']: raise ValueError('Legacy origin differs from its manifest')
    server_name = topology.hostname(settings['MATRIX_SERVER_NAME'])
    ids = execute(['docker', 'ps', '-aq', '--no-trunc', '--filter', 'label=com.docker.compose.project=voicechat']).decode().split()
    if len(ids) != len(SERVICES) or any(not re.fullmatch(r'[a-f0-9]{64}', value) for value in ids):
        raise ValueError('Exactly the known legacy containers are required before adoption')
    template = ('{"id":{{json .Id}},"image":{{json .Config.Image}},"image_id":{{json .Image}},'
        '"labels":{{json .Config.Labels}},"readonly":{{json (index .HostConfig "ReadonlyRootfs")}},'
        '"restart":{{json .HostConfig.RestartPolicy}},"cap_add":{{json (index .HostConfig "CapAdd")}},'
        '"cap_drop":{{json (index .HostConfig "CapDrop")}},"security_opt":{{json (index .HostConfig "SecurityOpt")}},'
        '"tmpfs":{{json (index .HostConfig "Tmpfs")}},"mounts":{{json .Mounts}},"state":{{json .State}},'
        '"ports":{{json (index .HostConfig "PortBindings")}},"networks":{{json .NetworkSettings.Networks}}}')
    found, implicit_volumes = {}, {}
    for identifier in ids:
        current = json.loads(execute(['docker', 'inspect', '--format', template, identifier]))
        name = current['labels'].get('com.docker.compose.service')
        if current['id'] != identifier or name not in SERVICES or name in found:
            raise ValueError('Unknown or duplicated legacy container ownership')
        service = model['services'][name]
        if not isinstance(service['image'], str) or not role_release.IMAGE.fullmatch(service['image']):
            raise ValueError('Legacy images must be immutable')
        image = json.loads(execute(['docker', 'image', 'inspect', '--format',
            '{"id":{{json .Id}},"volumes":{{json (index .Config "Volumes")}}}', service['image']]))
        if current['image_id'] != image['id'] or not re.fullmatch(r'sha256:[a-f0-9]{64}', image['id']):
            raise ValueError('Running legacy binary differs from its immutable image')
        implicit = set(image['volumes'] or {}) - {item['target'] for item in service.get('volumes', [])}
        if implicit and (name != 'turn' or implicit != {'/var/lib/coturn'}):
            raise ValueError('Unknown image-declared legacy volume requires separate migration')
        anonymous = _container(service, current, model,
            running=(name == 'postgres' and restart_policy == 'legacy') or (require_running and name != 'configure'),
            implicit=implicit, restart_policy=restart_policy)
        for volume in anonymous.values():
            value = json.loads(execute(['docker', 'volume', 'inspect', '--format',
                '{"name":{{json .Name}},"driver":{{json .Driver}},"labels":{{json .Labels}},"options":{{json .Options}}}', volume]))
            if (value['name'] != volume or value['driver'] != 'local' or value['options'] or
                    'com.docker.volume.anonymous' not in (value['labels'] or {})):
                raise ValueError('Unclaimed implicit legacy runtime volume must be preserved')
        if anonymous: implicit_volumes[name] = anonymous
        if name == 'configure' and (current['state']['Status'] != 'exited' or current['state']['ExitCode'] != 0):
            raise ValueError('Legacy configuration service has not completed successfully')
        found[name] = identifier
    images = {name: value['image'] for name, value in model['services'].items()}
    identity = core_deploy.volume_identity(images, model['volumes'], server_name, execute=execute)
    return {'schema': 1, 'root': str(root), 'record': record, 'matrix_server_name': server_name,
            'runtime_sha256': runtime, 'source_sha256': _sources(root, release),
            'images': images, 'containers': found, 'implicit_volumes': implicit_volumes, 'data_identity': identity}


def fence_restart(root, baseline, *, execute=role_deploy.run):
    with locked(root) as root:
        return _fence_restart_locked(root, baseline, execute=execute)


def _fence_restart_locked(root, baseline, *, execute=role_deploy.run):
    """Fence only captured legacy containers before the stopped-writer backup.

    Caller holds the legacy lock and has durably recorded the fencing phase.
    Docker may acknowledge only part of a multi-container update before death;
    resume accepts exactly old/no policies, never another source or data object.
    """
    current = _inspect_locked(root, execute=execute, require_running=False, restart_policy='fencing')
    if current != baseline: raise ValueError('Legacy baseline changed before restart fencing')
    identifiers = [baseline['containers'][name] for name in SERVICES if name != 'configure']
    execute(['docker', 'update', '--restart=no', *identifiers])
    if _inspect_locked(root, execute=execute, require_running=False, restart_policy='fenced') != baseline:
        raise ValueError('Legacy identity changed during restart fencing')
    return baseline


def rollback_override(baseline):
    """Reattach the same image-declared runtime after removing legacy containers.

    Use as an extra temporary Compose file, without changing the legacy baseline.
    External volume binding fails closed if its original data object is missing.
    """
    implicit = baseline['implicit_volumes']
    if not implicit: return {}
    topology.fields(implicit, ('turn',))
    topology.fields(implicit['turn'], ('/var/lib/coturn',))
    name = implicit['turn']['/var/lib/coturn']
    if not isinstance(name, str) or not re.fullmatch(r'[a-f0-9]{64}', name):
        raise ValueError('Exact original anonymous TURN volume required')
    return {'services': {'turn': {'volumes': [{'type': 'volume', 'source': 'legacy-turn-runtime',
        'target': '/var/lib/coturn'}]}},
        'volumes': {'legacy-turn-runtime': {'external': True, 'name': name}}}


def require_compatible(baseline, target):
    """Caller verifies the candidate bundle; adoption cannot change identity/engines."""
    role_release.validate(target)
    if (target['role'] != 'core' or target['identity'] != {
            'canonical_origin': baseline['record']['manifest']['origin'],
            'matrix_server_name': baseline['matrix_server_name']}):
        raise ValueError('Core adoption cannot change the existing Matrix/public identity')
    if any(target['images'][key] != baseline['images'][key] for key in ('postgres', 'synapse')):
        raise ValueError('Engine upgrades require a separate compatibility and restore procedure')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(inspect(args.root), sort_keys=True))


if __name__ == '__main__': main()
