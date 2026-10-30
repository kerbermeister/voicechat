"""Private host assignments, separate from the signed public route catalog.

Validation and rendering only: this module never contacts SSH, DNS or Docker.
"""
import base64
import hashlib
import ipaddress
import re
import struct

from topology import fields, read_json, validate as validate_topology


def ipv4(value, *, tunnel=False):
    if not isinstance(value, str):
        raise ValueError('IPv4 address required')
    address = ipaddress.ip_address(value)
    if (address.version != 4 or str(address) != value or address.is_unspecified or
            address.is_loopback or address.is_link_local or address.is_multicast or
            address.is_reserved):
        raise ValueError('Unicast IPv4 address required')
    private = any(address in ipaddress.ip_network(network)
                  for network in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'))
    if private != tunnel:
        raise ValueError('Separate public and RFC1918 tunnel addresses required')
    return value


def host_key(value):
    if not isinstance(value, str) or not value.startswith('ssh-ed25519 '):
        raise ValueError('Verified ssh-ed25519 host key required')
    try:
        encoded = value.split(' ')[1]
        raw = base64.b64decode(encoded, validate=True)
    except (ValueError, IndexError):
        raise ValueError('Invalid SSH host key') from None
    prefix = struct.pack('!I', 11) + b'ssh-ed25519' + struct.pack('!I', 32)
    if (value != 'ssh-ed25519 ' + base64.b64encode(raw).decode() or
            len(raw) != len(prefix) + 32 or not raw.startswith(prefix) or
            raw[len(prefix):] == bytes(32)):
        raise ValueError('Invalid SSH Ed25519 key encoding')
    return value


def shared_tls(value):
    fields(value, ('network', 'subnet', 'legacy_ip', 'ingress_ip'))
    if not isinstance(value['network'], str) or not re.fullmatch(r'[a-z][a-z0-9_-]{0,62}', value['network']):
        raise ValueError('Invalid shared TLS network name')
    if not isinstance(value['subnet'], str): raise ValueError('Shared TLS subnet must be a canonical CIDR')
    network = ipaddress.ip_network(value['subnet'], strict=True)
    if network.version != 4 or network.prefixlen != 29:
        raise ValueError('A dedicated private /29 is required for shared TLS')
    ipv4(str(network[1]), tunnel=True)
    addresses = [ipaddress.ip_address(ipv4(value[key], tunnel=True)) for key in ('legacy_ip', 'ingress_ip')]
    if len(set(addresses)) != 2 or any(address not in network or address in (network[0], network[1], network[-1]) for address in addresses):
        raise ValueError('Distinct shared TLS hosts must exclude the gateway and network/broadcast addresses')
    return value


def validate(value, topology=None):
    if topology is not None:
        validate_topology(topology)
    fields(value, ('schema', 'service_id', 'ssh_user', 'ssh_port', 'core', 'edges'))
    if type(value['schema']) is not int or value['schema'] != 1:
        raise ValueError('Unsupported inventory schema')
    if not isinstance(value['service_id'], str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,62}', value['service_id']):
        raise ValueError('Invalid installation ID')
    if topology is not None and value['service_id'] != topology['service_id']:
        raise ValueError('Inventory belongs to another installation')
    if not isinstance(value['ssh_user'], str) or not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', value['ssh_user']):
        raise ValueError('Invalid SSH user')
    if type(value['ssh_port']) is not int or not 1 <= value['ssh_port'] <= 65535:
        raise ValueError('Invalid SSH port')
    edges = value['edges']
    if not isinstance(edges, list) or not 1 <= len(edges) <= 32:
        raise ValueError('Between 1 and 32 edge assignments required')
    keys = ('generation', 'public_ip', 'tunnel_ip', 'ssh_host_key')
    fields(value['core'], keys)
    for edge in edges:
        if isinstance(edge, dict) and 'host' in edge:
            fields(edge, ('id', 'host', *(name for name in ('shared_tls', 'legacy_turn') if name in edge)))
            if 'shared_tls' in edge: shared_tls(edge['shared_tls'])
            if 'legacy_turn' in edge and type(edge['legacy_turn']) is not bool:
                raise ValueError('Legacy TURN compatibility must be a boolean')
            if edge['host'] != 'core':
                raise ValueError('Only an explicit core host reference is supported')
        else:
            fields(edge, (*keys, 'id'))
        if not isinstance(edge['id'], str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,31}', edge['id']):
            raise ValueError('Invalid inventory edge ID')
    ids = {edge['id'] for edge in edges}
    if len(ids) != len(edges):
        raise ValueError('Duplicate inventory edge ID')
    if topology is not None and ids != {edge['id'] for edge in topology['edges']}:
        raise ValueError('Inventory edge IDs must match public topology')
    if sum('host' in edge for edge in edges) > 1:
        raise ValueError('Only one edge may share the core host and public ports')
    nodes = [value['core'], *(edge for edge in edges if 'host' not in edge)]
    for node in nodes:
        if type(node['generation']) is not int or not 1 <= node['generation'] <= 2147483647:
            raise ValueError('Positive host generation required')
        ipv4(node['public_ip'])
        ipv4(node['tunnel_ip'], tunnel=True)
        host_key(node['ssh_host_key'])
    for edge in edges:
        if 'shared_tls' in edge:
            network = ipaddress.ip_network(edge['shared_tls']['subnet'])
            if any(ipaddress.ip_address(node['tunnel_ip']) in network for node in nodes):
                raise ValueError('Shared TLS network overlaps a tunnel address')
    for key in ('public_ip', 'tunnel_ip', 'ssh_host_key'):
        if len({node[key] for node in nodes}) != len(nodes):
            raise ValueError('Nodes must have distinct ' + key)
    return value


def load(path, topology=None):
    return validate(read_json(path), topology)


def edge_assignment(inventory, edge_id):
    edge = next((node for node in inventory['edges'] if node['id'] == edge_id), None)
    if edge is None:
        raise ValueError('Unknown edge host assignment')
    return {'id': edge_id, **inventory['core']} if edge.get('host') == 'core' else edge


def shared_tls_profile(inventory, edge_id):
    edge = next((item for item in inventory['edges'] if item['id'] == edge_id), None)
    if edge is None: raise ValueError('Unknown edge host assignment')
    return edge.get('shared_tls')


def check_replacement(previous, current):
    """Validate two already-validated inventories before preparing replacement.

    Changing a physical host/key must advance its generation; replaying an old
    inventory or silently reusing an old host identity is rejected.
    """
    if previous['service_id'] != current['service_id']:
        raise ValueError('Replacement cannot change installation')
    old = {('edge', node['id']): edge_assignment(previous, node['id']) for node in previous['edges']}
    old[('core', '')] = previous['core']
    new = {('edge', node['id']): edge_assignment(current, node['id']) for node in current['edges']}
    new[('core', '')] = current['core']
    for identity, node in new.items():
        before = old.get(identity)
        if before is None:
            continue
        if node['generation'] < before['generation']:
            raise ValueError('Host generation rollback')
        if node != before and node['generation'] == before['generation']:
            raise ValueError('Changed host assignment must advance generation')
        if node['generation'] > before['generation'] and node['ssh_host_key'] == before['ssh_host_key']:
            raise ValueError('Replacement requires a new verified host key')


def known_host(inventory, node):
    address = node['public_ip']
    if inventory['ssh_port'] != 22:
        address = '[' + address + ']:' + str(inventory['ssh_port'])
    return address + ' ' + node['ssh_host_key'] + '\n'


def edge_bridge(inventory, edge_id):
    """Stable Linux interface name shared by Compose and scoped firewall rules."""
    edge_assignment(inventory, edge_id)
    return 'vc-' + hashlib.sha256((inventory['service_id'] + ':' + edge_id).encode()).hexdigest()[:12]


def core_bridge(inventory):
    validate(inventory)
    return 'vcc-' + hashlib.sha256(inventory['service_id'].encode()).hexdigest()[:11]
