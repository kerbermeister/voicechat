"""Read-only checks before initial role installation on a clean Linux host.

Run on the destination through already verified SSH. This is not a migration or
an installer: occupied project ports also block until a separate rollout handles
their current owner. Never stop services or accept an unknown host key here.
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

import node_inventory
from tunnel_config import physical_nodes


def command(arguments):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=15, check=True)
    if len(result.stdout) > 1024 * 1024:
        raise ValueError('Host inspection output is too large')
    return result.stdout.decode('utf-8')


def listeners(text):
    """Parse ss -H -lntu (no process names/arguments or credentials)."""
    result = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 6 or parts[0] not in ('tcp', 'udp'):
            raise ValueError('Unexpected socket listing')
        address, separator, port = parts[4].rpartition(':')
        if not separator or not address or not port.isascii() or not port.isdigit():
            raise ValueError('Unexpected listening address')
        number = int(port)
        if not 1 <= number <= 65535:
            raise ValueError('Invalid listening port')
        result.append({'protocol': parts[0], 'port': number})
    return result


def collect(disk_path):
    """Collect only public host facts; failed inspection is never an empty result."""
    facts = {'system': platform.system(), 'machine': platform.machine(),
             'uid': os.geteuid(), 'errors': [], 'ports': [], 'networks': [], 'links': [],
             'tools': {name: shutil.which(name) is not None for name in
                       ('docker', 'wg', 'wg-quick', 'openssl', 'ip', 'ss')}}
    if facts['system'] != 'Linux':
        return facts

    def attempt(name, operation):
        try:
            return operation()
        except (OSError, ValueError, KeyError, IndexError, TypeError, StopIteration, subprocess.SubprocessError):
            # Do not print subprocess output: Docker/system tools can contain
            # unrelated host details. A named failed check is enough to fail shut.
            facts['errors'].append(name)
            return None

    facts['os'] = attempt('os-release', platform.freedesktop_os_release)
    facts['disk_free'] = attempt('disk space', lambda: shutil.disk_usage(disk_path).free)
    facts['memory'] = attempt('memory', lambda: int(next(
        line.split()[1] for line in Path('/proc/meminfo').read_text().splitlines()
        if line.startswith('MemTotal:'))) * 1024)
    facts['host_key'] = attempt('SSH public host key', lambda: ' '.join(
        Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2]))
    facts['systemd'] = attempt('systemd', lambda: command([
        'systemctl', 'show', '--property=SystemState', '--value']).strip())
    facts['ntp'] = attempt('clock synchronization', lambda: command([
        'timedatectl', 'show', '--property=NTPSynchronized', '--value']).strip() == 'yes')
    sockets = attempt('listening sockets', lambda: listeners(command(['ss', '-H', '-lntu'])))
    if sockets is not None:
        facts['ports'].extend(sockets)
    links = attempt('network interfaces', lambda: [item['ifname'] for item in
                    json.loads(command(['ip', '-j', 'link', 'show']))])
    if links is not None:
        facts['links'] = links
    routes = attempt('IPv4 routes', lambda: json.loads(command(['ip', '-j', '-4', 'route', 'show', 'table', 'all'])))
    if routes is not None:
        parsed = attempt('IPv4 route networks', lambda: [str(ipaddress.ip_network(
            route['dst'], strict=False)) for route in routes if route.get('dst', 'default') != 'default'])
        if parsed is not None:
            facts['networks'].extend(parsed)
    if facts['tools']['docker']:
        facts['compose'] = attempt('Docker Compose', lambda: command(['docker', 'compose', 'version', '--short']).strip())
        networks = attempt('Docker networks', lambda: command(['docker', 'network', 'ls', '-q']).split())
        if networks:
            def docker_networks():
                output = command(['docker', 'network', 'inspect', '--format', '{{json .IPAM.Config}}', *networks])
                return [str(ipaddress.ip_network(item['Subnet'], strict=False))
                        for line in output.splitlines() for item in (json.loads(line) or []) if 'Subnet' in item]
            found = attempt('Docker network subnets', docker_networks)
            if found is not None:
                facts['networks'].extend(found)
        containers = attempt('running Docker containers', lambda: command(['docker', 'ps', '-q']).split())
        if containers:
            def docker_ports():
                # Docker DNAT can publish ports without a host listening socket.
                output = command(['docker', 'inspect', '--format', '{{json .NetworkSettings.Ports}}', *containers])
                return [{'protocol': key.split('/')[1], 'port': int(binding['HostPort'])}
                        for line in output.splitlines() for key, bindings in (json.loads(line) or {}).items()
                        for binding in (bindings or [])]
            found = attempt('Docker published ports', docker_ports)
            if found is not None:
                facts['ports'].extend(found)
    return facts


def evaluate(inventory, identity, facts, subnet='10.241.0.0/28'):
    nodes = physical_nodes(inventory)
    if identity not in nodes:
        raise ValueError('Select a physical node (co-located edge uses core)')
    bridge = ipaddress.ip_network(subnet, strict=True)
    if bridge.version != 4 or bridge.prefixlen != 28:
        raise ValueError('An RFC1918 /28 edge bridge is required')
    node_inventory.ipv4(str(bridge[1]), tunnel=True)
    has_core = identity == 'core'
    has_edge = not has_core or any(edge.get('host') == 'core' for edge in inventory['edges'])
    blockers = []
    warnings = []
    if facts['system'] != 'Linux':
        blockers.append('A Linux destination is required; no host changes performed')
    else:
        blockers.extend('Inspection failed: ' + name for name in facts['errors'])
        release = facts.get('os') or {}
        if (release.get('ID'), release.get('VERSION_ID')) != ('debian', '12'):
            blockers.append('The initial clean-host profile is Debian 12; other hosts need separate adaptation')
        if facts['machine'] != 'x86_64':
            blockers.append('The initial clean-host profile requires amd64')
        if facts['uid'] != 0:
            blockers.append('Run the read-only inspection as root to inspect all host resources')
        if facts.get('host_key') != nodes[identity]['ssh_host_key']:
            blockers.append('Local SSH host key does not match the verified inventory')
        if facts.get('systemd') not in ('running', 'degraded'):
            blockers.append('An active systemd host is required')
        elif facts['systemd'] == 'degraded':
            blockers.append('Resolve failed systemd units before installing a new role')
        if facts.get('ntp') is not True:
            blockers.append('Clock synchronization must be confirmed')
        if (facts.get('memory') or 0) <= 0:
            blockers.append('Available host memory could not be determined')
        elif facts['memory'] < (4 if has_core else 2) * 1024**3:
            warnings.append('Review memory capacity: below 4 GiB core / 2 GiB edge recommendation')
        # Reuse the existing deployment free-space floor. Capacity for images,
        # user data and consistent backups still needs a workload-specific check.
        if (facts.get('disk_free') or 0) < 2 * 1024**3:
            blockers.append('At least 2 GiB free space is required before installation')
        elif facts['disk_free'] < (20 if has_core else 10) * 1024**3:
            warnings.append('Review disk capacity: below 20 GiB core / 10 GiB edge recommendation')

        required = {'tcp': set(), 'udp': {51820}}
        if has_core:
            required['tcp'].update((7880, 7981, 8088, 8090))
            required['udp'].update(range(50300, 50401))
        if has_edge:
            required['tcp'].update((443, 3478))
            required['udp'].update((3478, *range(49300, 49401)))
        # A custom SSH listener must never be displaced by a role port.
        ports = [*facts['ports'], {'protocol': 'tcp', 'port': inventory['ssh_port']}]
        conflicts = {(item['protocol'], item['port']) for item in ports
                     if item['port'] in required.get(item['protocol'], ())}
        blockers.extend(f'Port already reserved: {proto}/{port}' for proto, port in sorted(conflicts))
        targets = [ipaddress.ip_network(node['tunnel_ip'] + '/32') for node in nodes.values()]
        if has_edge:
            targets.append(bridge)
        if any(ipaddress.ip_address(node['tunnel_ip']) in bridge for node in nodes.values()):
            blockers.append('Edge bridge overlaps an inventory tunnel address')
        if has_edge:
            edge_id = next(edge['id'] for edge in inventory['edges']
                           if (has_core and edge.get('host') == 'core') or identity == 'edge-' + edge['id'])
            if node_inventory.edge_bridge(inventory, edge_id) in facts['links']:
                blockers.append('Planned edge bridge interface already exists')
        if has_core and node_inventory.core_bridge(inventory) in facts['links']:
            blockers.append('Planned core bridge interface already exists')
        for existing in sorted(set(facts['networks'])):
            network = ipaddress.ip_network(existing, strict=False)
            if network.version == 4 and network.prefixlen and any(network.overlaps(target) for target in targets):
                blockers.append('Existing route/network overlaps planned addressing: ' + existing)
        missing = [name for name, exists in facts['tools'].items() if not exists]
        if missing:
            warnings.append('Dependencies still need installation: ' + ', '.join(missing))
        if facts['tools']['docker'] and not facts.get('compose'):
            blockers.append('Installed Docker requires a working Compose plugin')
    return {'schema': 1, 'service_id': inventory['service_id'], 'node': identity,
            'generation': nodes[identity]['generation'], 'ready_for_initial_install': not blockers,
            'blockers': blockers, 'warnings': warnings,
            'scope': 'Read-only clean-host inspection; no installer, migration, firewall or external reachability proof'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--node', required=True)
    parser.add_argument('--disk-path', type=Path, default=Path('/var/lib'))
    parser.add_argument('--edge-subnet', default='10.241.0.0/28')
    args = parser.parse_args()
    inventory = node_inventory.load(args.inventory)
    # Validate the target before collecting any host facts.
    if args.node not in physical_nodes(inventory):
        parser.error('Select a physical node from inventory')
    report = evaluate(inventory, args.node, collect(args.disk_path), args.edge_subnet)
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report['ready_for_initial_install'] else 1)


if __name__ == '__main__':
    main()
