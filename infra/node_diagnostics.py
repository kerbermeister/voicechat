"""Read-only, content-free operator checks on one physical VoiceChat node.

TLS and API checks do not prove WSS signaling or a decrypted TURN/media flow.
No profile, environment, database or container log is read. Private network
intent is checked locally; keys and raw subprocess output never enter the report.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import time
from urllib.parse import urlsplit

import core_deploy
import edge_deploy
import firewall_runtime
import managed_release
import managed_state
import network_bootstrap
import node_inventory
import role_deploy
import route_health
import topology
import tunnel_config
import tunnel_runtime
import network_runtime


def check(operation):
    try:
        value = operation()
        return {'status': 'passed' if value is True else 'failed'}
    except Exception:
        # Exception text can include private URLs or subprocess output.
        return {'status': 'failed'}


def tls(address, hostname, *, now=None):
    context = ssl.create_default_context()
    with socket.create_connection((address, 443), timeout=5) as raw:
        with context.wrap_socket(raw, server_hostname=hostname) as stream:
            certificate = stream.getpeercert()
    remaining = ssl.cert_time_to_seconds(certificate['notAfter']) - (time.time() if now is None else now)
    return {'status': 'passed' if remaining > 0 else 'failed',
            'expires_in_days': int(remaining // 86400), 'renewal_due': remaining < 7 * 86400}


def network(inventory, node, subnet, directory=Path('/var/lib/voicechat-network')):
    # An inspection must not create an unclaimed network directory or lock.
    if not directory.is_dir() or directory.resolve() != directory or not (directory / 'apply.lock').is_file():
        return False
    with role_deploy.network_ready(inventory, node, subnet, directory=directory):
        desired = managed_state.read(directory / 'desired.json')
        firewall, tunnel = network_runtime.components(desired)
        exists, targets, routes, local = tunnel_runtime.inspect(tunnel, owned=True)
        if not exists or targets != routes or not firewall_runtime.inspect(firewall, owned=True, run=tunnel_runtime.command):
            return False
        peers = tunnel_runtime.command('wg', 'show', 'wg-vc', 'peers').split()
        expected = {value['public_key'] for name, value in desired['public_keys']['nodes'].items()
                    if name != node and (node == 'core' or name == 'core')}
        addresses = json.loads(tunnel_runtime.command('ip', '-j', '-4', 'address', 'show', 'dev', 'wg-vc'))
        return (set(peers) == expected and any(address.get('local') == local
                for item in addresses for address in item.get('addr_info', [])))


def processes(root, module, identifier=None):
    try:
        state = module.read_state(root) if identifier is None else module.read_state(root, identifier)
        if state['current'] is None or state['pending'] is not None:
            return {'status': 'failed'}
        manifest = state['current']['manifest']
        sockets = ('unix:///var/run/docker.sock', 'unix:///run/docker.sock')
        if os.environ.get('DOCKER_HOST') not in (None, '', *sockets):
            return {'status': 'failed'}
        endpoint = role_deploy.run(['docker', 'context', 'inspect', '--format',
                                   '{{(index .Endpoints "docker").Host}}']).decode().strip()
        if endpoint not in sockets:
            return {'status': 'failed'}
        running = bool(managed_release.process_snapshot(root, state['current']))
        return {'status': 'passed' if running else 'failed', 'commit': manifest['commit']}
    except Exception:
        return {'status': 'failed'}


def report(root, public, inventory, node, *, subnet='10.241.0.0/28'):
    root = Path(root).absolute()
    node_inventory.validate(inventory, public)
    nodes = tunnel_config.physical_nodes(inventory)
    if node not in nodes:
        raise ValueError('Known physical node required')
    firewall_runtime.validate({'schema':1,'inventory':inventory,'node':node,'edge_subnet':subnet})
    if (root.resolve() != root or not root.is_dir() or root.stat().st_uid != os.geteuid()
            or root.stat().st_mode & 0o077):
        raise ValueError('Existing private canonical managed root required')
    host = network_bootstrap.existing(Path('/etc/ssh/ssh_host_ed25519_key.pub'))
    if host is None or ' '.join(host.decode().split()[:2]) != nodes[node]['ssh_host_key']:
        raise ValueError('Diagnostic target differs from the verified SSH host')
    checks = {'network': check(lambda: network(inventory, node, subnet))}
    address = inventory['core']['tunnel_ip']
    checks['matrix'] = check(lambda: route_health.upstream_ready(
        'http://' + address + ':8088/_matrix/client/versions', 'matrix'))
    checks['control'] = check(lambda: route_health.upstream_ready('http://' + address + ':8090/health', 'control'))
    if node == 'core':
        checks['core_processes'] = processes(root / 'core', core_deploy)
    for edge in public['edges']:
        assignment = next(item for item in inventory['edges'] if item['id'] == edge['id'])
        physical = 'core' if assignment.get('host') == 'core' else 'edge-' + edge['id']
        if physical != node:
            continue
        identifier = edge['id']
        checks['edge_' + identifier + '_processes'] = processes(root / 'edges' / identifier, edge_deploy, identifier)
        for service, hostname in (('web', urlsplit(edge['origin']).hostname), ('turn', edge['turn_host'])):
            try:
                value = tls(nodes[node]['public_ip'], hostname)
            except Exception:
                value = {'status': 'failed'}
            checks['edge_' + identifier + '_' + service + '_tls'] = value
    try:
        free = shutil.disk_usage(root).free
        checks['disk'] = {'status': 'passed' if free >= 2 * 1024**3 else 'failed', 'free_bytes': free}
    except OSError:
        checks['disk'] = {'status': 'failed'}
    return {'schema': 1, 'service_id': public['service_id'], 'node': node,
            'generation': nodes[node]['generation'], 'checked_at': int(time.time()),
            'checks': checks, 'available_checks_passed': all(value['status'] == 'passed' for value in checks.values()),
            'not_checked': ['authenticated_wss', 'turn_allocation_and_media', 'media_decryption', 'external_reachability', 'firewall_rule_equivalence'],
            'scope': 'Node-local network, process, upstream, trusted TLS and free-space checks only'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--topology', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--node', required=True)
    parser.add_argument('--edge-subnet', default='10.241.0.0/28')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run node-local inspection as root')
    value = report(args.root, topology.load(args.topology), node_inventory.load(args.inventory),
                   args.node, subnet=args.edge_subnet)
    print(json.dumps(value, sort_keys=True))
    raise SystemExit(0 if value['available_checks_passed'] else 1)


if __name__ == '__main__':
    main()
