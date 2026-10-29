"""Prepare and warm the shared TLS listener without taking public port 443.

The full cutover must separately move Caddy and verify all public routes. This
step owns only its HAProxy container/networks, and never starts core or edge.
"""
import hashlib
import json
import os
from pathlib import Path
import re
from copy import deepcopy

import managed_state
import node_inventory
import role_deploy
import role_prepare
import role_release
import shared_ingress
import topology

PROJECT = 'voicechat-shared-front'


def prepare(root, edge_root, manifest, *, warm_port=19443):
    """Copy the exact front from an already prepared immutable edge release."""
    root, edge_root = Path(root).absolute(), Path(edge_root).absolute()
    if root.resolve() != root or edge_root.resolve() != edge_root:
        raise ValueError('Canonical shared front and edge roots required')
    if type(warm_port) is not int or not 1024 <= warm_port <= 65535:
        raise ValueError('An unprivileged loopback warm port required')
    role_release.validate(manifest)
    if manifest['role'] != 'edge' or 'ingress' in manifest['images']:
        raise ValueError('A prepared shared edge release required')
    owner = managed_state.read(edge_root / 'role.json')
    if owner != {key: manifest[key] for key in ('schema', 'service_id', 'role', 'edge_id', 'identity')}:
        raise ValueError('Prepared edge ownership differs from candidate')
    release = role_deploy.release_path(edge_root, {'manifest': manifest})
    if managed_state.read(release / 'release.json') != manifest:
        raise ValueError('Prepared release receipt differs from candidate')
    model = json.loads(shared_ingress.read_environment(release / 'infra/compose.shared-front.json'))
    if model['name'] != PROJECT or set(model['services']) != {'ingress'}:
        raise ValueError('One independent shared ingress required')
    service = model['services']['ingress']
    if service['ports'] != ['443:8443/tcp'] or not role_release.IMAGE.fullmatch(service['image']):
        raise ValueError('Pinned shared public listener required')
    if service['volumes'] != [{'type': 'bind', 'source': './haproxy.cfg',
                              'target': '/usr/local/etc/haproxy/haproxy.cfg', 'read_only': True,
                              'bind': {'create_host_path': False}}]:
        raise ValueError('One read-only shared proxy configuration required')
    service['ports'] = [f'127.0.0.1:{warm_port}:8443/tcp']
    public_model = deepcopy(model)
    # Retain the private probe endpoint for certificate activation/renewal after
    # takeover; only the full cutover controller may select this definition.
    public_model['services']['ingress']['ports'].insert(0, '443:8443/tcp')
    node = json.loads(shared_ingress.read_environment(release / 'infra/node.json'))
    host_key = node_inventory.host_key(node['ssh_host_key'])
    files = {'haproxy.cfg': shared_ingress.read_environment(release / 'infra/haproxy.cfg'),
             'compose.json': (json.dumps(model, sort_keys=True, indent=2) + '\n').encode(),
             'compose.public.json': (json.dumps(public_model, sort_keys=True, indent=2) + '\n').encode()}
    record = {'schema': 1, 'service_id': manifest['service_id'], 'edge_id': manifest['edge_id'],
              'host_key': host_key, 'warm_port': warm_port,
              'files': {name: hashlib.sha256(content).hexdigest() for name, content in files.items()}}
    with managed_state.locked(root):
        role_prepare.directory(root / 'plans')
        plan = root / 'plans' / role_release.json_digest(record)
        role_prepare.directory(plan)
        if {item.name for item in plan.iterdir()} - {*files, 'plan.json'}:
            raise ValueError('Unexpected shared front source')
        for name, content in files.items():
            path = plan / name
            if path.exists() or path.is_symlink():
                if shared_ingress.read_environment(path) != content: raise ValueError('Immutable shared front source changed')
            else:
                descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
                with os.fdopen(descriptor, 'wb') as stream:
                    os.fchmod(stream.fileno(), 0o644)
                    stream.write(content); stream.flush(); os.fsync(stream.fileno())
        receipt = plan / 'plan.json'
        if (receipt.exists() or receipt.is_symlink()) and managed_state.read(receipt) != record:
            raise ValueError('Immutable shared front receipt changed')
        managed_state.persist(receipt, record)
        return plan


def read_plan(root, plan, *, system_root=Path('/')):
    root, plan = Path(root).absolute(), Path(plan).absolute()
    if root.resolve() != root or plan.resolve() != plan or plan.parent != root / 'plans':
        raise ValueError('Shared front plan must belong to its canonical root')
    role_prepare.directory(plan)
    record = managed_state.read(plan / 'plan.json')
    topology.fields(record, ('schema', 'service_id', 'edge_id', 'host_key', 'warm_port', 'files'))
    if type(record['schema']) is not int or record['schema'] != 1 or role_release.json_digest(record) != plan.name:
        raise ValueError('Shared front plan identity changed')
    if not isinstance(record['service_id'], str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,62}', record['service_id']):
        raise ValueError('Invalid shared front service')
    if not isinstance(record['edge_id'], str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,31}', record['edge_id']):
        raise ValueError('Invalid shared front edge')
    if type(record['warm_port']) is not int or not 1024 <= record['warm_port'] <= 65535:
        raise ValueError('Invalid shared front warm port')
    host = Path(system_root) / 'etc/ssh/ssh_host_ed25519_key.pub'
    if node_inventory.host_key(' '.join(shared_ingress.read_environment(host).decode().split()[:2])) != record['host_key']:
        raise ValueError('Shared front plan belongs to another SSH host')
    topology.fields(record['files'], ('haproxy.cfg', 'compose.json', 'compose.public.json'))
    if {item.name for item in plan.iterdir()} != {'haproxy.cfg', 'compose.json', 'compose.public.json', 'plan.json'}:
        raise ValueError('Unexpected shared front source')
    for name, checksum in record['files'].items():
        if not isinstance(checksum, str) or not role_release.SHA.fullmatch(checksum) or hashlib.sha256(shared_ingress.read_environment(plan / name)).hexdigest() != checksum:
            raise ValueError('Shared front source checksum changed')
    return record, json.loads(shared_ingress.read_environment(plan / 'compose.json'))


def _command(plan, *, public=False):
    return ['docker', 'compose', '--env-file', '/dev/null', '--project-name', PROJECT,
            '-f', str(plan / ('compose.public.json' if public else 'compose.json'))]


def _container(plan, model, *, execute, required):
    ids = execute(['docker', 'ps', '-aq', '--no-trunc', '--filter',
                   'label=com.docker.compose.project=' + PROJECT]).decode().split()
    if not ids and not required: return None
    if len(ids) != 1 or not re.fullmatch(r'[a-f0-9]{64}', ids[0]):
        raise ValueError('One owned shared front container required')
    template = ('{"id":{{json .Id}},"running":{{json .State.Running}},"image":{{json .Config.Image}},'
                '"labels":{{json .Config.Labels}},"mounts":{{json .Mounts}},'
                '"ports":{{json .HostConfig.PortBindings}},"networks":{{json .NetworkSettings.Networks}}}')
    value = json.loads(execute(['docker', 'inspect', '--format', template, ids[0]]))
    service = model['services']['ingress']
    configured = service['ports']
    warm = configured[-1]
    if not re.fullmatch(r'127\.0\.0\.1:[0-9]+:8443/tcp', warm) or configured not in ([warm], ['443:8443/tcp', warm]):
        raise ValueError('Only the known public and loopback shared front bindings are allowed')
    expected_ports = [('127.0.0.1', warm.split(':')[1])]
    if len(configured) == 2: expected_ports.append(('', '443'))
    bindings = value['ports']
    actual_ports = [(item['HostIp'], item['HostPort']) for item in bindings.get('8443/tcp', [])]
    mounts = value['mounts']
    networks = {model['networks'][name]['name']: item['ipv4_address'] for name, item in service['networks'].items()}
    if (value['id'] != ids[0] or value['image'] != service['image'] or
            value['labels'].get('com.docker.compose.project') != PROJECT or
            value['labels'].get('com.docker.compose.service') != 'ingress' or
            set(bindings) != {'8443/tcp'} or sorted(actual_ports) != sorted(expected_ports) or len(mounts) != 1 or
            mounts[0].get('Type') != 'bind' or mounts[0].get('RW') is not False or
            mounts[0].get('Source') != str(plan / 'haproxy.cfg') or
            mounts[0].get('Destination') != '/usr/local/etc/haproxy/haproxy.cfg' or
            set(value['networks']) != set(networks) or
            (value['running'] and any(value['networks'][name]['IPAddress'] != address for name, address in networks.items()))):
        raise ValueError('Shared front container identity, mounts, ports or networks changed')
    if required and not value['running']: raise ValueError('Shared front listener is not running')
    return value


def _networks(model, *, execute, owned):
    for name, network in model['networks'].items():
        ids = execute(['docker', 'network', 'ls', '-q', '--filter', 'name=^' + network['name'] + '$']).decode().split()
        if not ids: continue
        if not owned: raise ValueError('Refusing to adopt an existing shared front network')
        template = '{"name":{{json .Name}},"driver":{{json .Driver}},"labels":{{json .Labels}},"ipam":{{json .IPAM.Config}},"options":{{json .Options}}}'
        current = json.loads(execute(['docker', 'network', 'inspect', '--format', template, network['name']]))
        if (current['name'] != network['name'] or current['driver'] != 'bridge' or
                current['labels'].get('com.docker.compose.project') != PROJECT or
                current['labels'].get('com.docker.compose.network') != name or
                len(current['ipam']) != 1 or current['ipam'][0]['Subnet'] != network['ipam']['config'][0]['subnet'] or
                (current['options'] or {}) != network.get('driver_opts', {})):
            raise ValueError('Shared front network ownership or addressing changed')


def warm(root, plan, *, execute=role_deploy.run, system_root=Path('/')):
    """Start only the loopback listener; retry the same journal after failure.

    A committed warm plan cannot be replaced by this primitive. Public takeover
    and frontend configuration upgrades require the full ingress controller.
    """
    root, plan = Path(root).absolute(), Path(plan).absolute()
    with managed_state.locked(root):
        record, model = read_plan(root, plan, system_root=system_root)
        state = root / 'warm.json'
        saved = managed_state.read(state) if state.exists() or state.is_symlink() else None
        expected = {'schema': 1, 'plan': plan.name, 'phase': 'applying'}
        if saved not in (None, expected, {**expected, 'phase': 'running'}):
            raise ValueError('Resume the same shared front warm plan')
        _networks(model, execute=execute, owned=saved is not None)
        current = _container(plan, model, execute=execute, required=False)
        if current is not None and saved is None:
            raise ValueError('Refusing to adopt an unclaimed shared front container')
        if saved == {**expected, 'phase': 'running'} and current is not None and current['running']:
            return saved
        image = model['services']['ingress']['image']
        execute([*_command(plan), 'pull', '--policy', 'missing', 'ingress'],
                env={**os.environ, 'COMPOSE_DISABLE_ENV_FILE': 'true'})
        execute(['docker', 'run', '--rm', '--network', 'none', '--read-only',
                 '--volume', str(plan / 'haproxy.cfg') + ':/usr/local/etc/haproxy/haproxy.cfg:ro',
                 image, 'haproxy', '-c', '-f', '/usr/local/etc/haproxy/haproxy.cfg'])
        # Pull/validation may take time. Recheck ownership before recording an
        # initial claim, rather than adopting resources created in that window.
        if saved is None:
            _networks(model, execute=execute, owned=False)
            if _container(plan, model, execute=execute, required=False) is not None:
                raise ValueError('Shared front appeared before its ownership journal')
        managed_state.persist(state, expected)
        execute([*_command(plan), 'up', '-d', '--no-deps', '--no-build', '--pull', 'never',
                 '--wait', '--wait-timeout', '30', 'ingress'],
                env={**os.environ, 'COMPOSE_DISABLE_ENV_FILE': 'true'})
        _networks(model, execute=execute, owned=True)
        _container(plan, model, execute=execute, required=True)
        result = {**expected, 'phase': 'running'}
        managed_state.persist(state, result)
        return result
