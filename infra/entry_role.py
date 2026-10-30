"""Forward-only configuration change of an already claimed surviving role.

This is deliberately separate from ordinary deployment: admission changes public
configuration, and retirement may rotate a shared TURN secret. It never restores
an old secret or database snapshot on failure. The exact attempt retains its
fence until healthy state and its new ownership record have been verified.
"""
import hashlib
import os
from pathlib import Path
import re
import shutil
import tempfile

import core_deploy
import edge_deploy
import entry_lifecycle
import managed_fence
import managed_state
import role_bootstrap
import role_deploy
import role_prepare
import role_release
import tls_material
import topology


def turn_environment(content, secret):
    if not re.fullmatch(r'[a-f0-9]{64}', secret):
        raise ValueError('A fresh 32-byte TURN secret is required')
    matches = list(re.finditer(rb'(?m)^TURN_SECRET=([a-f0-9]{64})\r?$', content))
    if len(matches) != 1:
        raise ValueError('Expected one literal hexadecimal TURN_SECRET in the managed environment')
    match = matches[0]
    return content[:match.start(1)] + secret.encode() + content[match.end(1):]


def replace_private(path, content):
    descriptor, temporary = tempfile.mkstemp(prefix='.entry-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(content); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
        tls_material.sync_directory(path.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def binding(before_public, previous, public, inventory, before, target, attempt, secret):
    change = entry_lifecycle.change(before_public, previous, public, inventory)
    role_release.verify_configuration(before, before_public, previous)
    role_release.verify_configuration(target, public, inventory)
    if (any(before[name] != target[name] for name in
            ('role', 'edge_id', 'service_id', 'identity', 'contracts', 'node_sha256', 'images')) or
            not isinstance(attempt, str) or not role_release.SHA.fullmatch(attempt)):
        raise ValueError('Surviving role must retain host, identity, contracts and immutable images')
    if secret is not None and (not change['replacement'] or not re.fullmatch(r'[a-f0-9]{64}', secret)):
        raise ValueError('TURN rotation belongs only to the selected replacement')
    return {'schema': 1, 'attempt': attempt, 'before': before, 'target': target,
            'public': role_release.json_digest(public), 'inventory': role_release.json_digest(inventory),
            'turn_sha256': hashlib.sha256(secret.encode()).hexdigest() if secret is not None else None}


def apply(root, before_public, previous, public, inventory, before, target, attempt, *,
          turn_secret=None, subnet='10.241.0.0/28', execute=role_deploy.run):
    request = binding(before_public, previous, public, inventory, before, target, attempt, turn_secret)
    root = Path(root).absolute()
    if root.resolve() != root:
        raise ValueError('Canonical role root required')
    role, edge_id = target['role'], target['edge_id']
    module = core_deploy if role == 'core' else edge_deploy
    node = 'core' if role == 'core' or next(edge for edge in inventory['edges'] if edge['id'] == edge_id).get('host') == 'core' else 'edge-' + edge_id
    role_prepare.prepare(root, public, inventory, target, subnet)
    with managed_state.locked(root), role_deploy.network_ready(inventory, node, subnet, execute=execute):
        role_deploy.require_rollout_owner(root, attempt, before)
        intent = managed_fence._owned(root, before, before, attempt)
        if intent['phase'] != 'held':
            raise ValueError('Claim this surviving role before reconfiguration')
        state = core_deploy.read_state(root) if role == 'core' else edge_deploy.read_state(root, edge_id)
        directory = root / 'runtime/entry-role'
        role_prepare.directory(directory)
        path = directory / (attempt + '.json')
        saved = managed_state.read(path) if path.exists() or path.is_symlink() else None
        if saved is None:
            old = managed_fence._committed(root, before)['current']
            record = core_deploy.record_for(root, inventory, target) if role == 'core' else edge_deploy.record_for(public, inventory, target)
            environment = None
            if turn_secret is not None and role == 'core':
                content = tls_material.read_material(root / 'runtime/stand.env', private=True)
                if hashlib.sha256(content).hexdigest() != old['runtime_sha256']:
                    raise ValueError('Core runtime changed before credential rotation')
                environment = turn_environment(content, turn_secret).decode()
                record['runtime_sha256'] = hashlib.sha256(environment.encode()).hexdigest()
            saved = {'schema': 1, 'request': request, 'before': old, 'target': record,
                     'environment': environment, 'phase': 'prepared'}
            managed_state.persist(path, saved)
        elif saved['request'] != request:
            raise ValueError('Resume the exact role configuration/credential transition')
        topology.fields(saved, ('schema', 'request', 'before', 'target', 'environment', 'phase'))
        if type(saved['schema']) is not int or saved['schema'] != 1 or saved['phase'] not in ('prepared', 'stopping', 'applying', 'committing', 'complete'):
            raise ValueError('Known role transition phase required')
        old, record = saved['before'], saved['target']
        if old['manifest'] != before or record['manifest'] != target:
            raise ValueError('Saved role manifests differ from the frozen transition')
        if role == 'core':
            core_deploy.validate_record(old); core_deploy.validate_record(record)
            if saved['environment'] is not None and (not isinstance(saved['environment'], str) or
                    hashlib.sha256(saved['environment'].encode()).hexdigest() != record['runtime_sha256'] or
                    turn_secret is None or turn_environment(saved['environment'].encode(), turn_secret) != saved['environment'].encode()):
                raise ValueError('Saved credential transition changed')
        else:
            edge_deploy.validate_record(old, edge_id); edge_deploy.validate_record(record, edge_id)
            if saved['environment'] is not None:
                raise ValueError('Core environment must never be stored on an entry')
        if state['current'] not in (old, record) or (state['pending'] is not None and state['pending']['target'] != record):
            raise ValueError('Another role deployment must be preserved')
        if saved['phase'] == 'complete':
            if state['current'] != record or state['pending'] is not None:
                raise ValueError('Completed role transition drifted')
            module.healthy(root, record, execute=execute)
            return {'schema': 1, 'attempt': attempt, 'manifest': target, 'phase': 'complete'}
        changed = before['files'] != target['files'] or turn_secret is not None
        if saved['phase'] == 'prepared':
            module.healthy(root, old, execute=execute)
            if role == 'core':
                core_deploy.require_no_backup(root)
                if core_deploy.data_identity(root, old, execute=execute) != state['data_identity']:
                    raise ValueError('Core data identity changed before admission')
            if changed:
                if role == 'core':
                    if shutil.disk_usage(root).free < 2 * 1024**3:
                        raise ValueError('At least 2 GiB free space required before core reconfiguration')
                    execute(['docker', 'pull', core_deploy.legacy.RESTIC])
                module.compose(root, record, 'pull', '--policy', 'missing', execute=execute)
            saved = {**saved, 'phase': 'stopping'}; managed_state.persist(path, saved)
        if saved['phase'] == 'stopping':
            if changed and role == 'core':
                core_deploy.compose(root, old, 'stop', 'synapse', 'control', execute=execute)
                core_deploy.backup(root, old)
            saved = {**saved, 'phase': 'applying'}; managed_state.persist(path, saved)
        if saved['phase'] == 'applying':
            if saved['environment'] is not None:
                content = tls_material.read_material(root / 'runtime/stand.env', private=True)
                if hashlib.sha256(content).hexdigest() not in (old['runtime_sha256'], record['runtime_sha256']):
                    raise ValueError('Unexpected core environment during rotation')
                replace_private(root / 'runtime/stand.env', saved['environment'].encode())
            elif turn_secret is not None:
                path_secret = root / 'runtime/turn-secret'
                # The caller supplies only the replacement's new epoch. A
                # completed retry never reconfigures or republishes old bytes.
                tls_material.read_material(path_secret, private=True)
                replace_private(path_secret, turn_secret.encode())
            managed_state.persist(root / 'state.json', {**state, 'pending': {'target': record, 'phase': 'applying',
                **({'scope': 'edge'} if role == 'edge' else {})}})
            if changed:
                module.start_configured(root, record, execute=execute)
            module.healthy(root, record, execute=execute)
            if role == 'core' and core_deploy.data_identity(root, record, execute=execute) != state['data_identity']:
                raise ValueError('Core data identity changed during admission')
            saved = {**saved, 'phase': 'committing'}; managed_state.persist(path, saved)
        if saved['phase'] == 'committing':
            module.healthy(root, record, execute=execute)
            if role == 'core' and core_deploy.data_identity(root, record, execute=execute) != state['data_identity']:
                raise ValueError('Core data identity changed before transition commit')
            managed_state.persist(root / 'state.json', {**state, 'current': record,
                'previous': old if old != record else state['previous'], 'pending': None})
            saved = {**saved, 'phase': 'complete'}; managed_state.persist(path, saved)
        return {'schema': 1, 'attempt': attempt, 'manifest': target, 'phase': saved['phase']}


def release(root, before_public, previous, public, inventory, before, target, attempt, *,
            turn_secret=None, subnet='10.241.0.0/28', system_root=Path('/'),
            execute=role_deploy.run, run=role_bootstrap.service_command):
    """Rebind only a completed explicit transition, then use normal fence release.

    The intermediate old/new marker pair is repairable by this same attempt.
    Ordinary deployment still rejects any change in physical/public identity.
    """
    request = binding(before_public, previous, public, inventory, before, target, attempt, turn_secret)
    root = Path(root).absolute()
    if root.resolve() != root:
        raise ValueError('Canonical role root required')
    saved = managed_state.read(root / 'runtime/entry-role' / (attempt + '.json'))
    if saved['request'] != request or saved['phase'] != 'complete':
        raise ValueError('Finish the exact role transition before releasing its fence')
    role_bootstrap.install(root, target['role'], target['edge_id'], system_root=system_root, run=run)
    with managed_state.locked(root):
        state = core_deploy.read_state(root) if target['role'] == 'core' else edge_deploy.read_state(root, target['edge_id'])
        if state['current'] != saved['target'] or state['pending'] is not None:
            raise ValueError('Role transition drifted before release')
        intent = role_deploy.managed_operation(root)
        if intent is None or intent['attempt'] != attempt:
            raise ValueError('Another maintenance owner must be preserved')
        if not (intent['before'] == intent['target'] == intent['active'] and
                intent['active'] in (before, target)):
            raise ValueError('Unexpected role operation during entry transition')
        marker = role_deploy.pending_rollout(root)
        old_marker = role_deploy.rollout_marker(root, before, attempt)
        new_marker = role_deploy.rollout_marker(root, target, attempt)
        if intent['phase'] == 'held':
            if marker not in (old_marker, new_marker):
                raise ValueError('Missing or foreign entry transition fence')
            if intent['active'] != target:
                managed_state.persist(root / 'runtime/managed-release.json', {
                    **intent, 'before': target, 'target': target, 'active': target})
            if marker != new_marker:
                managed_state.persist(root / 'runtime/full-rollout.json', new_marker)
        elif intent['active'] != target:
            raise ValueError('Finish the original maintenance release first')
    return managed_fence.release(root, public, inventory, target, target, target, attempt,
        subnet=subnet, system_root=system_root, execute=execute, run=run)


def observe(root, before_public, previous, public, inventory, before, target, attempt, *,
            subnet='10.241.0.0/28', execute=role_deploy.run):
    """Inspect a completed entry transition while its original fence is held."""
    request = binding(before_public, previous, public, inventory, before, target, attempt, None)
    root = Path(root).absolute()
    if root.resolve() != root:
        raise ValueError('Canonical role root required')
    role, edge_id = target['role'], target['edge_id']
    module = core_deploy if role == 'core' else edge_deploy
    node = 'core' if role == 'core' or next(edge for edge in inventory['edges'] if edge['id'] == edge_id).get('host') == 'core' else 'edge-' + edge_id
    with managed_state.locked(root), role_deploy.network_ready(inventory, node, subnet, execute=execute):
        role_deploy.require_rollout_owner(root, attempt, before)
        saved = managed_state.read(root / 'runtime/entry-role' / (attempt + '.json'))
        if (saved['phase'] != 'complete' or {key: value for key, value in saved['request'].items()
                if key != 'turn_sha256'} != {key: value for key, value in request.items() if key != 'turn_sha256'}):
            raise ValueError('Complete the same role transition before inspection')
        state = core_deploy.read_state(root) if role == 'core' else edge_deploy.read_state(root, edge_id)
        if state['current'] != saved['target'] or state['pending'] is not None:
            raise ValueError('Role transition is not committed locally')
        record = state['current']
        role_deploy.release_path(root, record)
        role_bootstrap.ready(root, role, edge_id)
        module.healthy(root, record, execute=execute)
        # Same bounded actual process snapshot used by ordinary releases.
        import managed_release
        facts = {'schema': 1, 'role': role, 'edge_id': edge_id, 'manifest': target,
                 'processes': managed_release.process_snapshot(root, record, execute=execute)}
        if role == 'core':
            if core_deploy.runtime_digest(root) != record['runtime_sha256']:
                raise ValueError('Core runtime changed after entry transition')
            identity = core_deploy.data_identity(root, record, execute=execute)
            if identity != state['data_identity']:
                raise ValueError('Core data identity changed after entry transition')
            facts.update(runtime_sha256=record['runtime_sha256'], data_identity=identity)
        elif saved['request']['turn_sha256'] is not None:
            secret = tls_material.read_material(root / 'runtime/turn-secret', private=True)
            if hashlib.sha256(secret).hexdigest() != saved['request']['turn_sha256']:
                raise ValueError('Entry credential epoch changed')
        return facts
