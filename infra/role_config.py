"""Independent Compose roles. No Docker/SSH/DNS calls or runtime secret reads."""
from copy import deepcopy
import ipaddress
import json
from pathlib import Path
import re

import node_inventory
import render_edge

ROOT = Path(__file__).resolve().parents[1]
CORE_SERVICES = ('configure', 'postgres', 'synapse', 'control')
LOGGING = {'driver': 'json-file', 'options': {'max-size': '10m', 'max-file': '3'}}


def pinned_image(service):
    source = (ROOT / 'infra/compose.yaml').read_text()
    match = re.search(r'^  ' + re.escape(service) + r':\n    image: (\S+)', source, re.M)
    if not match or not re.fullmatch(r'[a-z0-9._/:-]+@sha256:[a-f0-9]{64}', match[1]):
        raise ValueError('Pinned base image required for ' + service)
    return match[1]


def bind(source, target):
    # Missing files must fail, never become silently-created writable directories.
    return {'type': 'bind', 'source': source, 'target': target, 'read_only': True,
            'bind': {'create_host_path': False}}


def core_base(source):
    """Select complete blocks from our canonical base file, without interpreting YAML.

    Compose interpolates even unused services in an extends file. Keeping web
    there would require WEB_IMAGE/SITE on a data-only host. Reject a changed
    source layout rather than silently dropping part of a service definition.
    """
    _, separator, rest = source.partition('\nservices:\n')
    body, volumes, _ = rest.partition('\nvolumes:\n')
    if not separator or not volumes:
        raise ValueError('Unexpected base Compose layout')
    blocks = re.split(r'(?m)^  ([a-z][a-z0-9-]*):\n', body)
    if blocks[0].strip() or len(blocks) % 2 != 1:
        raise ValueError('Unexpected base service layout')
    selected = {}
    for name, content in zip(blocks[1::2], blocks[2::2]):
        if name in selected: raise ValueError('Duplicate base service')
        if any(line.strip() and not line.startswith('    ') and not line.lstrip().startswith('#')
               for line in content.splitlines()):
            raise ValueError('Unexpected base service indentation')
        selected[name] = content
    if not set(CORE_SERVICES) <= selected.keys(): raise ValueError('Missing core service')
    return 'services:\n' + ''.join('  ' + name + ':\n' + selected[name].rstrip() + '\n' for name in CORE_SERVICES)


def core(public, inventory):
    node_inventory.validate(inventory, public)
    address = inventory['core']['tunnel_ip']
    services = {name: {'extends': {'file': 'compose.yaml', 'service': name},
                       # The media reply ACL owns this UDP range. Keep ephemeral
                       # DNS/client sockets in core containers out of that range.
                       'sysctls': {'net.ipv4.ip_local_reserved_ports': '50300-50400'},
                       'logging': deepcopy(LOGGING)}
                for name in CORE_SERVICES}
    for name in ('postgres', 'synapse', 'control'):
        services[name]['restart'] = 'no'
    services['configure'].update(environment={
        'VOICECHAT_ROUTE_CONFIG': json.dumps(public, separators=(',', ':'), sort_keys=True),
        'PUBLIC_IP': inventory['core']['public_ip'],
        'VOICECHAT_PUSH_GATEWAY_IP': address,
    }, volumes=[bind('./topology.py', '/topology.py'), bind('./client_config.py', '/client_config.py'),
                bind('./node_inventory.py', '/node_inventory.py')])
    services['synapse']['ports'] = [f'{address}:8088:8008']
    # Keep the canonical origin first: push links use the first control origin.
    origins = [public['canonical_origin'], *(value for value in public['web_origins']
                                            if value != public['canonical_origin'])]
    services['control'].update(
        environment={'VOICECHAT_ORIGINS': ','.join(origins),
                     'VOICECHAT_PUSH_GATEWAY_URL': f'http://{address}:8090/_matrix/push/v1/notify'},
        ports=[f'{address}:8090:8090', f'{address}:7880:7880'])
    return {'name': 'voicechat', 'services': services,
            'networks': {'default': {'driver_opts': {
                'com.docker.network.bridge.name': node_inventory.core_bridge(inventory)}}},
            'volumes': {name: {} for name in ('postgres', 'synapse', 'control', 'media-config', 'turn-config')}}


def edge(public, inventory, edge_id, subnet='10.241.0.0/28'):
    node_inventory.validate(inventory, public)
    node = node_inventory.edge_assignment(inventory, edge_id)
    network = ipaddress.ip_network(subnet, strict=True)
    if network.version != 4 or network.prefixlen != 28:
        raise ValueError('An RFC1918 /28 bridge subnet is required')
    node_inventory.ipv4(str(network[1]), tunnel=True)
    nodes = [inventory['core'], *(node_inventory.edge_assignment(inventory, item['id'])
                                 for item in inventory['edges'])]
    if any(ipaddress.ip_address(item['tunnel_ip']) in network for item in nodes):
        raise ValueError('Bridge subnet overlaps a tunnel address')
    ingress_ip, relay_ip = str(network[2]), str(network[4])
    core_ip = inventory['core']['tunnel_ip']
    hardened = {'read_only': True, 'cap_drop': ['ALL'], 'security_opt': ['no-new-privileges:true'],
                'tmpfs': ['/tmp:size=16m,mode=1777'], 'restart': 'no', 'pids_limit': 128}
    services = {
        'configure': {
            'image': pinned_image('configure'), 'entrypoint': ['python3', '/edge_turn.py'],
            'command': ['--public-ip', node['public_ip'], '--relay-ip', relay_ip,
                        '--realm', public['matrix_server_name']],
            'read_only': True, 'tmpfs': ['/tmp:size=16m,mode=1777'], 'security_opt': ['no-new-privileges:true'],
            'volumes': [bind('./edge_turn.py', '/edge_turn.py'), bind('./configure.py', '/configure.py'),
                        bind('./node_inventory.py', '/node_inventory.py'), bind('./topology.py', '/topology.py'),
                        bind('./client_config.py', '/client_config.py'),
                        bind('./runtime/turn-secret', '/run/secrets/turn-secret'), 'turn-config:/turn'],
        },
        'ingress': {
            **deepcopy(hardened), 'image': json.loads((ROOT / 'infra/edge-images.json').read_text())['haproxy'],
            'ports': ['443:8443/tcp'], 'volumes': [bind('./haproxy.cfg', '/usr/local/etc/haproxy/haproxy.cfg')],
            'depends_on': ['web', 'turn'],
        },
        'web': {
            **deepcopy(hardened), 'image': '${WEB_IMAGE:?An immutable web image is required}',
            # The pinned Caddy binary carries this file capability even on 8443.
            'cap_add': ['NET_BIND_SERVICE'],
            'tmpfs': ['/tmp:size=16m,mode=1777', '/data:size=16m', '/config:size=16m'],
            'volumes': [bind('./Caddyfile', '/etc/caddy/Caddyfile'), bind('./runtime/tls/web', '/tls'),
                        bind('./runtime/catalog', '/catalog'),
                        bind('./runtime/android-updates', '/updates/android'), bind('./runtime/macos-updates', '/updates/macos')],
            'depends_on': ['route-health'],
            'healthcheck': {'test': ['CMD', 'wget', '-q', '-O', '/dev/null', 'http://127.0.0.1:8080/health'],
                            'interval': '5s', 'timeout': '3s', 'retries': 10},
        },
        'route-health': {
            **deepcopy(hardened), 'image': pinned_image('configure'), 'user': '10001:10001',
            'entrypoint': ['python3', '/route_health.py'],
            'command': ['--service-id', public['service_id'], '--edge-id', edge_id,
                        '--matrix-url', f'http://{core_ip}:8088', '--control-url', f'http://{core_ip}:8090'],
            'volumes': [bind('./route_health.py', '/route_health.py')],
        },
        'turn': {
            **deepcopy(hardened), 'image': pinned_image('turn'), 'user': '10001:10001',
            'cap_add': ['NET_BIND_SERVICE'], 'command': ['-c', '/config/turnserver.conf'],
            'ports': ['3478:3478/tcp', '3478:3478/udp', '49300-49400:49300-49400/udp'],
            'volumes': ['turn-config:/config:ro', bind('./runtime/tls/turn', '/tls')],
            'depends_on': {'configure': {'condition': 'service_completed_successfully'}},
        },
    }
    entry = next(item for item in inventory['edges'] if item['id'] == edge_id)
    if entry.get('legacy_turn', False):
        # Existing clients may retain Synapse's old :3488 URI for its 1h TTL.
        services['turn']['ports'] += ['3488:3478/tcp', '3488:3478/udp']
    for name, service in services.items():
        service['logging'] = deepcopy(LOGGING)
        service['environment'] = {'PYTHONDONTWRITEBYTECODE': '1'} if name in ('configure', 'route-health') else {}
        slot = {'ingress':2, 'web':3, 'turn':4, 'route-health':5, 'configure':6}[name]
        service['networks'] = {'default': {'ipv4_address': str(network[slot])}}
    compose = {'name': 'voicechat-edge-' + edge_id, 'services': services, 'volumes': {'turn-config': {}},
               # All role addresses are explicit so creation order cannot take
               # the fixed ingress/relay addresses through dynamic allocation.
               'networks': {'default': {
                   'driver_opts': {'com.docker.network.bridge.name': node_inventory.edge_bridge(inventory, edge_id)},
                   'ipam': {'config': [{'subnet': subnet}]}}}}
    shared = node_inventory.shared_tls_profile(inventory, edge_id)
    files = render_edge.render(public, inventory, edge_id, ingress_ip,
                               web_ip=str(network[3]), turn_ip=relay_ip)
    if shared is not None:
        if network.overlaps(ipaddress.ip_network(shared['subnet'])):
            raise ValueError('Shared TLS and edge bridge networks must not overlap')
        # The shared listener must survive a failed VoiceChat network gate so
        # unrelated sites remain reachable. Its bridge also survives edge down.
        ingress = services.pop('ingress')
        ingress.pop('depends_on')
        ingress['restart'] = 'unless-stopped'
        ingress['networks'] = {'edge': {'ipv4_address': ingress_ip},
                               'legacy': {'ipv4_address': shared['ingress_ip']}}
        edge_network = compose['networks']['default']
        edge_network['name'] = compose['name'] + '_default'
        front = {'name': 'voicechat-shared-front', 'services': {'ingress': ingress},
                 'networks': {'edge': edge_network, 'legacy': {
                     'name': shared['network'], 'ipam': {'config': [{'subnet': shared['subnet']}]}}}}
        compose['networks']['default'] = {'external': True, 'name': edge_network['name']}
        files['compose.shared-front.json'] = json.dumps(front, indent=2) + '\n'
    return compose, files
