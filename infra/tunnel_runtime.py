"""Reconcile the owned wg-vc interface from an atomic private desired-state file.

Run only on the selected Linux host after host/firewall preparation. This does
not install packages, modify firewall/default routes, enable systemd, or use SSH.
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

import node_inventory
import tunnel_config
from topology import fields, read_json
import managed_state

INTERFACE = 'wg-vc'


def command(*args):
    # Never include stderr or a private configuration in a diagnostic/exception.
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    if result.returncode:
        raise RuntimeError('Network command failed: ' + ' '.join(args[:3]))
    return result.stdout.decode()


def validate(value):
    fields(value, ('schema', 'inventory', 'public_keys', 'node', 'private_key'))
    if type(value['schema']) is not int or value['schema'] != 1:
        raise ValueError('Unsupported managed tunnel state')
    # This verifies identity, generations and the local private/public key pair.
    tunnel_config.render(value['inventory'], value['public_keys'], value['node'], value['private_key'])
    return value


def read_state(path):
    return validate(managed_state.read(path))


def transition(previous, current):
    validate(previous); validate(current)
    if previous['node'] != current['node']:
        raise ValueError('Cannot repurpose an owned tunnel as another physical node')
    node_inventory.check_replacement(previous['inventory'], current['inventory'])
    before = tunnel_config.physical_nodes(previous['inventory'])[previous['node']]
    after = tunnel_config.physical_nodes(current['inventory'])[current['node']]
    if before != after or previous['private_key'] != current['private_key']:
        raise ValueError('Local host identity/address/key replacement requires a separate migration')
    for name, old in previous['public_keys']['nodes'].items():
        new = current['public_keys']['nodes'].get(name)
        if new and old['generation'] == new['generation'] and old['public_key'] != new['public_key']:
            raise ValueError('Peer key replacement must advance its verified host generation')


def inspect(value, *, owned, run=command):
    """Validate all collisions before saving intent or changing the interface."""
    nodes = tunnel_config.physical_nodes(value['inventory'])
    local = nodes[value['node']]['tunnel_ip']
    targets = {node['tunnel_ip'] + '/32' for name, node in nodes.items()
               if name != value['node'] and (value['node'] == 'core' or name == 'core')}
    links = json.loads(run('ip', '-j', '-d', 'link', 'show'))
    link = next((item for item in links if item['ifname'] == INTERFACE), None)
    if link and (not owned or link.get('linkinfo', {}).get('info_kind') != 'wireguard'):
        raise ValueError('Refusing to claim an existing or foreign interface')
    if link:
        actual = run('wg', 'show', INTERFACE, 'public-key').strip()
        expected = value['public_keys']['nodes'][value['node']]['public_key']
        if actual not in ('', '(none)', expected):
            raise ValueError('Live interface key differs from managed identity')
    for item in json.loads(run('ip', '-j', '-4', 'address', 'show')):
        addresses = {address['local'] for address in item.get('addr_info', []) if address['family'] == 'inet'}
        if item['ifname'] == INTERFACE:
            if addresses - {local}:
                raise ValueError('Owned interface has an unexpected IPv4 address')
        elif local in addresses:
            raise ValueError('Tunnel address is already owned by another interface')
    routes = json.loads(run('ip', '-j', '-4', 'route', 'show', 'table', 'main'))
    existing = set()
    for route in routes:
        destination = route.get('dst', 'default')
        if destination == 'default': continue
        network = ipaddress.ip_network(destination, strict=False)
        if route.get('dev') == INTERFACE:
            if network.prefixlen != 32 or route.get('gateway') or route.get('type', 'unicast') != 'unicast':
                raise ValueError('Owned interface has an unexpected route')
            if str(network.network_address) != local:
                existing.add(str(network))
        elif any(ipaddress.ip_address(target.split('/')[0]) in network for target in targets | {local + '/32'}):
            raise ValueError('Planned tunnel address overlaps an existing main-table route')
    return link is not None, targets, existing, local


def reconcile(directory, value=None, *, run=command):
    with managed_state.locked(directory) as directory:
        path = directory / 'desired.json'
        previous = read_state(path) if path.exists() or path.is_symlink() else None
        desired = validate(value) if value is not None else previous
        if desired is None: raise ValueError('No saved tunnel state to resume')
        if previous is not None: transition(previous, desired)
        exists, targets, old_routes, local = inspect(desired, owned=previous is not None, run=run)
        # One atomic record includes only this node's private key and public peer
        # data. An interrupted apply resumes this intent, never a half-updated
        # key/config pair. Do not silently roll back a revoked peer on failure.
        if previous != desired: managed_state.persist(path, desired)
        if not exists:
            run('ip', 'link', 'add', 'dev', INTERFACE, 'type', 'wireguard')
        content = tunnel_config.render(desired['inventory'], desired['public_keys'],
                                       desired['node'], desired['private_key'])
        content = '\n'.join(line for line in content.splitlines() if not line.startswith('Address = ')) + '\n'
        descriptor, temporary = tempfile.mkstemp(prefix='.wg-', dir=directory)
        try:
            with os.fdopen(descriptor, 'w') as config:
                os.fchmod(config.fileno(), 0o600)
                config.write(content); config.flush()
            run('wg', 'syncconf', INTERFACE, temporary)
        finally:
            Path(temporary).unlink(missing_ok=True)
        run('ip', 'address', 'replace', local + '/32', 'dev', INTERFACE)
        run('ip', 'link', 'set', 'dev', INTERFACE, 'mtu', '1420', 'up')
        for route in sorted(targets - old_routes):
            run('ip', 'route', 'add', route, 'dev', INTERFACE)
        for route in sorted(old_routes - targets):
            run('ip', 'route', 'del', route, 'dev', INTERFACE)
        if run('wg', 'show', INTERFACE, 'public-key').strip() != desired['public_keys']['nodes'][desired['node']]['public_key']:
            raise RuntimeError('Applied tunnel key verification failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--inventory', type=Path)
    parser.add_argument('--public-keys', type=Path)
    parser.add_argument('--node')
    parser.add_argument('--private-key', type=Path)
    args = parser.parse_args()
    inputs = (args.inventory, args.public_keys, args.node, args.private_key)
    if (args.resume and any(inputs)) or (not args.resume and not all(inputs)):
        parser.error('Choose --resume or provide inventory, public-keys, node and private-key')
    if platform.system() != 'Linux' or os.geteuid() != 0:
        raise SystemExit('Applying networking requires the selected Linux host as root')
    desired = None if args.resume else {'schema': 1, 'inventory': node_inventory.load(args.inventory),
        'public_keys': read_json(args.public_keys), 'node': args.node,
        'private_key': tunnel_config.read_private(args.private_key)}
    reconcile(args.directory, desired)
    print('Managed WireGuard intent applied; firewall, default routes and systemd unchanged.')


if __name__ == '__main__': main()
