"""Durable normal-release coordination on the data host.

The pinned SSH driver must obtain proofs from the real role operation. This
module validates/records those acknowledgements; it never runs containers,
publishes a catalog or treats a planned manifest as an observed role.
"""
import os
from pathlib import Path
import re
import secrets

import core_deploy
import managed_release
import managed_state
import release_delivery
import role_release
import topology

PHASES = ('fencing', 'applying', 'verifying', 'committing', 'releasing', 'complete',
          'rolling-back', 'rollback-verifying', 'rollback-releasing', 'rolled-back')


def _root(root):
    root = Path(root).absolute()
    if root.resolve() != root or not root.is_dir():
        raise ValueError('Existing canonical managed root required')
    info = root.stat()
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError('Managed root must be owner-only')
    return root


def _attempt_root(root, attempt):
    if not isinstance(attempt, str) or not role_release.SHA.fullmatch(attempt):
        raise ValueError('Valid managed attempt identity required')
    directory = root / ('attempt-' + attempt)
    if directory.resolve() != directory or not directory.is_dir():
        raise ValueError('Existing private attempt directory required')
    info = directory.stat()
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError('Attempt directory must be owner-only')
    return directory


def _delivery(root, checksum):
    if not isinstance(checksum, str) or not role_release.SHA.fullmatch(checksum):
        raise ValueError('Immutable source delivery required')
    source = root / 'bundles' / checksum
    if source.resolve() != source:
        raise ValueError('Source delivery cannot traverse symlinks')
    record = release_delivery.decode(release_delivery.read(source / 'delivery.json'))
    if record['archive_sha256'] != checksum:
        raise ValueError('Source delivery identity changed')
    release_delivery.verify(source, record)
    return record


def _pointer_baseline(root, pointer):
    if not isinstance(pointer, dict):
        raise ValueError('Typed managed release pointer required')
    if pointer.get('kind') == 'roles':
        baseline = managed_release.from_initial(pointer)
        initial = managed_state.read(root / 'initial.json')
        if initial.get('phase') != 'complete' or initial.get('target') != pointer['target']:
            raise ValueError('Finish initial adoption before a normal release')
        target = pointer['target']
        identifier = target['edge']['edge_id']
        if (target['root'] != str(root) or pointer['core_root'] != str(root / 'core') or
                pointer['edge_root'] != str(root / 'edges' / identifier) or
                pointer['legacy_root'] != target['legacy_root']):
            raise ValueError('Adoption role roots changed')
        shared = target['shared_root']
    else:
        topology.fields(pointer, ('schema', 'kind', 'baseline', 'data_identity', 'legacy_root', 'shared_root'))
        if type(pointer['schema']) is not int or pointer['schema'] != 1 or pointer['kind'] != 'managed':
            raise ValueError('Typed managed release pointer required')
        baseline = managed_release.load_baseline(root, pointer['baseline'])
        shared = pointer['shared_root']
    core_deploy.validate_data_identity(pointer['data_identity'])
    paths = [root]
    for name in (pointer['legacy_root'], shared):
        if not isinstance(name, str) or not re.fullmatch(r'/[A-Za-z0-9/_-]+', name):
            raise ValueError('Canonical installation path required')
        path = Path(name)
        if str(path) != name or path.resolve() != path or path == Path('/'):
            raise ValueError('Canonical installation path required')
        paths.append(path)
    if len(set(paths)) != 3 or any(a in b.parents for a in paths for b in paths if a != b):
        raise ValueError('Distinct nonnested installation roots required')
    return baseline, shared


def current(root):
    """Read either the completed adoption pointer or a compact normal pointer."""
    root = _root(root)
    pointer = managed_state.read(root / 'current.json')
    baseline, shared = _pointer_baseline(root, pointer)
    return pointer, baseline, shared


def _manifest(baseline, step):
    return baseline['core'] if step['role'] == 'core' else baseline['edges'][step['edge_id']]


def _sequence(journal, phase):
    if phase in ('fencing', 'verifying', 'releasing'):
        return journal['participants']
    if phase == 'applying':
        return journal['steps']
    before = journal['rollback_from']
    if before is None:
        raise ValueError('Rollback has no recorded origin')
    if before['phase'] == 'fencing':
        participants = journal['participants'][:before['position'] + 1]
        steps = []
    else:
        participants = journal['participants']
        count = before['position'] + 1 if before['phase'] == 'applying' else len(journal['steps'])
        steps = journal['steps'][:count]
    return list(reversed(steps)) if phase == 'rolling-back' else participants


def _load(root, attempt=None):
    value = managed_state.read(root / 'rollout.json')
    topology.fields(value, ('schema', 'attempt', 'request', 'baseline', 'target', 'before', 'phase',
                            'position', 'steps', 'participants', 'data_identity', 'legacy_root',
                            'shared_root', 'rollback_from'))
    if (type(value['schema']) is not int or value['schema'] != 1 or
            not isinstance(value['attempt'], str) or not role_release.SHA.fullmatch(value['attempt']) or
            (attempt is not None and attempt != value['attempt'])):
        raise ValueError('Another managed release owns the journal')
    topology.fields(value['request'], ('source', 'baseline', 'scope', 'edges'))
    receipt = _delivery(root, value['request']['source'])
    baseline = managed_release.load_baseline(root, value['baseline'])
    target = managed_release.load_baseline(root, value['target'])
    directory = _attempt_root(root, value['attempt'])
    intent = managed_state.read(directory / 'intent.json')
    immutable = {key: item for key, item in value.items() if key not in ('phase', 'position', 'rollback_from')}
    if intent != immutable or value['request']['baseline'] != role_release.json_digest(baseline):
        raise ValueError('Recorded release intent changed')
    if value['phase'] not in ('complete', 'rolled-back'):
        # Active attempts run from their frozen source entry. Historical terminal
        # journals retain their original validated intent: do not re-render them
        # using the next release's changed configuration generator.
        plan = managed_release.plan(baseline, receipt['manifest'], receipt['backend'],
                                    scope=value['request']['scope'], edges=value['request']['edges'])
        expected = {**baseline, 'backend': plan['backend'], 'core': plan['core'], 'edges': plan['edges']}
        participants = [{'role': 'core', 'edge_id': None}]
        participants += [step for step in plan['steps'] if step['role'] == 'edge']
        if target != expected or value['steps'] != plan['steps'] or value['participants'] != participants:
            raise ValueError('Recorded release plan changed')
    before = managed_state.read(directory / 'before.json')
    if role_release.json_digest(before) != value['before']:
        raise ValueError('Original production pointer changed')
    original, shared = _pointer_baseline(root, before)
    if original != baseline or shared != value['shared_root']:
        raise ValueError('Original production baseline changed')
    core_deploy.validate_data_identity(value['data_identity'])
    if before['data_identity'] != value['data_identity'] or before['legacy_root'] != value['legacy_root']:
        raise ValueError('Managed release identity changed')
    if value['phase'] not in PHASES or type(value['position']) is not int or value['position'] < 0:
        raise ValueError('Invalid release phase')
    rollback = value['rollback_from']
    if rollback is not None:
        topology.fields(rollback, ('phase', 'position'))
        if (rollback['phase'] not in ('fencing', 'applying', 'verifying') or
                type(rollback['position']) is not int or not 0 <= rollback['position'] < len(_sequence(value, rollback['phase']))):
            raise ValueError('Invalid rollback origin')
    if value['phase'] not in ('committing', 'complete', 'rolled-back'):
        if value['position'] >= len(_sequence(value, value['phase'])):
            raise ValueError('Invalid release step')
    elif value['position'] != 0:
        raise ValueError('Terminal release phase has a step position')
    return value, baseline, target, before


def begin(root, source, expected_baseline, *, scope='full', edges=None, retry=False):
    root = _root(root)
    request = {'source': source, 'baseline': expected_baseline, 'scope': scope, 'edges': None if edges is None else list(edges)}
    with managed_state.locked(root):
        receipt = _delivery(root, source)
        path = root / 'rollout.json'
        previous = None
        if path.exists() or path.is_symlink():
            previous, _, _, before = _load(root)
            if previous['phase'] not in ('complete', 'rolled-back'):
                if previous['request'] != request:
                    raise ValueError('Resume the same pending managed release')
                return previous
            if previous['phase'] == 'complete' and previous['request'] == request:
                _require_pointer(root, _pointer(previous))
                return previous
            if previous['phase'] == 'rolled-back' and not retry:
                raise ValueError('Explicit retry required after a completed rollback')
        pointer, baseline, shared = current(root)
        if role_release.json_digest(baseline) != expected_baseline:
            raise ValueError('Production baseline changed since release preparation')
        plan = managed_release.plan(baseline, receipt['manifest'], receipt['backend'], scope=scope, edges=request['edges'])
        target = {**baseline, 'backend': plan['backend'], 'core': plan['core'], 'edges': plan['edges']}
        baseline_ref = managed_release.store_baseline(root, baseline)
        target_ref = managed_release.store_baseline(root, target)
        attempt = secrets.token_hex(32)
        directory = root / ('attempt-' + attempt)
        directory.mkdir(mode=0o700)
        managed_state.persist(directory / 'before.json', pointer)
        if previous is not None:
            # Preserve the original completed journal verbatim; never edit its source bundle.
            archived = _attempt_root(root, previous['attempt']) / 'managed-rollout.json'
            if archived.exists() or archived.is_symlink():
                raise ValueError('Previous managed journal archive already exists')
            os.rename(path, archived)
            for parent in (root, archived.parent):
                descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
                try: os.fsync(descriptor)
                finally: os.close(descriptor)
        participants = [{'role': 'core', 'edge_id': None}]
        participants += [step for step in plan['steps'] if step['role'] == 'edge']
        value = {'schema': 1, 'attempt': attempt, 'request': request, 'baseline': baseline_ref,
                 'target': target_ref, 'before': role_release.json_digest(pointer), 'phase': 'fencing',
                 'position': 0, 'steps': plan['steps'], 'participants': participants,
                 'data_identity': pointer['data_identity'], 'legacy_root': pointer['legacy_root'],
                 'shared_root': shared, 'rollback_from': None}
        managed_state.persist(directory / 'intent.json', {key: item for key, item in value.items()
                                                       if key not in ('phase', 'position', 'rollback_from')})
        managed_state.persist(path, value)
        return value


def _pointer(journal):
    return {'schema': 1, 'kind': 'managed', 'baseline': journal['target'],
            **{key: journal[key] for key in ('data_identity', 'legacy_root', 'shared_root')}}


def _require_pointer(root, expected):
    if managed_state.read(root / 'current.json') != expected:
        raise ValueError('Production pointer changed outside the managed release')


def read(root, attempt=None):
    root = _root(root)
    with managed_state.locked(root):
        return _load(root, attempt)[0]


def _proof(root, journal, baseline, target, phase, position, proof):
    topology.fields(proof, ('facts', 'fence'))
    step = _sequence(journal, phase)[position]
    restoring = phase.startswith('rollback') or phase == 'rolling-back'
    manifest = _manifest(baseline if phase == 'fencing' or restoring else target, step)
    facts = proof['facts']
    names = ('schema', 'role', 'edge_id', 'manifest', 'processes')
    if step['role'] == 'core': names += ('runtime_sha256', 'data_identity')
    topology.fields(facts, names)
    if (type(facts['schema']) is not int or facts['schema'] != 1 or
            any(facts[key] != step[key] for key in ('role', 'edge_id')) or facts['manifest'] != manifest):
        raise ValueError('Proof does not identify the expected role manifest')
    processes = facts['processes']
    count = 3 if step['role'] == 'core' else len(set(manifest['images']) - {'configure'})
    if (not isinstance(processes, list) or len(processes) != count or
            any(not isinstance(item, str) or not re.fullmatch(r'[a-f0-9]{64} true [^ ]+ [0-9]+', item) for item in processes) or
            len({item.split()[0] for item in processes}) != count):
        raise ValueError('Complete running role process proof required')
    if step['role'] == 'core':
        if facts['data_identity'] != journal['data_identity'] or not isinstance(facts['runtime_sha256'], str) or not role_release.SHA.fullmatch(facts['runtime_sha256']):
            raise ValueError('Core data or runtime proof changed')
        if phase != 'fencing':
            path = _attempt_root(root, journal['attempt']) / 'fencing-0.json'
            # Aborting the first claim can precede its acknowledgement. The
            # role still must prove its committed manifest/data/runtime; there
            # is no earlier observed process snapshot to compare in that case.
            early_abort = journal['rollback_from'] == {'phase': 'fencing', 'position': 0}
            if not (restoring and early_abort and not path.exists() and not path.is_symlink()):
                first = managed_state.read(path)['facts']
                if facts['runtime_sha256'] != first['runtime_sha256']:
                    raise ValueError('Core runtime changed during the release')
                if (phase in ('verifying', 'rollback-verifying') and
                        _manifest(baseline, step) == _manifest(target, step) and facts['processes'] != first['processes']):
                    raise ValueError('Partial edge release changed core processes')
    if phase in ('releasing', 'rollback-releasing'):
        expected_fence = None
    else:
        fenced_manifest = _manifest(baseline if restoring else target, step)
        expected_fence = {'attempt': journal['attempt'], 'target': role_release.json_digest(fenced_manifest)}
    if proof['fence'] != expected_fence:
        raise ValueError('Role maintenance fence proof differs from the release')


def _advance(journal):
    following = {'fencing': 'applying', 'applying': 'verifying', 'verifying': 'committing',
                 'releasing': 'complete', 'rolling-back': 'rollback-verifying',
                 'rollback-verifying': 'rollback-releasing', 'rollback-releasing': 'rolled-back'}
    phase, position = journal['phase'], journal['position'] + 1
    while position >= len(_sequence(journal, phase)):
        phase, position = following[phase], 0
        if phase in ('committing', 'complete', 'rolled-back'): break
    return {**journal, 'phase': phase, 'position': position}


def acknowledge(root, attempt, phase, position, proof):
    root = _root(root)
    if phase not in PHASES or phase in ('committing', 'complete', 'rolled-back') or type(position) is not int or position < 0:
        raise ValueError('An observed role operation is required')
    with managed_state.locked(root):
        journal, baseline, target, before = _load(root, attempt)
        sequence = _sequence(journal, phase)
        if position >= len(sequence): raise ValueError('Unknown release step')
        path = _attempt_root(root, attempt) / (phase + '-' + str(position) + '.json')
        existed = path.exists() or path.is_symlink()
        if existed and managed_state.read(path) != proof:
            raise ValueError('Previously acknowledged operation proof changed')
        if (journal['phase'], journal['position']) != (phase, position):
            if existed: return journal  # Lost reply: never advance a second time.
            raise ValueError('Out-of-order managed release acknowledgement')
        _require_pointer(root, _pointer(journal) if phase == 'releasing' else before)
        _proof(root, journal, baseline, target, phase, position, proof)
        managed_state.persist(path, proof)
        result = _advance(journal)
        managed_state.persist(root / 'rollout.json', result)
        return result


def commit(root, attempt):
    root = _root(root)
    with managed_state.locked(root):
        journal, baseline, target, before = _load(root, attempt)
        expected = _pointer(journal)
        if journal['phase'] in ('releasing', 'complete'):
            _require_pointer(root, expected)
            return journal
        if journal['phase'] != 'committing':
            raise ValueError('Verify all participating roles before committing')
        for phase in ('fencing', 'applying', 'verifying'):
            for position in range(len(_sequence(journal, phase))):
                proof = managed_state.read(_attempt_root(root, attempt) / (phase + '-' + str(position) + '.json'))
                _proof(root, journal, baseline, target, phase, position, proof)
        actual = managed_state.read(root / 'current.json')
        if actual not in (before, expected):
            raise ValueError('Production pointer changed outside the managed release')
        managed_state.persist(root / 'previous.json', before)
        managed_state.persist(root / 'current.json', expected)
        result = {**journal, 'phase': 'releasing'}
        managed_state.persist(root / 'rollout.json', result)
        return result


def start_rollback(root, attempt):
    root = _root(root)
    with managed_state.locked(root):
        journal, _, _, before = _load(root, attempt)
        if journal['phase'] in ('rolling-back', 'rollback-verifying', 'rollback-releasing', 'rolled-back'):
            return journal
        if journal['phase'] not in ('fencing', 'applying', 'verifying'):
            raise ValueError('Public commit is forward-only; finish releasing the committed target')
        _require_pointer(root, before)
        result = {**journal, 'phase': 'rolling-back', 'position': 0,
                  'rollback_from': {key: journal[key] for key in ('phase', 'position')}}
        if not _sequence(result, 'rolling-back'):
            result['phase'] = 'rollback-verifying'
        managed_state.persist(root / 'rollout.json', result)
        return result
