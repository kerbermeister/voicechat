"""Bootstrap one prepared host using pinned SSH and reviewed sources.

An optional public key registry enables initial networking on an application-free
host. This does not deploy roles or publish routes. Interrupted steps retain the
node-local dependency journal, key and network intent.
No registry credential, application secret or private tunnel key is transmitted.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess

import host_connection
import host_packages
import host_network
import network_bootstrap
import role_release
import node_inventory
import ssh_deploy
import topology
import tunnel_config


def prepare(inventory, node, identity, commit, archive, *, checkout=None, initialize_key=False,
            public_keys=None, subnet='10.241.0.0/28'):
    target = host_packages.binding(inventory, node)
    network_request = None if public_keys is None else host_network.request(json.dumps({
        'schema': 1, 'inventory': inventory, 'public_keys': public_keys,
        'node': node, 'edge_subnet': subnet}).encode())
    if host_connection.parameters(inventory, node, identity)['user'] != 'root':
        raise ValueError('Clean-host package preparation requires root SSH')
    # Separate from an existing deployment root: source delivery does not select
    # a release and package preparation refuses an unclaimed container runtime.
    root = '/var/lib/voicechat-host-source'
    with host_connection.connection(inventory, node, identity) as ssh:
        delivery = ssh_deploy.receive(ssh, root, commit, archive, checkout=checkout)
        command = ['python3', '-B', delivery['path'] + '/infra/host_packages.py',
                   '--inventory', '-', '--node', node, '--execute']
        value = invoke(ssh, command, inventory)
        expected = {'target': target, 'base': host_packages.BASE, 'docker': host_packages.DOCKER,
                    'installed': True, 'scope': 'Dependencies only; no role/network/DNS deployment'}
        if json.dumps(value, sort_keys=True) != json.dumps(expected, sort_keys=True):
            raise ValueError('Unexpected host preparation receipt; inspect the node journal')
        if initialize_key or network_request is not None:
            command = ['python3', '-B', delivery['path'] + '/infra/host_identity.py',
                       '--inventory', '-', '--node', node]
            public = invoke(ssh, command, inventory)
            topology.fields(public, ('schema', 'service_id', 'node', 'generation', 'public_key'))
            expected_identity = {'schema': 1, 'service_id': inventory['service_id'], 'node': node,
                                 'generation': target['assignment']['generation']}
            if any(type(public[name]) is not type(item) or public[name] != item
                   for name, item in expected_identity.items()):
                raise ValueError('Tunnel public key belongs to another host generation')
            tunnel_config.key_bytes(public['public_key'])
            value = {**value, 'tunnel_identity': public,
                     'scope': 'Dependencies and tunnel identity; no network/role/DNS deployment'}
        if network_request is not None:
            if public['public_key'] != public_keys['nodes'][node]['public_key']:
                raise ValueError('Register the actual prepared public key before initializing networking')
            command = ['python3', '-B', delivery['path'] + '/infra/host_network.py']
            receipt = invoke(ssh, command, network_request)
            topology.fields(receipt, ('schema', 'node', 'generation', 'network_sha256', 'boot_source_sha256'))
            boot, _, _ = network_bootstrap.source_plan(network_request)
            expected = {'schema': 1, 'node': node, 'generation': target['assignment']['generation'],
                        'boot_source_sha256': boot['source_sha256']}
            if (any(type(receipt[name]) is not type(item) or receipt[name] != item
                    for name, item in expected.items()) or
                    not isinstance(receipt['network_sha256'], str) or
                    not role_release.SHA.fullmatch(receipt['network_sha256'])):
                raise ValueError('Unexpected network bootstrap receipt; inspect the node intent')
            value = {**value, 'network': receipt,
                     'scope': 'Dependencies, tunnel identity and initial network; no role/TLS/DNS/catalog deployment'}
    return value


def invoke(ssh, command, inventory):
    response = subprocess.run([*ssh, shlex.join(command)],
        input=json.dumps(inventory, separators=(',', ':')).encode(),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3600, check=True)
    if len(response.stdout) > 65536:
        raise ValueError('Host preparation response exceeds its bound; inspect the node journal')
    return json.loads(response.stdout, object_pairs_hook=topology.unique_object)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--node', required=True)
    connection = parser.add_mutually_exclusive_group()
    connection.add_argument('--identity', type=Path)
    connection.add_argument('--connection', type=Path, help='SSH profile with identity_file and optional host/port/user')
    parser.add_argument('--commit')
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--public-keys', type=Path, help='Also initialize networking using this complete registry')
    parser.add_argument('--edge-subnet', default='10.241.0.0/28')
    parser.add_argument('--initialize-key', action='store_true',
                        help='Also create the generation-bound node-local WireGuard key')
    args = parser.parse_args()
    inventory = node_inventory.load(args.inventory)
    target = host_packages.binding(inventory, args.node)
    keys = None if args.public_keys is None else topology.read_json(args.public_keys)
    if keys is not None:
        host_network.request(json.dumps({'schema': 1, 'inventory': inventory, 'public_keys': keys,
            'node': args.node, 'edge_subnet': args.edge_subnet}).encode())
    if args.execute:
        identity = topology.read_json(args.connection) if args.connection is not None else args.identity
        if identity is None or args.commit is None or args.archive is None:
            parser.error('--execute requires --identity or --connection, plus --commit and --archive')
        value = prepare(inventory, args.node, identity, args.commit, args.archive,
                        initialize_key=args.initialize_key, public_keys=keys, subnet=args.edge_subnet)
    else:
        value = {'target': target, 'installed': False,
                 'scope': 'Plan only; no SSH or host changes'}
    print(json.dumps(value))


if __name__ == '__main__':
    main()
