"""Change one admitted peer on a live host under its owned role fences.

All private WireGuard material stays local. The exact previous and target intents
are compared under the network lock, including on retry after a lost response.
"""
from contextlib import ExitStack
from pathlib import Path

import host_registration
import managed_fence
import managed_state
import network_bootstrap
import network_runtime
import node_inventory
import role_deploy
import role_release
from tunnel_config import physical_nodes
from tunnel_runtime import command


def local_roles(root, inventory, node):
    if node == 'core':
        return [root / 'core', *(root / 'edges' / edge['id'] for edge in inventory['edges']
                               if edge.get('host') == 'core')]
    return [root / 'edges' / node.removeprefix('edge-')]


def transition(root, previous_inventory, inventory, previous_keys, identity, node, attempt, *,
               subnet='10.241.0.0/28', system_root=Path('/'), run=command):
    root = Path(root).absolute()
    if root.resolve() != root or not root.is_dir():
        raise ValueError('Existing canonical role installation required')
    if not isinstance(attempt, str) or not role_release.SHA.fullmatch(attempt):
        raise ValueError('Exact lifecycle maintenance owner required')
    keys = host_registration.registry(previous_inventory, inventory, previous_keys, identity)
    before_nodes, after_nodes = physical_nodes(previous_inventory), physical_nodes(inventory)
    if node not in before_nodes or before_nodes[node] != after_nodes.get(node):
        raise ValueError('Live peer transition must preserve the local host')
    host = network_bootstrap.existing(system_root / 'etc/ssh/ssh_host_ed25519_key.pub')
    if host is None or node_inventory.host_key(' '.join(host.decode().split()[:2])) != before_nodes[node]['ssh_host_key']:
        raise ValueError('Peer transition belongs to another SSH host')
    network = system_root / 'var/lib/voicechat-network'
    with ExitStack() as locks:
        for role_root in sorted(local_roles(root, previous_inventory, node)):
            locks.enter_context(managed_state.locked(role_root))
            intent = role_deploy.managed_operation(role_root)
            if (intent is None or intent['attempt'] != attempt or intent['phase'] != 'held' or
                    intent['before'] != intent['target'] or intent['active'] != intent['before']):
                raise ValueError('Claim every local role unchanged before replacing its peer')
            role_deploy.require_rollout_owner(role_root, attempt, intent['active'])
            managed_fence._committed(role_root, intent['before'])
            if intent['before']['node_sha256'] != role_release.json_digest(
                    before_nodes[node] if node == 'core' and intent['before']['role'] == 'core'
                    else node_inventory.edge_assignment(previous_inventory, intent['before']['edge_id'])):
                raise ValueError('Role fence belongs to another host assignment')
        desired = managed_state.read(network / 'desired.json')
        before = {**desired, 'inventory': previous_inventory, 'public_keys': previous_keys,
                  'node': node, 'edge_subnet': subnet}
        target = {**before, 'inventory': inventory, 'public_keys': keys}
        # Private key is taken from the local intent, never an operator payload.
        network_runtime.components(before)
        network_runtime.components(target)
        network_runtime.reconcile(network, target, run=run, expected=(before, target))
        network_bootstrap.upgrade(system_root, run=run)
    return {'schema': 1, 'node': node, 'attempt': attempt,
            'network_sha256': network_runtime.fingerprint(target),
            'retired_peer_removed': identity['node'] in previous_keys['nodes'],
            'private_key_exported': False}
