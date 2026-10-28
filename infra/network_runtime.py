"""Coordinate firewall and WireGuard from one durable host network intent.

Use this entrypoint for managed hosts. A crash between firewall and tunnel apply
must resume the same inventory, rather than unrelated per-component snapshots.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform

import firewall_runtime
import managed_state
import node_inventory
from topology import fields, read_json
import tunnel_config
import tunnel_runtime


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def components(value):
    fields(value, ('schema', 'inventory', 'public_keys', 'node', 'private_key', 'edge_subnet'))
    tunnel = tunnel_runtime.validate({key: item for key, item in value.items() if key != 'edge_subnet'})
    firewall = firewall_runtime.validate({key: value[key] for key in ('schema', 'inventory', 'node', 'edge_subnet')})
    return firewall, tunnel


def reconcile(directory, value=None, *, run=tunnel_runtime.command):
    with managed_state.locked(directory) as directory:
        path = directory / 'desired.json'
        previous = managed_state.read(path) if path.exists() or path.is_symlink() else None
        desired = value if value is not None else previous
        if desired is None: raise ValueError('No saved network state to resume')
        firewall, tunnel = components(desired)
        if previous is not None:
            old_firewall, old_tunnel = components(previous)
            firewall_runtime.transition(old_firewall, firewall)
            tunnel_runtime.transition(old_tunnel, tunnel)
        # Preflight both components before committing the shared intention.
        # Child locks also reject unsafe directories, state and foreign owners.
        with managed_state.locked(directory / 'firewall') as child:
            state = child / 'desired.json'
            saved = firewall_runtime.validate(managed_state.read(state)) if state.exists() or state.is_symlink() else None
            if saved is not None:
                if previous is None: raise ValueError('Unclaimed child firewall state')
                firewall_runtime.transition(saved, firewall)
            firewall_runtime.inspect(firewall, owned=saved is not None, run=run)
        with managed_state.locked(directory / 'tunnel') as child:
            state = child / 'desired.json'
            saved = tunnel_runtime.read_state(state) if state.exists() or state.is_symlink() else None
            if saved is not None:
                if previous is None: raise ValueError('Unclaimed child tunnel state')
                tunnel_runtime.transition(saved, tunnel)
            tunnel_runtime.inspect(tunnel, owned=saved is not None, run=run)
        if previous != desired: managed_state.persist(path, desired)
        status = {'schema': 1, 'sha256': fingerprint(desired), 'phase': 'applying'}
        managed_state.persist(directory / 'applied.json', status)
        # Revocation is restrictive first; a new peer cannot authenticate until
        # its WireGuard key is installed. Never roll back to retired credentials.
        firewall_runtime.reconcile(directory / 'firewall', firewall, run=run)
        tunnel_runtime.reconcile(directory / 'tunnel', tunnel, run=run)
        managed_state.persist(directory / 'applied.json', {**status, 'phase': 'complete'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--inventory', type=Path)
    parser.add_argument('--public-keys', type=Path)
    parser.add_argument('--node')
    parser.add_argument('--private-key', type=Path)
    parser.add_argument('--edge-subnet')
    args = parser.parse_args()
    inputs = (args.inventory, args.public_keys, args.node, args.private_key)
    if (args.resume and (any(inputs) or args.edge_subnet)) or (not args.resume and not all(inputs)):
        parser.error('Choose --resume or provide inventory, public-keys, node and private-key')
    if platform.system() != 'Linux' or os.geteuid() != 0:
        raise SystemExit('Applying networking requires the selected Linux host as root')
    desired = None if args.resume else {'schema': 1, 'inventory': node_inventory.load(args.inventory),
        'public_keys': read_json(args.public_keys), 'node': args.node,
        'private_key': tunnel_config.read_private(args.private_key), 'edge_subnet': args.edge_subnet or '10.241.0.0/28'}
    reconcile(args.directory, desired)
    print('Managed firewall and WireGuard applied from one saved intent; systemd unchanged.')


if __name__ == '__main__': main()
