"""Prepare a role bundle locally, without reading secrets or executing deployment."""
import argparse
import json
import os
from pathlib import Path

import node_inventory
import role_config
import topology

NETWORK_FILES = ('node_inventory.py', 'tunnel_config.py', 'tunnel_runtime.py',
                 'managed_state.py', 'firewall_config.py', 'firewall_runtime.py',
                 'network_runtime.py', 'host_preflight.py',
                 'network_bootstrap.py',
                 'voicechat-network.service', 'voicechat-docker-network.conf')


def bundle(public, inventory, role, edge_id=None, subnet='10.241.0.0/28'):
    node_inventory.validate(inventory, public)
    shared = ['configure.py', 'topology.py', 'client_config.py', *NETWORK_FILES]
    if role == 'core':
        if edge_id is not None:
            raise ValueError('Core has no edge ID')
        compose = role_config.core(public, inventory)
        sources = ['infra/' + name for name in [*shared, 'compose.yaml', 'push_route_migration.py']]
        sources += ['prototype/' + name for name in ('client-policy.json', 'voicechat_policy.py',
                                                    'client_policy.py', 'scheduled_messages.py')]
        node = inventory['core']
        generated = {'known_hosts': node_inventory.known_host(inventory, node),
                     'node.json': json.dumps({'schema':1, 'role':'core', 'service_id':public['service_id'],
                                             **node, 'ssh_user':inventory['ssh_user'], 'ssh_port':inventory['ssh_port']}, sort_keys=True, indent=2)}
        runtime = ['runtime']
    elif role == 'edge':
        compose, generated = role_config.edge(public, inventory, edge_id, subnet)
        sources = ['infra/' + name for name in [*shared, 'edge_turn.py', 'route_health.py', 'tls_material.py', 'tls_runtime.py', 'tls_activation.py']]
        runtime = ['runtime/tls', 'runtime/tls/web', 'runtime/tls/turn', 'runtime/catalog',
                   'runtime/android-updates', 'runtime/macos-updates']
    else:
        raise ValueError('Unknown server role')
    files = {name: (role_config.ROOT / name).read_text() for name in sources}
    if role == 'core':
        # The legacy BIND may be 0.0.0.0/:: or another interface. The core media
        # ACL protects the inventory address; never publish a bypass on aliases.
        source = role_config.core_base(files['infra/compose.yaml'])
        if '${BIND}' not in source: raise ValueError('Core base bind contract changed')
        files['infra/compose.yaml'] = source.replace('${BIND}', inventory['core']['public_ip'])
    files.update({'infra/' + name: content for name, content in generated.items()})
    files['infra/compose.' + role + '.json'] = json.dumps(compose, indent=2) + '\n'
    return files, runtime


def write_bundle(output, files, runtime):
    output.mkdir(mode=0o700)
    for name, content in files.items():
        path = output / name
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        # These are public source/configuration mounts, readable by unprivileged
        # container UIDs. The containing bundle stays private on the host.
        mode = 0o600 if path.name in ('node.json', 'known_hosts') else 0o644
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        with os.fdopen(descriptor, 'w') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
    for name in runtime:
        (output / 'infra' / name).mkdir(mode=0o700, parents=True, exist_ok=True)
        if name in ('runtime/catalog', 'runtime/android-updates', 'runtime/macos-updates'):
            (output / 'infra' / name).chmod(0o755)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--topology', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--previous-inventory', type=Path)
    parser.add_argument('--role', choices=('core', 'edge'), required=True)
    parser.add_argument('--edge')
    parser.add_argument('--edge-subnet', default='10.241.0.0/28')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    public = topology.load(args.topology)
    inventory = node_inventory.load(args.inventory, public)
    if args.previous_inventory:
        node_inventory.check_replacement(node_inventory.load(args.previous_inventory), inventory)
    files, runtime = bundle(public, inventory, args.role, args.edge, args.edge_subnet)
    write_bundle(args.output, files, runtime)
    print('Role bundle rendered locally. Runtime secrets, TLS, tunnels and deployment are not applied.')


if __name__ == '__main__':
    main()
