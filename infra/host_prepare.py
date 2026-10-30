"""Prepare dependencies on one clean host using pinned SSH and reviewed sources.

This does not register a new route, change network intent, or deploy a role.
A failed/uncertain installation resumes through the node-local package journal.
No registry credential, application secret or private tunnel key is transmitted.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess

import host_connection
import host_packages
import node_inventory
import ssh_deploy
import topology


def prepare(inventory, node, identity, commit, archive, *, checkout=None):
    target = host_packages.binding(inventory, node)
    if inventory['ssh_user'] != 'root':
        raise ValueError('Clean-host package preparation requires root SSH')
    # Separate from an existing deployment root: source delivery does not select
    # a release and package preparation refuses an unclaimed container runtime.
    root = '/var/lib/voicechat-host-source'
    with host_connection.connection(inventory, node, identity) as ssh:
        delivery = ssh_deploy.receive(ssh, root, commit, archive, checkout=checkout)
        command = ['python3', '-B', delivery['path'] + '/infra/host_packages.py',
                   '--inventory', '-', '--node', node, '--execute']
        response = subprocess.run([*ssh, shlex.join(command)],
            input=json.dumps(inventory, separators=(',', ':')).encode(),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3600, check=True)
    if len(response.stdout) > 65536:
        raise ValueError('Host preparation response exceeds its bound; inspect the node journal')
    value = json.loads(response.stdout, object_pairs_hook=topology.unique_object)
    expected = {'target': target, 'base': host_packages.BASE, 'docker': host_packages.DOCKER,
                'installed': True, 'scope': 'Dependencies only; no role/network/DNS deployment'}
    if json.dumps(value, sort_keys=True) != json.dumps(expected, sort_keys=True):
        raise ValueError('Unexpected host preparation receipt; inspect the node journal')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--node', required=True)
    parser.add_argument('--identity', type=Path)
    parser.add_argument('--commit')
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    inventory = node_inventory.load(args.inventory)
    target = host_packages.binding(inventory, args.node)
    if args.execute:
        if args.identity is None or args.commit is None or args.archive is None:
            parser.error('--execute requires --identity, --commit and --archive')
        value = prepare(inventory, args.node, args.identity, args.commit, args.archive)
    else:
        value = {'target': target, 'installed': False,
                 'scope': 'Plan only; no SSH or host changes'}
    print(json.dumps(value))


if __name__ == '__main__':
    main()
