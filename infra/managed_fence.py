"""Claim, inspect and release an existing role for the normal release driver.

These operations never deploy an application or restore data. A quiescent owned
boot monitor and durable peer intent make interrupted fence changes resumable.
"""
import os
from pathlib import Path
import time

import core_deploy
import edge_deploy
import managed_release
import managed_state
import network_bootstrap
import node_inventory
import role_bootstrap
import role_deploy
import role_prepare
import role_release
import tls_material


def _parameters(root, public, inventory, before, target, attempt, system_root):
    root = Path(root).absolute()
    if root.resolve() != root or not root.is_dir():
        raise ValueError('Existing canonical role required')
    for manifest in (before, target): role_release.verify_configuration(manifest, public, inventory)
    if any(before[key] != target[key] for key in ('role','edge_id','service_id','identity','contracts','node_sha256','topology_sha256')):
        raise ValueError('Normal release cannot change role identity or host assignment')
    node = inventory['core'] if before['role'] == 'core' else node_inventory.edge_assignment(inventory, before['edge_id'])
    host = network_bootstrap.existing(Path(system_root) / 'etc/ssh/ssh_host_ed25519_key.pub')
    if host is None or node_inventory.host_key(' '.join(host.decode().split()[:2])) != node['ssh_host_key']:
        raise ValueError('Managed role operation belongs to another SSH host')
    role_deploy.rollout_marker(root, target, attempt)
    return root


def _state(root, manifest):
    return core_deploy.read_state(root) if manifest['role'] == 'core' else edge_deploy.read_state(root, manifest['edge_id'])


def _committed(root, manifest):
    state = _state(root, manifest)
    if state['current'] is None or state['pending'] is not None or state['current']['manifest'] != manifest:
        raise ValueError('Exact committed role without pending deployment required')
    role_deploy.release_path(root, state['current'])
    return state


def _owned(root, before, target, attempt):
    value = role_deploy.managed_operation(root)
    if value is None or value['attempt'] != attempt or value['before'] != before or value['target'] != target:
        raise ValueError('Another managed operation owns this role')
    return value


def _quiesce(root, manifest, attempt, *, run):
    # Earlier installed operators understand full-rollout.json but not the new
    # peer intent. Wait for their monitor to exit under that existing fence;
    # never stop an unknown/older monitor and risk its finally stopping services.
    with managed_state.locked(root):
        role_deploy.require_rollout_owner(root, attempt, manifest)
    deadline = time.monotonic() + 15
    name = role_bootstrap.unit_name(manifest['role'], manifest['edge_id'])
    while run('systemctl','show',name,'--property=MainPID','--value').strip() != '0':
        if time.monotonic() >= deadline:
            raise TimeoutError('Owned boot monitor did not quiesce; preserve the fence')
        time.sleep(.1)


def _facts(root, public, inventory, manifest, active, attempt, *, subnet, system_root, execute, run):
    return managed_release.inspect_role(root, public, inventory, manifest, subnet=subnet,
        system_root=system_root, execute=execute, run=run,
        rollout_attempt=attempt if active is not None else None, rollout_manifest=active)


def claim(root, public, inventory, before, target, attempt, *, subnet='10.241.0.0/28',
          system_root=Path('/'), execute=role_deploy.run, run=role_bootstrap.service_command):
    root = _parameters(root, public, inventory, before, target, attempt, system_root)
    expected = role_deploy.rollout_marker(root, target, attempt)
    with managed_state.locked(root):
        existing = role_deploy.managed_operation(root)
        marker = role_deploy.pending_rollout(root)
        if marker not in (None, expected): raise ValueError('Another maintenance fence must be preserved')
        if existing is not None and existing['phase'] != 'released':
            _owned(root, before, target, attempt)
            if existing['active'] != target or existing['phase'] != 'held':
                raise ValueError('Finish the existing rollback or release')
        elif existing is not None and existing['attempt'] == attempt:
            raise ValueError('This managed role operation was already released')
        _committed(root, before)
    if existing is None or existing['phase'] == 'released':
        _facts(root,public,inventory,before,target if marker else None,attempt,
               subnet=subnet,system_root=system_root,execute=execute,run=run)
    # Only immutable generated source files are prepared; no runtime secrets,
    # certificates, service processes or deployment pointers are changed.
    role_prepare.prepare(root, public, inventory, target, subnet)
    with managed_state.locked(root):
        _committed(root, before)
        if role_deploy.managed_operation(root) != existing:
            raise ValueError('Peer intent changed during role preparation')
        if role_deploy.pending_rollout(root) not in (None, expected):
            raise ValueError('Another maintenance fence must be preserved')
        path = root / 'runtime/managed-release.json'
        if existing is not None and existing['phase'] == 'released':
            directory = root / 'runtime/managed-releases'; role_prepare.directory(directory)
            archived = directory / (existing['attempt'] + '.json')
            if archived.exists() or archived.is_symlink(): raise ValueError('Peer operation archive already exists')
            os.rename(path, archived)
            tls_material.sync_directory(directory); tls_material.sync_directory(path.parent)
        # Marker first: already installed operators must see maintenance even
        # if the process dies before the new peer intent has been persisted.
        managed_state.persist(root / 'runtime/full-rollout.json', expected)
        intent = {'schema':1,'operation':'managed-release','root':str(root),'attempt':attempt,
                  'owner':expected['owner'],'before':before,'target':target,'active':target,
                  'phase':'held','result':None}
        managed_state.persist(path, intent)
    _quiesce(root, target, attempt, run=run)
    return observe(root, public, inventory, before, target, before, attempt,
                   subnet=subnet,system_root=system_root,execute=execute,run=run)


def observe(root, public, inventory, before, target, manifest, attempt, *, subnet='10.241.0.0/28',
            system_root=Path('/'), execute=role_deploy.run, run=role_bootstrap.service_command):
    root = _parameters(root, public, inventory, before, target, attempt, system_root)
    if manifest not in (before, target): raise ValueError('Observe only this operation baseline or target')
    with managed_state.locked(root):
        intent = _owned(root, before, target, attempt)
        if intent['phase'] != 'held': raise ValueError('Finish releasing this managed operation')
        active = intent['active']
        role_deploy.require_rollout_owner(root, attempt, active)
    facts = _facts(root,public,inventory,manifest,active,attempt,
                   subnet=subnet,system_root=system_root,execute=execute,run=run)
    return {'facts':facts,'fence':{'attempt':attempt,'target':role_release.json_digest(active)}}


def retarget(root, public, inventory, before, target, active, attempt, *, system_root=Path('/'),
             run=role_bootstrap.service_command):
    """Select only the same operation's baseline/target before owned rollback."""
    root = _parameters(root, public, inventory, before, target, attempt, system_root)
    if active not in (before, target): raise ValueError('Rollback target is outside this managed operation')
    with managed_state.locked(root):
        intent = _owned(root, before, target, attempt)
        if intent['phase'] != 'held': raise ValueError('Cannot retarget an operation during release')
        state = _state(root, before)
        if state['current'] is None or state['current']['manifest'] not in (before,target):
            raise ValueError('A different role was deployed during maintenance')
        if state['pending'] is not None and state['pending']['target']['manifest'] not in (before,target):
            raise ValueError('A different role deployment is pending')
        previous = role_deploy.rollout_marker(root, intent['active'], attempt)
        expected = role_deploy.rollout_marker(root, active, attempt)
        if role_deploy.pending_rollout(root) not in (previous,expected):
            raise ValueError('Unknown maintenance fence must be preserved')
        managed_state.persist(root / 'runtime/full-rollout.json', expected)
        managed_state.persist(root / 'runtime/managed-release.json', {**intent,'active':active})
    _quiesce(root, active, attempt, run=run)


def release(root, public, inventory, before, target, manifest, attempt, *, subnet='10.241.0.0/28',
            system_root=Path('/'), execute=role_deploy.run, run=role_bootstrap.service_command,
            activate=role_bootstrap.activate):
    root = _parameters(root, public, inventory, before, target, attempt, system_root)
    if manifest not in (before,target): raise ValueError('Release only this operation baseline or target')
    with managed_state.locked(root):
        intent = _owned(root, before, target, attempt)
        if intent['active'] != manifest: raise ValueError('Commit or roll back the active target before release')
        marker = role_deploy.pending_rollout(root)
        expected = role_deploy.rollout_marker(root, manifest, attempt)
        if marker not in (None,expected): raise ValueError('Unknown maintenance fence must be preserved')
        if marker is None and intent['phase'] == 'held': raise ValueError('Managed fence disappeared before release')
        if marker is not None and intent['phase'] == 'released': raise ValueError('Released intent still has a maintenance fence')
        _committed(root, manifest)
    if marker is not None:
        _facts(root,public,inventory,manifest,manifest,attempt,
               subnet=subnet,system_root=system_root,execute=execute,run=run)
        _quiesce(root, manifest, attempt, run=run)
    with managed_state.locked(root):
        intent = _owned(root, before, target, attempt)
        _committed(root, manifest)
        if intent['active'] != manifest: raise ValueError('Active target changed before release')
        marker = role_deploy.pending_rollout(root)
        if marker not in (None,expected): raise ValueError('Unknown maintenance fence must be preserved')
        path = root / 'runtime/managed-release.json'
        if intent['phase'] == 'held':
            if marker is None: raise ValueError('Managed fence disappeared before release')
            intent = {**intent,'phase':'releasing','result':manifest}
            managed_state.persist(path, intent)
        if marker is not None:
            (root / 'runtime/full-rollout.json').unlink(); tls_material.sync_directory(path.parent)
        managed_state.persist(path, {**intent,'phase':'released','result':manifest})
    # Retry also activates: a crash may have happened after the receipt commit
    # but before monitoring restarted. Application data/configure is untouched.
    activate(root, manifest['role'], manifest['edge_id'])
    facts = _facts(root,public,inventory,manifest,None,attempt,
                   subnet=subnet,system_root=system_root,execute=execute,run=run)
    return {'facts':facts,'fence':None}
