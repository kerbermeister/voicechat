"""Initialize the owned network/boot gate on a prepared, application-free host.

Private tunnel material is read only on the destination. Existing network intent
must match exactly: peer changes on live hosts need the coordinated lifecycle.
"""
import argparse
import json
import os
from pathlib import Path
import sys

import host_packages
import firewall_runtime
import managed_state
import network_bootstrap
import network_runtime
import node_inventory
import topology
import tunnel_config
from tunnel_runtime import command


def request(raw):
    if len(raw) > 65536:
        raise ValueError('Host network request exceeds its bound')
    value = json.loads(raw, object_pairs_hook=topology.unique_object)
    topology.fields(value, ('schema', 'inventory', 'public_keys', 'node', 'edge_subnet'))
    if type(value['schema']) is not int or value['schema'] != 1:
        raise ValueError('Known host network request required')
    host_packages.binding(value['inventory'], value['node'])
    tunnel_config.validate_keys(value['public_keys'], value['inventory'])
    firewall_runtime.validate({name: value[name] for name in
                              ('schema', 'inventory', 'node', 'edge_subnet')})
    return value


def initialize(value, *, system_root=Path('/'), run=command):
    value = request(json.dumps(value).encode())
    system_root = Path(system_root).absolute()
    target = host_packages.binding(value['inventory'], value['node'])
    host_packages.inspect_identity(system_root, target)
    directory = network_bootstrap.directory(system_root, 'var/lib/voicechat-host')
    network = network_bootstrap.directory(system_root, 'var/lib/voicechat-network')
    with managed_state.locked(directory) as state:
        if (managed_state.read(state / 'current.json') != target or
                (state / 'pending.json').exists() or (state / 'pending.json').is_symlink()):
            raise ValueError('Finish the same host dependency preparation first')
        private = tunnel_config.read_private(state / 'network.key')
        public = tunnel_config.public_key(private)
        if managed_state.read(state / 'identity.json') != {'schema': 1, 'target': target, 'public_key': public}:
            raise ValueError('Prepared tunnel identity changed')
        desired = {**value, 'private_key': private}
        network_runtime.components(desired)
        # No service may start while bootstrap installs Docker's boot gate.
        # Inspect stopped containers too; an application host needs migration.
        if run('docker', 'ps', '-aq').strip():
            raise ValueError('Initial network bootstrap requires an application-free host')
        path = network / 'desired.json'
        if path.exists() or path.is_symlink():
            if managed_state.read(path) != desired:
                raise ValueError('Existing network intent needs a coordinated lifecycle change')
        elif network.exists() and {item.name for item in network.iterdir()} - {'apply.lock'}:
            raise ValueError('Cannot adopt unclaimed network state')
        boot_receipt = network / 'boot-install/desired.json'
        if not boot_receipt.exists() and not boot_receipt.is_symlink():
            if any(network_bootstrap.existing(system_root / name) is not None
                   for name in (network_bootstrap.UNIT, network_bootstrap.DROP_IN)):
                raise ValueError('Cannot replace an unclaimed network boot gate')
            if any(line.split()[:1] == ['voicechat-network.service'] for line in
                   run('systemctl', 'list-unit-files', '--no-legend', '--no-pager').splitlines()):
                raise ValueError('Cannot replace an unclaimed network service')
        # Both existing components retain their own crash-safe intent/receipts.
        network_runtime.reconcile(network, desired, run=run)
        source = network_bootstrap.install(system_root, run=run)
        return {'schema': 1, 'node': value['node'], 'generation': target['assignment']['generation'],
                'network_sha256': network_runtime.fingerprint(desired), 'boot_source_sha256': source}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('Host network initialization requires root on the selected node')
    print(json.dumps(initialize(request(sys.stdin.buffer.read(65537)))))


if __name__ == '__main__':
    main()
