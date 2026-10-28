"""Atomically replace only the owned VoiceChat nftables table from saved intent.

This Linux host component does not install packages or enable boot services.
Apply the filter before starting tunnel-facing services; --resume restores the
last validated intent after interruption without reverting revoked peers.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import tempfile

import firewall_config
import managed_state
import node_inventory
from topology import fields
from tunnel_config import physical_nodes
from tunnel_runtime import command


def validate(value):
    fields(value, ('schema', 'inventory', 'node', 'edge_subnet'))
    if type(value['schema']) is not int or value['schema'] != 1:
        raise ValueError('Unsupported managed firewall state')
    firewall_config.render(value['inventory'], value['node'], value['edge_subnet'])
    return value


def transition(previous, current):
    if previous['node'] != current['node'] or previous['edge_subnet'] != current['edge_subnet']:
        raise ValueError('Local firewall role/subnet replacement requires a separate migration')
    node_inventory.check_replacement(previous['inventory'], current['inventory'])
    before = physical_nodes(previous['inventory'])[previous['node']]
    after = physical_nodes(current['inventory'])[current['node']]
    if before != after:
        raise ValueError('Local firewall host replacement requires a separate migration')


def inspect(value, *, owned, run):
    table, owner = firewall_config.identity(value['inventory'], value['node'])
    tables = json.loads(run('nft', '-j', 'list', 'tables'))['nftables']
    exists = any(item.get('table', {}).get('family') == 'inet' and
                 item['table'].get('name') == table for item in tables)
    if exists:
        # Debian 12's nft 1.0.6 omits table comments from JSON. Match only the
        # anchored table header/comment, never a comment buried in a rule.
        lines = run('nft', 'list', 'table', 'inet', table).splitlines()
        if (not owned or len(lines) < 2 or lines[0].strip() != f'table inet {table} {{' or
                lines[1].strip() != f'comment "{owner}"'):
            raise ValueError('Refusing to replace a foreign or unclaimed firewall table')
    return exists


def reconcile(directory, value=None, *, run=command):
    with managed_state.locked(directory) as directory:
        path = directory / 'desired.json'
        previous = validate(managed_state.read(path)) if path.exists() or path.is_symlink() else None
        desired = validate(value) if value is not None else previous
        if desired is None: raise ValueError('No saved firewall state to resume')
        if previous is not None: transition(previous, desired)
        exists = inspect(desired, owned=previous is not None, run=run)
        content = firewall_config.render(desired['inventory'], desired['node'],
                                         desired['edge_subnet'], replace=exists)
        descriptor, temporary = tempfile.mkstemp(prefix='.nft-', dir=directory)
        try:
            with os.fdopen(descriptor, 'w') as output:
                output.write(content); output.flush()
            run('nft', '--check', '--file', temporary)
            if previous != desired: managed_state.persist(path, desired)
            # nft applies the delete+replacement in a single kernel transaction;
            # there is no flush/re-add interval with an absent filter.
            run('nft', '--file', temporary)
            if not inspect(desired, owned=True, run=run):
                raise RuntimeError('Applied firewall table verification failed')
        finally:
            Path(temporary).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--inventory', type=Path)
    parser.add_argument('--node')
    parser.add_argument('--edge-subnet')
    args = parser.parse_args()
    if (args.resume and any((args.inventory, args.node, args.edge_subnet))) or (
            not args.resume and not (args.inventory and args.node)):
        parser.error('Choose --resume or provide inventory and node')
    if platform.system() != 'Linux' or os.geteuid() != 0:
        raise SystemExit('Applying firewall requires the selected Linux host as root')
    desired = None if args.resume else {'schema': 1, 'inventory': node_inventory.load(args.inventory),
        'node': args.node, 'edge_subnet': args.edge_subnet or '10.241.0.0/28'}
    reconcile(args.directory, desired)
    print('Managed firewall intent applied; unrelated tables and systemd unchanged.')


if __name__ == '__main__': main()
