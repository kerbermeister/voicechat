"""One durable entry lifecycle, bound to reviewed inputs and exact acknowledgements.

The journal does not contact hosts or accept planned state as a health proof.
An interrupted step is retried with the same request and attempt. Completed
receipts are immutable; no automatic rollback can reauthorize a retired host.
"""
from pathlib import Path
import secrets

import entry_lifecycle
import managed_state
import managed_release
import role_release
import topology


def load(directory):
    value = managed_state.read(Path(directory) / 'current.json')
    topology.fields(value, ('schema', 'attempt', 'request', 'steps', 'position', 'receipts'))
    if (type(value['schema']) is not int or value['schema'] != 1 or
            not isinstance(value['attempt'], str) or not role_release.SHA.fullmatch(value['attempt'])):
        raise ValueError('Known entry lifecycle journal required')
    intent = managed_state.read(Path(directory) / ('intent-' + value['attempt'] + '.json'))
    if intent != {key: value[key] for key in ('schema', 'attempt', 'request', 'steps')}:
        raise ValueError('Frozen entry lifecycle intent changed')
    request = value['request']
    topology.fields(request, ('baseline', 'target', 'commit', 'web_image', 'source', 'settings'))
    if any(not isinstance(request[name], str) or not role_release.SHA.fullmatch(request[name]) for name in ('source', 'settings')):
        raise ValueError('Frozen lifecycle source required')
    expected = value['steps']
    if (not isinstance(expected, list) or not 1 <= len(expected) <= 256 or
            type(value['position']) is not int or not 0 <= value['position'] <= len(expected) or
            not isinstance(value['receipts'], list) or len(value['receipts']) != value['position']):
        raise ValueError('Entry lifecycle journal or sequence changed')
    for step in expected:
        topology.fields(step, ('action', 'node'))
        if not isinstance(step['action'], str) or not isinstance(step['node'], str):
            raise ValueError('Known lifecycle step required')
    for position, checksum in enumerate(value['receipts']):
        if not isinstance(checksum, str) or not role_release.SHA.fullmatch(checksum):
            raise ValueError('Known lifecycle receipt reference required')
        receipt = managed_state.read(Path(directory) / ('receipt-' + value['attempt'] + '-' + str(position) + '.json'))
        if role_release.json_digest(receipt) != checksum:
            raise ValueError('Frozen lifecycle receipt changed')
        validate_receipt(receipt, value['attempt'], position, expected[position])
    if value['position'] < len(expected):
        baseline = managed_release.load_baseline(Path(directory), request['baseline'])
        target = managed_release.load_baseline(Path(directory), request['target'])
        plan = entry_lifecycle.plan(baseline, target['public'], target['inventory'], request['commit'], request['web_image'])
        if plan['target'] != target or expected != entry_lifecycle.steps(plan):
            raise ValueError('Entry lifecycle sequence changed; use its frozen source')
    return value


def validate_receipt(receipt, attempt, position, step):
    topology.fields(receipt, ('schema', 'attempt', 'position', 'step', 'result_sha256'))
    if (type(receipt['schema']) is not int or receipt['schema'] != 1 or
            receipt['attempt'] != attempt or type(receipt['position']) is not int or
            receipt['position'] != position or receipt['step'] != step or
            not isinstance(receipt['result_sha256'], str) or
            not role_release.SHA.fullmatch(receipt['result_sha256'])):
        raise ValueError('Receipt does not acknowledge this exact lifecycle step')


def begin(directory, request):
    # Validate everything before creating even an empty journal directory.
    topology.fields(request, ('baseline', 'public', 'inventory', 'commit', 'web_image', 'source', 'settings'))
    plan = entry_lifecycle.plan(*(request[name] for name in
        ('baseline', 'public', 'inventory', 'commit', 'web_image')))
    if any(not isinstance(request[name], str) or not role_release.SHA.fullmatch(request[name]) for name in ('source', 'settings')):
        raise ValueError('Frozen lifecycle source required')
    with managed_state.locked(directory) as root:
        request = {**{key: request[key] for key in ('commit', 'web_image', 'source', 'settings')},
                   'baseline': managed_release.store_baseline(root, request['baseline']),
                   'target': managed_release.store_baseline(root, plan['target'])}
        path = root / 'current.json'
        if path.exists() or path.is_symlink():
            existing = load(root)
            if existing['request'] == request:
                return existing
            if existing['position'] < len(existing['steps']):
                raise ValueError('Resume the current entry lifecycle before a different request')
            archived = root / (existing['attempt'] + '.json')
            if archived.exists() or archived.is_symlink():
                raise ValueError('Lifecycle archive already exists')
            managed_state.persist(archived, existing)
        value = {'schema': 1, 'attempt': secrets.token_hex(32), 'request': request,
                 'steps': entry_lifecycle.steps(plan), 'position': 0, 'receipts': []}
        managed_state.persist(root / ('intent-' + value['attempt'] + '.json'),
                              {key: value[key] for key in ('schema', 'attempt', 'request', 'steps')})
        managed_state.persist(path, value)
        return value


def acknowledge(directory, receipt):
    with managed_state.locked(directory) as root:
        value = load(root)
        position = receipt.get('position') if isinstance(receipt, dict) else None
        if type(position) is not int or not 0 <= position < len(value['steps']):
            raise ValueError('Known lifecycle step position required')
        validate_receipt(receipt, value['attempt'], position, value['steps'][position])
        if position < value['position']:
            if value['receipts'][position] != role_release.json_digest(receipt):
                raise ValueError('Conflicting acknowledgement of a completed step')
            return value
        if position != value['position']:
            raise ValueError('Cannot skip a lifecycle step')
        record = root / ('receipt-' + value['attempt'] + '-' + str(position) + '.json')
        if record.exists() or record.is_symlink():
            if managed_state.read(record) != receipt:
                raise ValueError('Conflicting saved lifecycle receipt')
        else:
            managed_state.persist(record, receipt)
        value = {**value, 'position': position + 1, 'receipts': [*value['receipts'], role_release.json_digest(receipt)]}
        managed_state.persist(root / 'current.json', value)
        return value


def require_idle(directory):
    path = Path(directory) / 'current.json'
    if path.exists() or path.is_symlink():
        value = load(directory)
        if value['position'] != len(value['steps']):
            raise ValueError('Finish the active entry lifecycle before an ordinary release')
