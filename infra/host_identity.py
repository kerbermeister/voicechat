"""Create a generation-bound tunnel identity on a prepared node, without networking.

Only the public key leaves this entry point. A committed key is never regenerated
when its private file disappears; restore it or replace the host generation.
"""
import argparse
import json
import os
from pathlib import Path

import host_packages
import managed_state
import tunnel_config


def initialize(directory, inventory, node, *, system_root=Path('/')):
    target = host_packages.binding(inventory, node)
    host_packages.inspect_identity(system_root, target)
    with managed_state.locked(directory) as state:
        if (managed_state.read(state / 'current.json') != target or
                (state / 'pending.json').exists() or (state / 'pending.json').is_symlink()):
            raise ValueError('Complete the same host dependency preparation first')
        key = state / 'network.key'
        intent, receipt = state / 'identity-intent.json', state / 'identity.json'
        expected = {'schema': 1, 'target': target}
        if intent.exists() or intent.is_symlink():
            if managed_state.read(intent) != expected:
                raise ValueError('Resume the same host tunnel identity')
        else:
            if any(path.exists() or path.is_symlink() for path in (key, receipt)):
                raise ValueError('Cannot adopt an unclaimed tunnel identity')
            managed_state.persist(intent, expected)
        if receipt.exists() or receipt.is_symlink():
            value = managed_state.read(receipt)
            public = tunnel_config.public_key(tunnel_config.read_private(key))
            if value != {**expected, 'public_key': public}:
                raise ValueError('Committed tunnel identity changed; preserve the private key')
        else:
            public = tunnel_config.ensure_key(key)
            managed_state.persist(receipt, {**expected, 'public_key': public})
        return {'schema': 1, 'service_id': inventory['service_id'], 'node': node,
                'generation': target['assignment']['generation'], 'public_key': public}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--node', required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('Tunnel identity preparation requires root on the selected node')
    value = initialize(Path('/var/lib/voicechat-host'),
                       host_packages.load_inventory(args.inventory), args.node)
    print(json.dumps(value))


if __name__ == '__main__':
    main()
