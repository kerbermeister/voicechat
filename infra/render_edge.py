"""Render reviewable edge proxy files offline; never deploy or change DNS."""
import argparse
import json
import os
from pathlib import Path
from urllib.parse import urlsplit

import node_inventory
import topology
from edge_config import edge_proxy, sni_proxy


def render(public, inventory, edge_id, ingress_ip, *, web_ip=None, turn_ip=None):
    node_inventory.validate(inventory, public)
    node = node_inventory.edge_assignment(inventory, edge_id)
    edge = next(edge for edge in public['edges'] if edge['id'] == edge_id)
    names = [urlsplit(edge['origin']).hostname, urlsplit(public['canonical_origin']).hostname]
    shared = node_inventory.shared_tls_profile(inventory, edge_id)
    return {
        'Caddyfile': edge_proxy(public, edge_id, inventory['core']['tunnel_ip'], ingress_ip),
        'haproxy.cfg': sni_proxy(names, edge['turn_host'], web_ip=web_ip, turn_ip=turn_ip, legacy_ip=shared['legacy_ip'] if shared else None),
        'known_hosts': node_inventory.known_host(inventory, node),
        'node.json': json.dumps({
            'schema': 1, 'role': 'edge', 'service_id': public['service_id'],
            **node, 'ssh_user': inventory['ssh_user'], 'ssh_port': inventory['ssh_port'],
        }, sort_keys=True, indent=2) + '\n',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--topology', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--previous-inventory', type=Path)
    parser.add_argument('--edge', required=True)
    parser.add_argument('--ingress-ip', required=True, help='Exact private IP of the HAProxy container')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    public = topology.load(args.topology)
    inventory = node_inventory.load(args.inventory, public)
    if args.previous_inventory:
        old = node_inventory.load(args.previous_inventory)
        node_inventory.check_replacement(old, inventory)
    files = render(public, inventory, args.edge, args.ingress_ip)
    args.output.mkdir(mode=0o700)
    for name, content in files.items():
        descriptor = os.open(args.output / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(content)
    print('Offline edge files rendered; no host or DNS changes. TLS/runtime/deploy are separate steps.')


if __name__ == '__main__':
    main()
