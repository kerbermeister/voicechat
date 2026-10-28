"""Deploy one prepared edge, with durable rollback and a shared TLS writer lock.

This does not bootstrap hosts, migrate the legacy core or publish a catalog.
"""
import argparse
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
from urllib.parse import urlsplit

import managed_state
import role_deploy
from role_deploy import run, release_path
import node_inventory
import role_release
import role_bootstrap
import tls_activation
import tls_material
import tls_runtime
import topology



def compose(root, record, *arguments, execute=run):
    release = release_path(root, record)
    manifest = record['manifest']
    return execute(['docker', 'compose', '--env-file', '/dev/null', '--project-name',
        'voicechat-edge-' + manifest['edge_id'], '-f', str(release / 'infra/compose.edge.json'), *arguments],
        env={**os.environ, 'WEB_IMAGE': manifest['images']['web'], 'COMPOSE_DISABLE_ENV_FILE': 'true'})


def record_for(public, inventory, manifest):
    role_release.validate(manifest)
    if manifest['role'] != 'edge': raise ValueError('Edge manifest required')
    edge = next(item for item in public['edges'] if item['id'] == manifest['edge_id'])
    # Keep the TLS identity needed for rollback, not three copies of a large
    # discovery catalog in the atomic current/previous/pending journal.
    identity = {**public, 'edges': [edge], 'web_origins': list(dict.fromkeys(
        [public['canonical_origin'], edge['origin']]))}
    return {'manifest': manifest, 'identity': identity,
            'address': node_inventory.edge_assignment(inventory, edge['id'])['public_ip']}


def validate_record(record, edge_id):
    topology.fields(record, ('manifest', 'identity', 'address'))
    manifest = role_release.validate(record['manifest'])
    public = topology.validate(record['identity'])
    node_inventory.ipv4(record['address'])
    if (manifest['role'] != 'edge' or manifest['edge_id'] != edge_id or
            public['service_id'] != manifest['service_id'] or len(public['edges']) != 1 or
            public['edges'][0]['id'] != edge_id or any(public[key] != manifest['identity'][key]
                for key in ('canonical_origin', 'matrix_server_name'))):
        raise ValueError('Foreign edge deployment record')
    return record


def read_state(root, edge_id):
    path = root / 'state.json'
    if not path.exists() and not path.is_symlink():
        return {'schema': 1, 'current': None, 'previous': None, 'pending': None}
    state = managed_state.read(path)
    topology.fields(state, ('schema', 'current', 'previous', 'pending'))
    if type(state['schema']) is not int or state['schema'] != 1:
        raise ValueError('Unknown edge deployment state')
    for name in ('current', 'previous'):
        if state[name] is not None: validate_record(state[name], edge_id)
    if state['pending'] is not None:
        pending = state['pending']
        topology.fields(pending, ('target', 'scope', 'phase'))
        validate_record(pending['target'], edge_id)
        if pending['scope'] not in ('web', 'edge') or pending['phase'] not in ('prepared', 'applying', 'rollback'):
            raise ValueError('Invalid pending edge deployment')
    return state


def network_ready(inventory, edge_id, subnet, *, execute=run, directory=Path('/var/lib/voicechat-network')):
    node = 'core' if next(item for item in inventory['edges'] if item['id'] == edge_id).get('host') == 'core' else 'edge-' + edge_id
    return role_deploy.network_ready(inventory, node, subnet, execute=execute, directory=directory)


def snapshot(root, record, *, execute=run):
    services = [name for name in ('ingress', 'turn', 'route-health') if name in record['manifest']['images']]
    ids = compose(root, record, 'ps', '-q', *services, execute=execute).decode().split()
    if len(ids) != len(services): raise ValueError('Web deployment requires existing edge services')
    data = execute(['docker', 'inspect', '--format',
        '{{.Id}} {{.State.Running}} {{.State.StartedAt}} {{.RestartCount}}', *ids]).decode().splitlines()
    if len(data) != len(services) or any(' true ' not in item for item in data):
        raise ValueError('Existing edge services are not running')
    return sorted(data)


def certificate(root, record, service):
    path = root / 'runtime/tls'
    generation = tls_runtime.link_target(path / service / 'current')
    if generation is None: raise ValueError('Prepare edge TLS before deployment')
    verified = path / '.verified' / generation
    # Revalidate expiry, chain, key, identity and the serving selector before up.
    result = tls_runtime._publish_locked(path, record['identity'], record['manifest']['edge_id'], service,
        verified / (service + '.crt'), verified / (service + '.key'))
    if result['generation'] != generation: raise ValueError('TLS generation mismatch')
    return tls_material.read_material(verified / (service + '.crt'), private=True)


def healthy(root, record, *, execute=run):
    public, edge_id = record['identity'], record['manifest']['edge_id']
    for service in ('web', 'turn'):
        tls_activation.verify_live(record['address'], 443, tls_material.names(public, edge_id, service),
                                   certificate(root, record, service))
    name = urlsplit(public['edges'][0]['origin']).hostname
    context = ssl.create_default_context()
    with socket.create_connection((record['address'], 443), timeout=5) as raw:
        with context.wrap_socket(raw, server_hostname=name) as stream:
            stream.sendall(('GET /health/route HTTP/1.1\r\nHost: ' + name + '\r\nConnection: close\r\n\r\n').encode())
            response = http.client.HTTPResponse(stream)
            response.begin()
            body = response.read(4097)
            if response.status != 200 or len(body) > 4096:
                raise ValueError('Public edge readiness failed')
            value = json.loads(body)
    if (not isinstance(value, dict) or type(value.get('schema')) is not int or value['schema'] != 1 or
            value.get('service_id') != public['service_id'] or
            value.get('edge_id') != edge_id or value.get('matrix') is not True or value.get('control') is not True or
            type(value.get('age_ms')) is not int or not 0 <= value['age_ms'] <= 2000):
        raise ValueError('Public edge identity or upstream readiness failed')


def deploy(root, public, inventory, manifest, core_manifest, *, scope='edge', subnet='10.241.0.0/28',
           execute=run, check_network=network_ready, check_health=healthy, check_boot=role_bootstrap.ready, activate_monitor=role_bootstrap.activate):
    if scope not in ('web', 'edge'): raise ValueError('Choose web or edge scope')
    root = Path(root).absolute()
    if root.resolve() != root: raise ValueError('Deployment root must not traverse symlinks')
    role_release.require_compatible(core_manifest, manifest)
    target = record_for(public, inventory, manifest)
    edge_id = manifest['edge_id']
    with role_bootstrap.monitor_after(root, 'edge', edge_id, activate=activate_monitor), managed_state.locked(root), check_network(inventory, edge_id, subnet, execute=execute):
        check_boot(root, 'edge', edge_id)
        release = release_path(root, target)
        role_release.verify_bundle(release, manifest, public, inventory, subnet)
        state = read_state(root, edge_id)
        old = state['current']
        if old:
            release_path(root, old)
            if any(old['manifest'][name] != manifest[name] for name in ('service_id', 'identity', 'contracts', 'node_sha256')):
                raise ValueError('Changing role identity or physical host requires explicit migration')
        if scope == 'web':
            role_release.require_web_only(old['manifest'] if old else None, manifest)
        pending = state['pending']
        if pending and (pending['target'] != target or pending['scope'] != scope):
            raise ValueError('Resume the interrupted edge deployment before another target')
        if old is None and (pending is None or pending['phase'] == 'prepared'):
            if compose(root, target, 'ps', '-a', '-q', execute=execute).strip():
                raise ValueError('Existing edge containers have no verified baseline; explicit adoption required')
        if not pending:
            pending = {'target': target, 'scope': scope, 'phase': 'prepared'}
            state = {**state, 'pending': pending}
            managed_state.persist(root / 'state.json', state)
        if pending['phase'] == 'prepared':
            # Digests are immutable: reuse verified local image content and fetch
            # only missing images, so a config-only rollout can work offline.
            compose(root, target, 'pull', '--policy', 'missing',
                    *(['web'] if scope == 'web' else []), execute=execute)
        with managed_state.locked(root / 'runtime/tls'):
            def up(record):
                compose(root, record, 'up', '-d', '--wait', '--wait-timeout', '180',
                        *(['--no-deps', 'web'] if scope == 'web' else []), execute=execute)
            def rollback():
                if old:
                    up(old)
                    check_health(root, old, execute=execute)
                else:
                    compose(root, target, 'stop', execute=execute)
                managed_state.persist(root / 'state.json', {**state, 'pending': None})
            if pending['phase'] == 'rollback':
                rollback()
                raise RuntimeError('Interrupted rollback completed; retry the candidate explicitly')
            before = snapshot(root, old, execute=execute) if scope == 'web' else None
            # Validate both TLS pairs before any container can be changed.
            for service in ('web', 'turn'): certificate(root, target, service)
            state = {**state, 'pending': {**pending, 'phase': 'applying'}}
            managed_state.persist(root / 'state.json', state)
            try:
                up(target)
                check_health(root, target, execute=execute)
                if before is not None and snapshot(root, old, execute=execute) != before:
                    raise RuntimeError('Web deployment changed another edge service')
            except Exception:
                state = {**state, 'pending': {**pending, 'phase': 'rollback'}}
                managed_state.persist(root / 'state.json', state)
                rollback()
                raise
            managed_state.persist(root / 'state.json', {'schema': 1, 'current': target,
                'previous': old if old != target else state['previous'], 'pending': None})
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--topology', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--core-manifest', type=Path, required=True, help='Verified current core baseline')
    parser.add_argument('--scope', choices=('web', 'edge'), default='edge')
    parser.add_argument('--edge-subnet', default='10.241.0.0/28')
    args = parser.parse_args()
    public = topology.load(args.topology)
    deploy(args.root, public, node_inventory.load(args.inventory, public), role_release.load(args.manifest),
           role_release.load(args.core_manifest), scope=args.scope, subnet=args.edge_subnet)
    print('Edge deployment verified; current/previous committed atomically. Catalog unchanged.')


if __name__ == '__main__': main()
