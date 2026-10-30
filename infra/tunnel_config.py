"""Generate node-local WireGuard keys/configs offline; never apply networking."""
import argparse
import base64
import os
from pathlib import Path
import stat
import subprocess

import node_inventory
from topology import fields, read_json

PRIVATE_DER = bytes.fromhex('302e020100300506032b656e04220420')
PUBLIC_DER = bytes.fromhex('302a300506032b656e032100')


def key_bytes(value):
    if not isinstance(value, str): raise ValueError('WireGuard key required')
    try:
        raw = base64.b64decode(value, validate=True)
    except ValueError:
        raise ValueError('Invalid WireGuard key') from None
    if len(raw) != 32 or raw == bytes(32) or base64.b64encode(raw).decode() != value:
        raise ValueError('Canonical nonzero 32-byte WireGuard key required')
    return raw


def public_key(private):
    # RFC 8410 PKCS#8/SPKI wrappers; OpenSSL performs X25519 key derivation.
    result = subprocess.run(['openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'],
                            input=PRIVATE_DER + key_bytes(private), stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=True).stdout
    if len(result) != len(PUBLIC_DER) + 32 or not result.startswith(PUBLIC_DER):
        raise ValueError('Unexpected OpenSSL X25519 public key format')
    return base64.b64encode(result[len(PUBLIC_DER):]).decode()


def read_private(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'r') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_uid != os.geteuid():
            raise ValueError('Private key must be an owner-only regular file owned by this user')
        value = source.read(128).removesuffix('\n')
        key_bytes(value)
        return value


def ensure_key(path):
    path = Path(path)
    if not path.exists() and not path.is_symlink():
        result = subprocess.run(['openssl', 'genpkey', '-algorithm', 'X25519', '-outform', 'DER'],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout
        if len(result) != len(PRIVATE_DER) + 32 or not result.startswith(PRIVATE_DER):
            raise ValueError('Unexpected OpenSSL X25519 private key format')
        value = base64.b64encode(result[len(PRIVATE_DER):]).decode()
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            # Another bootstrap won the race; verify and retain its key.
            pass
        else:
            with os.fdopen(descriptor, 'w') as output:
                os.fchmod(output.fileno(), 0o600)
                output.write(value + '\n'); output.flush(); os.fsync(output.fileno())
            directory = os.open(path.parent, os.O_RDONLY)
            try: os.fsync(directory)
            finally: os.close(directory)
    return public_key(read_private(path))


def physical_nodes(inventory):
    node_inventory.validate(inventory)
    return {'core': inventory['core'], **{'edge-' + edge['id']: edge
            for edge in inventory['edges'] if 'host' not in edge}}


def validate_keys(value, inventory):
    fields(value, ('schema', 'service_id', 'nodes'))
    if type(value['schema']) is not int or value['schema'] != 1 or value['service_id'] != inventory['service_id']:
        raise ValueError('Invalid tunnel key registry identity/schema')
    nodes = physical_nodes(inventory)
    fields(value['nodes'], nodes)
    keys = set()
    for identity, node in nodes.items():
        item = value['nodes'][identity]
        fields(item, ('generation', 'public_key'))
        if type(item['generation']) is not int or item['generation'] != node['generation']:
            raise ValueError('Tunnel key belongs to a different host generation')
        key_bytes(item['public_key'])
        if item['public_key'] in keys: raise ValueError('Every physical host needs a unique tunnel key')
        keys.add(item['public_key'])
    return value


def render(inventory, registry, identity, private):
    nodes = physical_nodes(inventory)
    validate_keys(registry, inventory)
    if identity not in nodes: raise ValueError('Unknown physical node')
    if public_key(private) != registry['nodes'][identity]['public_key']:
        raise ValueError('Local private key does not match this verified host assignment')
    node = nodes[identity]
    lines = ['[Interface]', 'Address = ' + node['tunnel_ip'] + '/32',
             'ListenPort = 51820', 'PrivateKey = ' + private]
    peers = [name for name in nodes if name != 'core'] if identity == 'core' else ['core']
    for peer in peers:
        target = nodes[peer]
        lines += ['', '[Peer]', 'PublicKey = ' + registry['nodes'][peer]['public_key'],
                  'AllowedIPs = ' + target['tunnel_ip'] + '/32',
                  'Endpoint = ' + target['public_ip'] + ':51820']
        # Both ends initiate traffic after interface recreation. With edge-only
        # keepalive, peers can keep sending an old session to a restarted core
        # until rekey; core keepalive triggers a fresh handshake on link-up.
        lines.append('PersistentKeepalive = 25')
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    key = commands.add_parser('key')
    key.add_argument('--private-key', type=Path, required=True)
    config = commands.add_parser('render')
    config.add_argument('--inventory', type=Path, required=True)
    config.add_argument('--public-keys', type=Path, required=True)
    config.add_argument('--node', required=True)
    config.add_argument('--private-key', type=Path, required=True)
    config.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'key':
        # The only key written to stdout is public. Run on the destination host;
        # do not generate all nodes' private keys in the orchestrator workspace.
        print(ensure_key(args.private_key))
        return
    inventory = node_inventory.load(args.inventory)
    registry = read_json(args.public_keys)
    content = render(inventory, registry, args.node, read_private(args.private_key))
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        output.write(content); output.flush(); os.fsync(output.fileno())
    print('Private node configuration written; no interface, routing or firewall changed.')


if __name__ == '__main__': main()
