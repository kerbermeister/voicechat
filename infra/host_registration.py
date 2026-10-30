"""Prepare the public WireGuard registry for one new or replaced entry host.

This validates an identity returned over pinned SSH. It never applies networking,
contacts the old host, publishes a route, or overwrites an existing registry.
"""
import argparse
from copy import deepcopy
import json
import os
from pathlib import Path

import node_inventory
import topology
import tunnel_config


def registry(previous_inventory, inventory, previous_keys, identity):
    node_inventory.validate(previous_inventory)
    node_inventory.validate(inventory)
    node_inventory.check_replacement(previous_inventory, inventory)
    tunnel_config.validate_keys(previous_keys, previous_inventory)
    if any(inventory[name] != previous_inventory[name]
           for name in ('schema', 'service_id', 'ssh_user', 'ssh_port', 'core')):
        raise ValueError('Entry registration cannot migrate the core or SSH policy')
    before, after = (tunnel_config.physical_nodes(value)
                     for value in (previous_inventory, inventory))
    changed = [name for name in after if after[name] != before.get(name)]
    if set(before) - set(after) or len(changed) != 1 or changed[0] == 'core':
        raise ValueError('Register exactly one new or replaced physical entry host')
    node = changed[0]
    old_ids = {item['id'] for item in previous_inventory['edges']}
    new_ids = {item['id'] for item in inventory['edges']}
    if not old_ids <= new_ids or len(new_ids - old_ids) > 1:
        raise ValueError('Entry removal needs a separate retirement operation')
    # Do not smuggle a second logical change through a co-located host reference.
    old_edges = {item['id']: item for item in previous_inventory['edges']}
    new_edges = {item['id']: item for item in inventory['edges']}
    for identifier in old_ids - {node.removeprefix('edge-')}:
        if old_edges[identifier] != new_edges[identifier]:
            raise ValueError('Unrelated entry assignment changed')
    topology.fields(identity, ('schema', 'service_id', 'node', 'generation', 'public_key'))
    expected = {'schema': 1, 'service_id': inventory['service_id'], 'node': node,
                'generation': after[node]['generation']}
    if any(type(identity[name]) is not type(value) or identity[name] != value
           for name, value in expected.items()):
        raise ValueError('Public tunnel identity does not match the selected generation')
    tunnel_config.key_bytes(identity['public_key'])
    if identity['public_key'] in {item['public_key'] for item in previous_keys['nodes'].values()}:
        raise ValueError('A new host generation requires a fresh tunnel key')
    result = deepcopy(previous_keys)
    result['nodes'][node] = {'generation': identity['generation'], 'public_key': identity['public_key']}
    return tunnel_config.validate_keys(result, inventory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--previous-inventory', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--public-keys', type=Path, required=True)
    parser.add_argument('--node-identity', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    value = registry(node_inventory.load(args.previous_inventory), node_inventory.load(args.inventory),
                     topology.read_json(args.public_keys), topology.read_json(args.node_identity))
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        json.dump(value, output, sort_keys=True); output.write('\n')
        output.flush(); os.fsync(output.fileno())
    print('Public key registry prepared; no host networking or routes changed.')


if __name__ == '__main__':
    main()
