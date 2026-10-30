"""Validate one entry admission/replacement before contacting any host.

Ordinary releases cannot change physical assignments. This separate plan keeps
installation identity, unaffected hosts and application images fixed. Execution
must prove each step; a plan alone is never a deployment receipt.
"""
from copy import deepcopy

import managed_release
import node_inventory
import role_release
import topology
from tunnel_config import physical_nodes


def change(previous_public, previous, public, inventory):
    node_inventory.validate(previous, previous_public)
    node_inventory.validate(inventory, public)
    node_inventory.check_replacement(previous, inventory)
    if any(inventory[key] != previous[key] for key in
           ('schema', 'service_id', 'ssh_user', 'ssh_port', 'core')):
        raise ValueError('Entry lifecycle cannot move the core or change SSH policy')
    before, after = physical_nodes(previous), physical_nodes(inventory)
    changed = [name for name in after if after[name] != before.get(name)]
    if set(before) - set(after) or len(changed) != 1 or changed[0] == 'core':
        raise ValueError('Change exactly one new or replaced dedicated entry host')
    node = changed[0]
    identifier = node.removeprefix('edge-')
    old_edges = {edge['id']: edge for edge in previous['edges']}
    new_edges = {edge['id']: edge for edge in inventory['edges']}
    if set(new_edges) - set(old_edges) not in (set(), {identifier}):
        raise ValueError('Only the selected entry may be added')
    if any(new_edges.get(key) != value for key, value in old_edges.items() if key != identifier):
        raise ValueError('Unrelated entry assignment changed')
    replacement = identifier in old_edges
    if replacement:
        if 'host' in old_edges[identifier]:
            raise ValueError('Moving a cohost entry needs its own migration')
        if after[node]['tunnel_ip'] != before[node]['tunnel_ip']:
            raise ValueError('Replacement must retain its private entry address')
        if public != previous_public:
            raise ValueError('Replacement must retain public names and catalog topology')
        if len(old_edges) < 2:
            raise ValueError('Replacement requires another healthy entry')
    else:
        old_public = previous_public
        if any(public[key] != old_public[key] for key in public if key not in ('edges', 'web_origins')):
            raise ValueError('Entry admission cannot change installation identity or policy')
        if (public['edges'] != [*old_public['edges'], next(edge for edge in public['edges'] if edge['id'] == identifier)] or
                public['web_origins'] not in (old_public['web_origins'],
                    [*old_public['web_origins'], public['edges'][-1]['origin']])):
            raise ValueError('Append only the new entry and its optional web origin')
    # New generations may not reuse an old SSH identity, including a retired key
    # belonging to another active node. validate() enforces uniqueness in after.
    if after[node]['ssh_host_key'] in {value['ssh_host_key'] for value in before.values()}:
        raise ValueError('A clean entry needs a fresh verified SSH host key')
    return {'node': node, 'edge_id': identifier, 'replacement': replacement}


def plan(baseline, public, inventory, commit, web_image):
    managed_release.validate_baseline(baseline)
    transition = change(baseline['public'], baseline['inventory'], public, inventory)
    node, identifier, replacement = (transition[key] for key in ('node', 'edge_id', 'replacement'))
    old_edges = {edge['id']: edge for edge in baseline['inventory']['edges']}
    after = physical_nodes(inventory)
    images = {value['images']['web'] for value in baseline['edges'].values()}
    if web_image not in images:
        raise ValueError('Admission must reuse an installed immutable web image')
    current = {'core': baseline['core'], **{'edge-' + key: value for key, value in baseline['edges'].items()}}
    targets = {}
    for name in ('core', *('edge-' + edge['id'] for edge in public['edges'])):
        old = current.get(name)
        role, edge_id = ('core', None) if name == 'core' else ('edge', name.removeprefix('edge-'))
        image = baseline['core']['images']['control'] if role == 'core' else old['images']['web'] if old else web_image
        comparable = role_release.make(public, inventory, role, old['commit'] if old else commit,
                                       image, edge_id, baseline['subnet'])
        targets[name] = old if comparable == old else role_release.make(
            public, inventory, role, commit, image, edge_id, baseline['subnet'])
    target = deepcopy(baseline)
    target.update(public=deepcopy(public), inventory=deepcopy(inventory), core=targets['core'],
                  edges={edge['id']: targets['edge-' + edge['id']] for edge in public['edges']})
    managed_release.validate_baseline(target)
    return {'schema': 1, 'operation': 'replace' if replacement else 'add', 'node': node,
            'edge_id': identifier, 'baseline': role_release.json_digest(baseline),
            'target': target, 'surviving_edges': sorted(set(old_edges) - {identifier}),
            'network_nodes': list(after),
            'reconfigure': [name for name in targets if name != node and targets[name] != current.get(name)],
            'rotate_turn_secret': replacement}


def steps(value):
    """Order public exposure after readiness; revocation is never rolled back."""
    node = value['node']
    sequence = [('prepare', node), ('identity', node), ('register', 'core'),
                ('network', node), ('tls', node), ('stage', node)]
    sequence += [('claim', name) for name in value['network_nodes'] if name != node]
    sequence += [('network', name) for name in value['network_nodes'] if name != node]
    if value['rotate_turn_secret']:
        sequence += [('rotate-turn', name) for name in value['network_nodes'] if name != node]
    sequence += [('configure', name) for name in value['reconfigure']]
    sequence += [('start', node), ('verify', node)]
    sequence += [('verify-turn', 'edge-' + edge['id']) for edge in value['target']['public']['edges']
                 if value['rotate_turn_secret'] or edge['id'] == value['edge_id']]
    sequence += [('dns', node), ('verify-dns', node),
                 ('catalog', 'core'), ('commit', 'core')]
    sequence += [('release', name) for name in value['network_nodes'] if name != node]
    sequence.append(('finish', 'core'))
    return [{'action': action, 'node': name} for action, name in sequence]


def role_ids(inventory, node):
    if node not in physical_nodes(inventory):
        raise ValueError('Known physical node required')
    if node == 'core':
        return ['core', *('edge-' + edge['id'] for edge in inventory['edges'] if edge.get('host') == 'core')]
    return [node]
