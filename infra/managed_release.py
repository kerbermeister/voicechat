"""Conservative release planning from a typed, per-role production baseline.

Planning and inspection never publish catalogs or change release pointers.
Explicit baseline storage writes bounded immutable objects only. The caller must
obtain the baseline from verified role state on pinned hosts.
"""
from copy import deepcopy
import argparse
import hashlib
import json
from pathlib import Path

import core_deploy
import edge_deploy
import managed_state
import network_bootstrap
import role_bootstrap
import role_deploy
from tunnel_runtime import command
import re

import node_inventory
import role_release
import topology


def validate_baseline(value):
    topology.fields(value, ('schema', 'backend', 'public', 'inventory', 'subnet', 'core', 'edges'))
    if type(value['schema']) is not int or value['schema'] != 1:
        raise ValueError('Typed managed baseline required')
    if not isinstance(value['backend'], str) or not role_release.SHA.fullmatch(value['backend']):
        raise ValueError('Recorded backend fingerprint required')
    topology.validate(value['public']); node_inventory.validate(value['inventory'], value['public'])
    role_release.validate(value['core'])
    if value['core']['role'] != 'core': raise ValueError('Core baseline required')
    ids = {edge['id'] for edge in value['public']['edges']}
    if not isinstance(value['edges'], dict) or value['edges'].keys() != ids:
        raise ValueError('Complete per-edge baseline required')
    for identifier, manifest in value['edges'].items():
        role_release.validate(manifest)
        if manifest['edge_id'] != identifier: raise ValueError('Baseline edge identity mismatch')
        role_release.require_compatible(value['core'], manifest)
        # The existing renderer validates bridge subnet/host overlap. Do not
        # compare its current source files with an older recorded bundle here.
        role_release.make(value['public'], value['inventory'], 'edge', manifest['commit'],
                          manifest['images']['web'], identifier, value['subnet'])
    identity = {'canonical_origin': value['public']['canonical_origin'],
                'matrix_server_name': value['public']['matrix_server_name']}
    if value['core']['identity'] != identity or value['core']['service_id'] != value['public']['service_id']:
        raise ValueError('Baseline belongs to another installation')
    if value['core']['node_sha256'] != role_release.json_digest(value['inventory']['core']):
        raise ValueError('Core baseline host assignment changed')
    for identifier, manifest in value['edges'].items():
        if manifest['node_sha256'] != role_release.json_digest(node_inventory.edge_assignment(value['inventory'],identifier)):
            raise ValueError('Edge baseline host assignment changed')
    return value


def from_initial(current):
    """Read the first adoption pointer without disguising it as legacy current."""
    topology.fields(current, ('schema', 'kind', 'target', 'core_root', 'edge_root', 'data_identity', 'legacy_root'))
    if type(current['schema']) is not int or current['schema'] != 1 or current['kind'] != 'roles':
        raise ValueError('Initial role pointer required')
    target = current['target']
    identifier = target['edge']['edge_id']
    return validate_baseline({'schema':1, 'backend':target['backend_sha256'],
        'public':deepcopy(target['public']), 'inventory':deepcopy(target['inventory']),
        'subnet':target['subnet'], 'core':deepcopy(target['core']),
        'edges':{identifier:deepcopy(target['edge'])}})


def _baseline_object(directory, checksum):
    if not isinstance(checksum, str) or not role_release.SHA.fullmatch(checksum):
        raise ValueError('Content-addressed baseline object required')
    value = managed_state.read(directory / (checksum + '.json'))
    if role_release.json_digest(value) != checksum:
        raise ValueError('Immutable baseline object changed')
    return value


def store_baseline(root, baseline):
    """Keep each bounded role/config object once, with a small immutable index.

    A complete 32-edge baseline exceeds the managed JSON boundary. References
    preserve that boundary and mixed role revisions without copying manifests
    into every journal step. This does not change any production pointer.
    """
    validate_baseline(baseline)
    root = Path(root).absolute()
    if root.resolve() != root or not root.is_dir():
        raise ValueError('Existing canonical managed root required')
    with managed_state.locked(root / 'baselines') as directory:
        def store(value):
            checksum = role_release.json_digest(value)
            path = directory / (checksum + '.json')
            if path.exists() or path.is_symlink():
                if _baseline_object(directory, checksum) != value:
                    raise ValueError('Immutable baseline object collision')
            else:
                managed_state.persist(path, value)
            return checksum
        index = {key: baseline[key] for key in ('schema', 'backend', 'subnet')}
        index.update({key: store(baseline[key]) for key in ('public', 'inventory', 'core')})
        index['edges'] = {identifier: store(manifest) for identifier, manifest in baseline['edges'].items()}
        return store(index)


def load_baseline(root, checksum):
    root = Path(root).absolute()
    if root.resolve() != root or not root.is_dir():
        raise ValueError('Existing canonical managed root required')
    directory = root / 'baselines'
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Existing immutable baseline storage required')
    with managed_state.locked(directory):
        value = _baseline_object(directory, checksum)
        topology.fields(value, ('schema', 'backend', 'public', 'inventory', 'subnet', 'core', 'edges'))
        if not isinstance(value['edges'], dict) or not 1 <= len(value['edges']) <= 32:
            raise ValueError('Complete bounded edge baseline index required')
        return validate_baseline({**value,
            **{key: _baseline_object(directory, value[key]) for key in ('public', 'inventory', 'core')},
            'edges': {identifier: _baseline_object(directory, item) for identifier, item in value['edges'].items()}})


def plan(baseline, candidate, backend, *, scope='full', edges=None):
    """Select immutable targets, preserving unselected/mixed-version roles.

    A core build reuses every installed web image. Edge/web never rebuild a core
    manifest with a new commit. Source/config changes outside the selected scope
    fail before deployment. Network/topology replacement is a separate operation.
    """
    validate_baseline(baseline)
    topology.fields(candidate, ('schema', 'commit', 'origin', 'control', 'web'))
    if (type(candidate['schema']) is not int or candidate['schema'] != 1 or
            not isinstance(candidate['commit'], str) or not re.fullmatch(r'[a-f0-9]{40}', candidate['commit']) or
            any(not isinstance(candidate[name], str) or not re.fullmatch(r'ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}',candidate[name]) for name in ('control','web'))):
        raise ValueError('Immutable candidate required')
    if candidate['origin'] != baseline['public']['canonical_origin']:
        raise ValueError('Candidate belongs to another origin')
    if scope not in ('web', 'edge', 'core', 'full'): raise ValueError('Unknown managed release scope')
    if not isinstance(backend,str) or not role_release.SHA.fullmatch(backend):
        raise ValueError('Build-generated backend fingerprint required')
    ids = [edge['id'] for edge in baseline['public']['edges']]
    selected = ids if edges is None else list(edges)
    if (not selected or len(set(selected)) != len(selected) or any(item not in ids for item in selected)):
        raise ValueError('Choose distinct known edge IDs')
    if scope in ('core','full') and (edges is not None and selected != ids):
        raise ValueError('Core/full requires the complete edge baseline')
    if scope in ('web','edge') and backend != baseline['backend']:
        raise ValueError('Protected backend sources changed; use full release')
    public, inventory, subnet = baseline['public'], baseline['inventory'], baseline['subnet']
    old_core = baseline['core']
    core = role_release.make(public,inventory,'core',candidate['commit'],candidate['control'],subnet=subnet) if scope in ('core','full') else deepcopy(old_core)
    if scope in ('web','edge'):
        if candidate['control'] != old_core['images']['control']:
            raise ValueError('Edge/web must reuse the deployed control digest')
        reconstructed = role_release.make(public,inventory,'core',old_core['commit'],old_core['images']['control'],subnet=subnet)
        if reconstructed != old_core:
            raise ValueError('Core configuration changed outside the requested scope')
    if any(core['images'][name] != old_core['images'][name] for name in ('postgres','synapse')):
        raise ValueError('Database engine upgrade requires an explicit migration')
    targets = deepcopy(baseline['edges'])
    for identifier in ids:
        old = baseline['edges'][identifier]
        if scope == 'core':
            reconstructed = role_release.make(public,inventory,'edge',old['commit'],old['images']['web'],identifier,subnet)
            if reconstructed != old:
                raise ValueError('Edge configuration changed outside the core scope')
        elif identifier in selected:
            target = role_release.make(public,inventory,'edge',candidate['commit'],candidate['web'],identifier,subnet)
            if scope == 'web': role_release.require_web_only(old,target)
            targets[identifier] = target
        # Both directions must work during staged updates and rollback. A
        # contract-breaking migration cannot be hidden in an ordinary full run.
        role_release.require_compatible(core,old)
        role_release.require_compatible(old_core,targets[identifier])
        role_release.require_compatible(core,targets[identifier])
    steps = ([{'role':'core','edge_id':None}] if scope in ('core','full') else [])
    if scope != 'core': steps += [{'role':'edge','edge_id':identifier} for identifier in selected]
    return {'schema':1, 'scope':scope, 'baseline':role_release.json_digest(baseline),
            'backend':backend, 'core':core, 'edges':targets, 'steps':steps}


def process_snapshot(root, record, *, execute=role_deploy.run):
    role = record['manifest']['role']
    services = ['postgres','synapse','control'] if role == 'core' else sorted(set(record['manifest']['images'])-{'configure'})
    compose = core_deploy.compose if role == 'core' else edge_deploy.compose
    identifiers = compose(root,record,'ps','-q',*services,execute=execute).decode().split()
    if len(identifiers) != len(services): raise ValueError('Committed services are missing')
    rows = execute(['docker','inspect','--format',
        '{{.Id}} {{.State.Running}} {{.State.StartedAt}} {{.RestartCount}}',*identifiers]).decode().splitlines()
    if len(rows) != len(services) or any(not re.fullmatch(r'[a-f0-9]{64} true [^ ]+ [0-9]+',row) for row in rows):
        raise ValueError('Committed services are not running')
    return sorted(rows)


def inspect_role(root, public, inventory, manifest, *, subnet='10.241.0.0/28',
                 system_root=Path('/'), execute=role_deploy.run, run=command,
                 rollout_attempt=None, rollout_manifest=None):
    """Inspect one actual pinned host; return only bounded public facts/hashes.

    Role/network locks reject concurrent deployment, backup and replacement.
    Historical boot sources are verified by their receipt; merely installing a
    new CI source bundle does not turn it into the committed boot operator.
    Only the exact maintenance owner may inspect the previous committed role
    while its fence already names the candidate target; default reads still fail.
    """
    role_release.validate(manifest)
    role_release.verify_configuration(manifest,public,inventory)
    if (rollout_attempt is None) != (rollout_manifest is None):
        raise ValueError('Maintenance inspection needs both attempt and target manifest')
    if rollout_manifest is not None:
        role_release.verify_configuration(rollout_manifest,public,inventory)
        if any(rollout_manifest[key] != manifest[key] for key in
               ('role','edge_id','service_id','identity','contracts','node_sha256','topology_sha256')):
            raise ValueError('Maintenance inspection target belongs to another role')
    root, system_root = Path(root).absolute(), Path(system_root).resolve()
    if root.resolve()!=root or not root.is_dir():raise ValueError('Existing canonical role root required')
    role, identifier = manifest['role'], manifest['edge_id']
    node = inventory['core'] if role == 'core' else node_inventory.edge_assignment(inventory,identifier)
    host = network_bootstrap.existing(system_root/'etc/ssh/ssh_host_ed25519_key.pub')
    if host is None or node_inventory.host_key(' '.join(host.decode().split()[:2])) != node['ssh_host_key']:
        raise ValueError('Role baseline belongs to another SSH host')
    network = (role_deploy.network_ready(inventory,'core',subnet,execute=execute,
                   directory=system_root/'var/lib/voicechat-network') if role=='core' else
               edge_deploy.network_ready(inventory,identifier,subnet,execute=execute,
                   directory=system_root/'var/lib/voicechat-network'))
    with managed_state.locked(root), network:
        role_deploy.require_rollout_owner(root, rollout_attempt, rollout_manifest)
        owner = managed_state.read(root/'role.json')
        expected = {key:manifest[key] for key in ('schema','service_id','role','edge_id','identity')}
        if owner != expected: raise ValueError('Role ownership differs from the baseline')
        state = core_deploy.read_state(root) if role=='core' else edge_deploy.read_state(root,identifier)
        current = state['current']
        if current is None or state['pending'] is not None or current['manifest'] != manifest:
            raise ValueError('Baseline requires the exact committed role without a pending release')
        role_deploy.release_path(root,current)
        if role=='core':core_deploy.require_no_backup(root)
        receipt = managed_state.read(root/'runtime/boot/current.json')
        if (receipt['role']!=role or receipt['edge_id']!=identifier or receipt['root']!=str(root) or
                (root/'runtime/boot/pending.json').exists() or (root/'runtime/boot/pending.json').is_symlink()):
            raise ValueError('Committed role boot installation required')
        unit = role_bootstrap.verify_record(system_root,receipt)
        actual = network_bootstrap.existing(system_root/'etc/systemd/system'/unit)
        if actual is None or hashlib.sha256(actual).hexdigest()!=receipt['unit_sha256']:
            raise ValueError('Installed role boot unit changed')
        dropins=system_root/'etc/systemd/system'/(unit+'.d')
        if dropins.exists() or dropins.is_symlink():
            raise ValueError('Unknown role boot drop-in must be preserved')
        run('systemctl','is-enabled','--quiet',unit)
        health = core_deploy.healthy if role=='core' else edge_deploy.healthy
        health(root,current,execute=execute)
        result = {'schema':1,'role':role,'edge_id':identifier,'manifest':manifest,
                  'processes':process_snapshot(root,current,execute=execute)}
        if role=='core':
            if core_deploy.runtime_digest(root) != current['runtime_sha256']:
                raise ValueError('Core runtime differs from the committed baseline')
            identity = core_deploy.data_identity(root,current,execute=execute)
            if identity != state['data_identity']:raise ValueError('Core data identity changed')
            result.update(runtime_sha256=current['runtime_sha256'],data_identity=identity)
        if len(json.dumps(result).encode())>65536:raise ValueError('Role baseline response is too large')
        return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--topology',type=Path,required=True)
    parser.add_argument('--inventory',type=Path,required=True)
    parser.add_argument('--manifest',type=Path,required=True)
    parser.add_argument('--edge-subnet',default='10.241.0.0/28')
    args=parser.parse_args()
    public=topology.load(args.topology)
    result=inspect_role(args.root,public,node_inventory.load(args.inventory,public),
                        role_release.load(args.manifest),subnet=args.edge_subnet)
    print(json.dumps(result))


if __name__=='__main__':main()
