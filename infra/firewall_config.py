"""Render an additional scoped nftables filter; never flush the host ruleset.

The filter only restricts VoiceChat's owned private address, WireGuard port and
core API/media ports. Other host policy still decides whether allowed traffic
passes. Applying/replacing the table needs a separate ownership-checked rollout.
"""
import argparse
import hashlib
import ipaddress
import os
from pathlib import Path

import node_inventory
from tunnel_config import physical_nodes

API_PORTS = '{ 7880, 8088, 8090 }'


def identity(inventory, node):
    if node not in physical_nodes(inventory): raise ValueError('Unknown physical node')
    name = 'vc_' + hashlib.sha256(inventory['service_id'].encode()).hexdigest()[:12]
    return name, 'voicechat-firewall-v1:' + inventory['service_id'] + ':' + node


def addresses(values):
    if not values: raise ValueError('Empty address set')
    return '{ ' + ', '.join(sorted(values)) + ' }'


def render(inventory, node, subnet='10.241.0.0/28', *, replace=False):
    nodes = physical_nodes(inventory)
    table, owner = identity(inventory, node)
    network = ipaddress.ip_network(subnet, strict=True)
    if network.version != 4 or network.prefixlen != 28:
        raise ValueError('An RFC1918 /28 edge bridge is required')
    node_inventory.ipv4(str(network[1]), tunnel=True)
    if any(ipaddress.ip_address(item['tunnel_ip']) in network for item in nodes.values()):
        raise ValueError('Bridge overlaps tunnel addresses')
    current = nodes[node]
    peers = [item for name, item in nodes.items() if name != node and (node == 'core' or name == 'core')]
    public, private = current['public_ip'], current['tunnel_ip']
    incoming = ['iifname "lo" return']
    forwarded = []
    # No IPv6 peers are configured. The owned UDP port must not silently acquire
    # an unrestricted IPv6 path; HTTP/TURN ports are unaffected by this rule.
    if peers:
        incoming.append('ip saddr ' + addresses([item['public_ip'] for item in peers]) + ' udp dport 51820 return')
    incoming.append('udp dport 51820 drop')
    incoming.append(f'ip daddr {private} ct direction reply ct state established,related return')

    if node == 'core':
        backend_bridge = node_inventory.core_bridge(inventory)
        api_input = f'ip daddr {private} tcp dport {API_PORTS}'
        api_forward = f'ct direction original ct original ip daddr {private} meta l4proto tcp ct original proto-dst {API_PORTS}'
        co_located = next((edge for edge in inventory['edges'] if edge.get('host') == 'core'), None)
        if peers:
            allowed = 'iifname "wg-vc" ip saddr ' + addresses([item['tunnel_ip'] for item in peers])
            incoming.append(api_input + ' ' + allowed + ' return')
            forwarded.append(api_forward + ' ' + allowed + ' return')
        if co_located:
            bridge = node_inventory.edge_bridge(inventory, co_located['id'])
            allowed = f'iifname "{bridge}" ip saddr ' + addresses([str(network[3]), str(network[5])])
            incoming.append(api_input + ' ' + allowed + ' return')
            forwarded.append(api_forward + ' ' + allowed + ' return')
        incoming.append(f'ip daddr {public} tcp dport {API_PORTS} drop')
        forwarded.append(f'ct direction original ct original ip daddr {public} meta l4proto tcp ct original proto-dst {API_PORTS} drop')
        # TURN reaches the public SFU address; clients are not required to reach A
        # directly. A co-located TURN uses its fixed bridge address before SNAT.
        for protocol, port in (('tcp', '7981'), ('udp', '50300-50400')):
            media_input = f'ip daddr {public} {protocol} dport {port}'
            media_forward = f'ct direction original ct original ip daddr {public} meta l4proto {protocol} ct original proto-dst {port}'
            media_reply = f'ct direction reply oifname "{backend_bridge}" iifname != "{backend_bridge}" {protocol} dport {port}'
            if peers:
                allowed = 'ip saddr ' + addresses([item['public_ip'] for item in peers])
                incoming.append(media_input + ' ' + allowed + ' return')
                forwarded.append(media_forward + ' ' + allowed + ' return')
                forwarded.append(media_reply + ' ' + allowed + ' return')
            if co_located:
                allowed = f'iifname "{bridge}" ip saddr {network[4]}'
                incoming.append(media_input + ' ' + allowed + ' return')
                forwarded.append(media_forward + ' ' + allowed + ' return')
                forwarded.append(media_reply + ' ' + allowed + ' return')
            incoming.append(media_input + ' drop')
            forwarded.append(media_forward + ' drop')
            # SFU-originated ICE traffic creates an outbound NAT mapping. Its
            # reply direction must not bypass the same media source allowlist.
            forwarded.append(media_reply + ' drop')
        # Published-port filtering alone misses directly routed container IPs.
        # Preserve traffic within the trusted core bridge and its reply packets.
        forwarded.append(f'ct direction original oifname "{backend_bridge}" iifname != "{backend_bridge}" drop')
    incoming.append(f'ip daddr {private} drop')
    incoming.append('iifname "wg-vc" drop')
    # Replies retain the connection's original destination, so restricting both
    # conntrack directions here would break every permitted DNAT response.
    forwarded.append(f'ct direction original ct original ip daddr {private} drop')
    # AllowedIPs authenticates the sender, not its destination. A peer must not
    # turn this host into a router to other containers, networks or the Internet.
    forwarded += ['iifname "wg-vc" ct direction reply ct state established,related return',
                  'iifname "wg-vc" drop']
    lines = [f'delete table inet {table}'] if replace else []
    lines += [f'table inet {table} {{', f'  comment "{owner}"']
    for chain, rules in (('input', incoming), ('forward', forwarded)):
        lines += [f'  chain {chain} {{', f'    type filter hook {chain} priority -5; policy accept;']
        lines += ['    ' + rule for rule in rules]
        lines.append('  }')
    return '\n'.join([*lines, '}']) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--node', required=True)
    parser.add_argument('--edge-subnet', default='10.241.0.0/28')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    value = render(node_inventory.load(args.inventory), args.node, args.edge_subnet)
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as output: output.write(value)
    print('Scoped nftables config rendered; no firewall changed.')


if __name__ == '__main__': main()
