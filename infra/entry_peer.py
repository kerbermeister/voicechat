"""Pinned-host entry lifecycle operations from one verified frozen source bundle."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import sys
import tempfile

import edge_deploy
import entry_lifecycle
import entry_image
import entry_turn
import entry_network
import entry_role
import managed_fence
import managed_journal
import managed_release
import network_bootstrap
import node_inventory
import publish_catalog
import role_bootstrap
import role_deploy
import role_prepare
import role_release
import route_catalog
import tls_material
import tls_runtime
import topology

ACTIONS = ('turn', 'image', 'stage', 'material', 'start', 'observe', 'claim', 'network', 'configure', 'release', 'catalog')
MAX_INPUT = 262144


def request(raw):
    if len(raw) > MAX_INPUT:
        raise ValueError('Entry peer request exceeds its bound')
    value = json.loads(raw, object_pairs_hook=topology.unique_object)
    topology.fields(value, ('schema', 'action', 'attempt', 'node', 'before_public', 'previous_inventory',
        'public', 'inventory', 'before', 'target', 'core', 'subnet', 'extra'))
    if (type(value['schema']) is not int or value['schema'] != 1 or value['action'] not in ACTIONS or
            not isinstance(value['attempt'], str) or not role_release.SHA.fullmatch(value['attempt']) or
            not isinstance(value['extra'], dict)):
        raise ValueError('Known entry peer operation required')
    change = entry_lifecycle.change(*(value[name] for name in
        ('before_public', 'previous_inventory', 'public', 'inventory')))
    target = value['target']
    if target is not None:
        role_release.verify_configuration(target, value['public'], value['inventory'])
        assignment = next((edge for edge in value['inventory']['edges'] if edge['id'] == target['edge_id']), {})
        physical = 'core' if target['role'] == 'core' or assignment.get('host') == 'core' else 'edge-' + target['edge_id']
        if physical != value['node']:
            raise ValueError('Role operation belongs to another physical node')
    if value['before'] is not None:
        role_release.verify_configuration(value['before'], value['before_public'], value['previous_inventory'])
    if value['action'] == 'turn':
        topology.fields(value['extra'], ('previous',))
    elif value['action'] == 'image':
        topology.fields(value['extra'], ('token',))
    elif value['action'] == 'network':
        topology.fields(value['extra'], ('public_keys', 'identity'))
    elif value['action'] == 'material':
        topology.fields(value['extra'], ('turn_secret', 'web_chain', 'web_key', 'turn_chain', 'turn_key', 'catalog', 'catalog_key'))
    elif value['action'] == 'catalog':
        topology.fields(value['extra'], ('catalog', 'catalog_key'))
    elif value['action'] in ('configure', 'release'):
        topology.fields(value['extra'], ('turn_secret',))
    else:
        topology.fields(value['extra'], ())
    if value['action'] in ('image', 'stage', 'material', 'start') and value['node'] != change['node']:
        raise ValueError('Prepare only the selected new physical entry')
    if value['action'] in ('claim', 'configure', 'release') and value['before'] is None:
        raise ValueError('Surviving role operation needs its committed baseline')
    if value['action'] != 'network' and target is None:
        raise ValueError('Role manifest required')
    return value


def operate(value, root, source_sha):
    value = request(json.dumps(value).encode())
    root = Path(root).absolute()
    if root.resolve() != root or not re.fullmatch(r'/[A-Za-z0-9/_-]+', str(root)) or root == Path('/'):
        raise ValueError('Canonical managed root required')
    if platform.system() != 'Linux' or os.geteuid() != 0:
        raise ValueError('Entry operations require the selected Linux host as root')
    sockets = ('unix:///var/run/docker.sock', 'unix:///run/docker.sock')
    if os.environ.get('DOCKER_HOST') not in (None, '', *sockets):
        raise ValueError('Local rootful Docker required')
    endpoint = role_deploy.run(['docker', 'context', 'inspect', '--format', '{{(index .Endpoints \"docker\").Host}}']).decode().strip()
    if endpoint not in sockets:
        raise ValueError('Local rootful Docker required')
    receipt = managed_journal._delivery(root, source_sha)
    source = root / 'bundles' / source_sha
    if source.resolve() != Path(__file__).resolve().parents[1]:
        raise ValueError('Run only the exact frozen entry peer source')
    public, inventory = value['public'], value['inventory']
    before, target, attempt = value['before'], value['target'], value['attempt']
    assignment = inventory['core'] if value['node'] == 'core' else node_inventory.edge_assignment(inventory, value['node'].removeprefix('edge-'))
    actual = network_bootstrap.existing(Path('/etc/ssh/ssh_host_ed25519_key.pub'))
    if actual is None or node_inventory.host_key(' '.join(actual.decode().split()[:2])) != assignment['ssh_host_key']:
        raise ValueError('Entry operation belongs to another pinned host generation')
    if target is not None and target != before:
        image = target['images']['control' if target['role'] == 'core' else 'web']
        expected = role_release.make(public, inventory, target['role'], receipt['manifest']['commit'],
                                     image, target['edge_id'], value['subnet'])
        if target != expected or (before is None and image != receipt['manifest']['web']):
            raise ValueError('Entry target differs from its frozen source/image delivery')
    path = None if target is None else root / 'core' if target['role'] == 'core' else root / 'edges' / target['edge_id']
    common = {'subnet': value['subnet']}
    action, extra = value['action'], value['extra']
    if action == 'turn':
        secret = tls_material.read_material(path / 'runtime/turn-secret', private=True).decode()
        return entry_turn.verify(public, inventory, target['edge_id'], secret, extra['previous'])
    if action == 'image':
        return entry_image.pull(target['images']['web'], extra['token'])
    if action == 'network':
        return entry_network.transition(root, value['previous_inventory'], inventory, extra['public_keys'],
            extra['identity'], value['node'], attempt, **common)
    if action == 'claim':
        return managed_fence.claim(path, value['before_public'], value['previous_inventory'], before, before, attempt, **common)
    if action in ('configure', 'release'):
        if action == 'configure':
            role_bootstrap.install(path, target['role'], target['edge_id'])
        return getattr(entry_role, 'apply' if action == 'configure' else 'release')(
            path, value['before_public'], value['previous_inventory'], public, inventory,
            before, target, attempt, turn_secret=extra['turn_secret'], **common)
    if action == 'stage':
        role_prepare.directory(root / 'edges')
        role_prepare.prepare(path, public, inventory, target, value['subnet'])
        role_bootstrap.install(path, 'edge', target['edge_id'])
        return {'schema': 1, 'node': value['node'], 'manifest': target, 'prepared': True}
    if action in ('material', 'catalog'):
        checked = route_catalog.verify(extra['catalog'].encode(), extra['catalog_key'], value['before_public'])
        if checked.topology != public:
            raise ValueError('Signed catalog differs from admitted topology')
        if action == 'material':
            if not isinstance(extra['turn_secret'], str) or not re.fullmatch(r'[a-f0-9]{64}', extra['turn_secret']):
                raise ValueError('One node-scoped TURN epoch required')
            role_prepare.directory(root / 'edges')
            role_prepare.prepare(path, public, inventory, target, value['subnet'])
            secret = path / 'runtime/turn-secret'
            if secret.exists() or secret.is_symlink():
                if tls_material.read_material(secret, private=True) != extra['turn_secret'].encode():
                    raise ValueError('Resume the same staged entry credential epoch')
            else:
                tls_material.write_private(secret, extra['turn_secret'].encode())
            with tempfile.TemporaryDirectory(prefix='.entry-tls-', dir=path / 'runtime') as temporary:
                for service in ('web', 'turn'):
                    chain, key = Path(temporary) / (service + '.crt'), Path(temporary) / (service + '.key')
                    tls_material.write_private(chain, extra[service + '_chain'].encode())
                    tls_material.write_private(key, extra[service + '_key'].encode())
                    tls_runtime.publish(path / 'runtime/tls', public, target['edge_id'], service, chain, key)
        catalog = path / 'runtime/catalog'
        verified = publish_catalog.publish(catalog, extra['catalog'].encode(), extra['catalog_key'],
            value['before_public'], initialize=not (catalog / 'routes.json').exists())
        if verified.topology != public:
            raise ValueError('Signed catalog differs from admitted topology')
        return {'schema': 1, 'manifest': target, 'catalog_revision': verified.revision, 'material_ready': True}
    if action == 'observe' and before is not None:
        facts = entry_role.observe(path, value['before_public'], value['previous_inventory'], public, inventory,
            before, target, attempt, **common)
        verify_images(path, target)
        facts['images_verified'] = True
        return facts
    if action == 'start':
        edge_deploy.deploy(path, public, inventory, target, value['core'], **common)
    facts = managed_release.inspect_role(path, public, inventory, target, **common)
    verify_images(path, target)
    facts['images_verified'] = True
    return facts



def verify_images(path, manifest):
    import core_deploy
    module = core_deploy if manifest['role'] == 'core' else edge_deploy
    state = core_deploy.read_state(path) if manifest['role'] == 'core' else edge_deploy.read_state(path, manifest['edge_id'])
    record = state['current']
    if record is None or record['manifest'] != manifest or state['pending'] is not None:
        raise ValueError('Committed role required for immutable image verification')
    for service, expected in manifest['images'].items():
        ids = module.compose(path, record, 'ps', '-a', '-q', service).decode().split()
        if len(ids) != 1:
            raise ValueError('Missing or duplicate role service container')
        actual = role_deploy.run(['docker', 'inspect', '--format', '{{.Config.Image}}', ids[0]]).decode().strip()
        if actual != expected:
            raise ValueError('Running role image differs from its immutable manifest')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--source-sha', required=True)
    args = parser.parse_args()
    try:
        result = operate(request(sys.stdin.buffer.read(MAX_INPUT + 1)), args.root, args.source_sha)
    except BlockingIOError:
        parser.exit(75, 'Entry operation is busy; preserve and resume its journal\n')
    if len(json.dumps(result).encode()) > MAX_INPUT:
        raise ValueError('Entry peer response exceeds its bound')
    print(json.dumps(result))


if __name__ == '__main__': main()
