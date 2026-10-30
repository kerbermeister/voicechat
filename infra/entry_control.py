"""Data-host entry lifecycle state, credentials and guarded baseline commit.

Private credentials stay on A except the selected entry's TURN/TLS material sent
through its pinned operator SSH session. This module never signs a catalog.
"""
import hashlib
import json
from pathlib import Path
import re
import secrets

import acme
import core_deploy
import entry_dns
import entry_journal
import entry_lifecycle
import entry_role
import entry_settings
import host_registration
import managed_journal
import managed_release
import managed_state
import network_runtime
import node_inventory
import role_release
import route_catalog
import tls_material


def directory(root, attempt):
    if not isinstance(attempt, str) or not role_release.SHA.fullmatch(attempt):
        raise ValueError('Exact entry lifecycle attempt required')
    path = root / 'entry-lifecycle' / ('attempt-' + attempt)
    path.mkdir(mode=0o700, exist_ok=True)
    if path.resolve() != path or path.stat().st_mode & 0o077:
        raise ValueError('Owned canonical private entry attempt directory required')
    return path


def catalog_key(root):
    initial = managed_state.read(root / 'initial.json')
    if initial.get('phase') != 'complete':
        raise ValueError('A completed initial adoption with its pinned catalog key is required')
    key = initial['target']['catalog_key']
    # Validate the key encoding without accepting a key received from an entry.
    import base64
    if not isinstance(key, str) or len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError('Invalid installation catalog key')
    return key



def published_catalog(root, baseline):
    path = root / 'catalog.json'
    if not path.exists() and not path.is_symlink():
        initial = managed_state.read(root / 'initial.json')
        path = root / 'edges' / initial['target']['edge']['edge_id'] / 'runtime/catalog/routes.json'
    envelope = route_catalog.read_envelope(path)
    checked = route_catalog.verify(envelope, catalog_key(root), baseline['public'], restoring=True)
    return envelope.decode(), checked

def begin(root, source, expected_baseline, public, inventory, settings, *, system_root=Path('/')):
    settings = entry_settings.normalize(settings)
    receipt = managed_journal._delivery(root, source)
    active = root / 'entry-lifecycle/current.json'
    if active.exists() or active.is_symlink():
        existing = entry_journal.load(active.parent)
        wanted = {'source': source, 'settings': role_release.json_digest(settings)}
        original_baseline = managed_release.load_baseline(active.parent, existing['request']['baseline'])
        same = role_release.json_digest(original_baseline) == expected_baseline and all(
            existing['request'][name] == value for name, value in wanted.items())
        stored_target = managed_release.load_baseline(active.parent, existing['request']['target'])
        same = same and stored_target['public'] == public and stored_target['inventory'] == inventory
        context = directory(root, existing['attempt']) / 'context.json'
        if same and context.exists() and managed_state.read(context)['secret_sha256'] is not None:
            state(root, existing['attempt']); read_secret(root, existing['attempt'])
            return existing
        if not same and existing['position'] < len(existing['steps']):
            raise ValueError('Resume the original frozen entry admission')
    pointer, baseline, _ = managed_journal.current(root)
    if role_release.json_digest(baseline) != expected_baseline:
        raise ValueError('Managed baseline changed before entry admission')
    if (receipt['backend'] != baseline['backend'] or receipt.get('core_guard') != baseline.get('core_guard') or
            receipt['manifest']['control'] != baseline['core']['images']['control']):
        raise ValueError('Install the matching full operator release before entry lifecycle execution')
    transition = entry_lifecycle.change(baseline['public'], baseline['inventory'], public, inventory)
    selected = transition['edge_id']
    web = baseline['edges'][selected]['images']['web'] if transition['replacement'] else receipt['manifest']['web']
    if web != receipt['manifest']['web']:
        raise ValueError('Source delivery must name the selected installed web digest')
    key = catalog_key(root)
    topology_fields = ('catalog', 'dns_domain', 'dns_expected', 'dns_token_file', 'tls')
    from topology import fields
    fields(settings, topology_fields)
    _, previous_catalog = published_catalog(root, baseline)
    verified = route_catalog.verify(settings['catalog'].encode(), key, baseline['public'], previous=previous_catalog)
    if verified.topology != public:
        raise ValueError('Signed admission catalog does not match the requested topology')
    entry_dns.plan(public, inventory, selected, settings['dns_domain'], settings['dns_expected'])
    rollout = root / 'rollout.json'
    if rollout.exists() or rollout.is_symlink():
        journal = managed_state.read(rollout)
        if journal.get('phase') not in ('complete', 'rolled-back'):
            raise ValueError('Finish the ordinary managed release before admitting an entry')
    network = managed_state.read(system_root / 'var/lib/voicechat-network/desired.json')
    if network['inventory'] != baseline['inventory'] or network['node'] != 'core':
        raise ValueError('Core network differs from the committed admission baseline')
    request = {'baseline': baseline, 'public': public, 'inventory': inventory,
        'commit': receipt['manifest']['commit'], 'web_image': web, 'source': source,
        'settings': role_release.json_digest(settings)}
    value = entry_journal.begin(root / 'entry-lifecycle', request)
    target = directory(root, value['attempt'])
    entry_settings.store(target, settings)
    context_path = target / 'context.json'
    if not context_path.exists() and not context_path.is_symlink():
        core = core_deploy.read_state(root / 'core')['current']
        if core is None or core_deploy.runtime_digest(root / 'core') != core['runtime_sha256']:
            raise ValueError('Committed core environment required before admission')
        content = tls_material.read_material(root / 'core/runtime/stand.env', private=True)
        epoch = entry_role.turn_epoch(content)['secret']
        old_epoch = target / 'turn-previous-secret'
        if old_epoch.exists() or old_epoch.is_symlink():
            if tls_material.read_material(old_epoch, private=True) != epoch:
                raise ValueError('Original TURN epoch changed')
        else:
            tls_material.write_private(old_epoch, epoch)
        context = {'schema': 1, 'pointer': pointer, 'public_keys': network['public_keys'],
            'catalog_key': key, 'turn_before_sha256': hashlib.sha256(epoch).hexdigest(),
            'secret_sha256': None}
        managed_state.persist(context_path, context)
        private = target / 'turn-secret'
        if not private.exists() and not private.is_symlink():
            secret = secrets.token_hex(32).encode() if transition['replacement'] else epoch
            tls_material.write_private(private, secret)
    # A lost write/reply may leave the secret before its receipt. Reuse that file,
    # never regenerate a committed epoch when it disappears.
    context = managed_state.read(context_path)
    private = target / 'turn-secret'
    if not private.exists() and context['secret_sha256'] is None:
        # Only possible before the very first secret creation; no driver step is
        # acknowledged yet. Existing context retains the original source/owner.
        if value['position'] != 0:
            raise ValueError('Missing entry credential; preserve the attempt')
        if transition['replacement']:
            tls_material.write_private(private, secrets.token_hex(32).encode())
        else:
            content = tls_material.read_material(root / 'core/runtime/stand.env', private=True)
            epoch = entry_role.turn_epoch(content)['secret']
            if hashlib.sha256(epoch).hexdigest() != context['turn_before_sha256']:
                raise ValueError('Original core TURN epoch changed before admission')
            tls_material.write_private(private, epoch)
    secret = tls_material.read_material(private, private=True)
    digest = hashlib.sha256(secret).hexdigest()
    if not re.fullmatch(rb'[a-f0-9]{64}', secret) or context['secret_sha256'] not in (None, digest):
        raise ValueError('Entry credential epoch changed or disappeared')
    if context['secret_sha256'] is None:
        managed_state.persist(context_path, {**context, 'secret_sha256': digest})
    return value


def state(root, attempt=None):
    value = entry_journal.load(root / 'entry-lifecycle')
    if attempt is not None and value['attempt'] != attempt:
        raise ValueError('Another entry lifecycle owns the coordinator')
    path = directory(root, value['attempt'])
    settings = entry_settings.load(path)
    if role_release.json_digest(settings) != value['request']['settings']:
        raise ValueError('Frozen entry settings changed')
    baseline = managed_release.load_baseline(root / 'entry-lifecycle', value['request']['baseline'])
    desired = managed_release.load_baseline(root / 'entry-lifecycle', value['request']['target'])
    plan = entry_lifecycle.plan(baseline, desired['public'], desired['inventory'],
                                value['request']['commit'], value['request']['web_image'])
    if plan['target'] != desired:
        raise ValueError('Frozen lifecycle target changed')
    context = managed_state.read(path / 'context.json')
    if context['catalog_key'] != catalog_key(root):
        raise ValueError('Installation catalog key changed')
    return value, path, baseline, plan, settings, context


def read_secret(root, attempt):
    _, path, _, _, _, context = state(root, attempt)
    content = tls_material.read_material(path / 'turn-secret', private=True)
    if hashlib.sha256(content).hexdigest() != context['secret_sha256']:
        raise ValueError('Restore the original entry epoch; never regenerate it')
    return {'secret': content.decode()}


def register(root, attempt, identity):
    _, path, baseline, plan, _, context = state(root, attempt)
    keys = host_registration.registry(baseline['inventory'], plan['target']['inventory'], context['public_keys'], identity)
    value = {'schema': 1, 'identity': identity, 'public_keys': keys}
    record = path / 'registration.json'
    if record.exists() or record.is_symlink():
        if managed_state.read(record) != value:
            raise ValueError('Resume the exact admitted host identity')
    else:
        managed_state.persist(record, value)
    return value


def certificates(root, attempt):
    _, path, _, plan, settings, _ = state(root, attempt)
    tls = settings['tls']
    from topology import fields
    if tls.get('mode') == 'acme':
        fields(tls, ('mode', 'directory', 'token_file', 'config', 'accept_tos'))
    elif tls.get('mode') == 'existing':
        fields(tls, ('mode', 'web_chain', 'web_key', 'turn_chain', 'turn_key'))
    else:
        raise ValueError('Central ACME or explicitly supplied certificate pairs required')
    receipt = path / 'certificates.json'
    saved = managed_state.read(receipt) if receipt.exists() or receipt.is_symlink() else {}
    public, inventory = plan['target']['public'], plan['target']['inventory']
    for service in ('web', 'turn'):
        if service in saved:
            original = Path(saved[service])
            checked = tls_material.stage(path / 'verified-tls', public, plan['edge_id'], service,
                original / (service + '.crt'), original / (service + '.key'))
            if str(checked) != saved[service]:
                raise ValueError('Frozen entry certificate material changed')
            continue
        if tls['mode'] == 'acme':
            issued = acme.execute(Path(tls['directory']), public, inventory, tls['config'],
                plan['edge_id'], service, Path(tls['token_file']), accept_tos=tls['accept_tos'])
            chain, key = issued / (service + '.crt'), issued / (service + '.key')
        else:
            chain, key = Path(tls[service + '_chain']), Path(tls[service + '_key'])
        verified = tls_material.stage(path / 'verified-tls', public, plan['edge_id'], service, chain, key)
        saved[service] = str(verified)
        managed_state.persist(receipt, saved)
    # This private response is captured in memory by the SSH driver. It must
    # never be used as a public step receipt or printed by the operator CLI.
    material = {}
    for service, location in saved.items():
        for extension, label in (('crt', 'chain'), ('key', 'key')):
            material[service + '_' + label] = tls_material.read_material(
                Path(location) / (service + '.' + extension), private=True).decode()
    return material


def acknowledge(root, attempt, position, result):
    value, path, baseline, plan, settings, context = state(root, attempt)
    if type(position) is not int or not 0 <= position < len(value['steps']):
        raise ValueError('Known lifecycle step position required')
    if position > value['position']:
        raise ValueError('Cannot acknowledge a future lifecycle step')
    # Explicitly prevent accidentally archiving a private SSH material response.
    forbidden = ('secret', 'turn_secret', 'web_key', 'turn_key', 'web_chain', 'turn_chain')
    if not isinstance(result, dict) or any(name in result for name in forbidden):
        raise ValueError('Only a bounded public step result may be acknowledged')
    def public_result(item):
        if isinstance(item, dict):
            if any(name in item for name in (*forbidden, 'password', 'token', 'private_key', 'environment', 'credential', 'username')):
                raise ValueError('Private nested material cannot enter a step receipt')
            for child in item.values(): public_result(child)
        elif isinstance(item, list):
            for child in item: public_result(child)
    public_result(result)
    if position == value['position']:
        validate_result(root, value, path, baseline, plan, settings, context, position, result)
    proof = {'schema': 1, 'attempt': attempt, 'position': position,
        'step': value['steps'][position], 'result_sha256': role_release.json_digest(result)}
    directory_results = path / 'results'
    directory_results.mkdir(mode=0o700, exist_ok=True)
    record = directory_results / (str(position) + '.json')
    if record.exists() or record.is_symlink():
        if managed_state.read(record) != result:
            raise ValueError('Conflicting result for this lifecycle step')
    else:
        managed_state.persist(record, result)
    return entry_journal.acknowledge(root / 'entry-lifecycle', proof)


def commit(root, attempt):
    value, path, _, plan, _, context = state(root, attempt)
    step = value['steps'][value['position']] if value['position'] < len(value['steps']) else None
    if step != {'action': 'commit', 'node': 'core'}:
        raise ValueError('Complete readiness, DNS and catalog before baseline commit')
    pointer, _, _ = managed_journal.current(root)
    target_ref = managed_release.store_baseline(root, plan['target'])
    target_pointer = {**context['pointer'], 'kind': 'managed', 'baseline': target_ref}
    if pointer not in (context['pointer'], target_pointer):
        raise ValueError('Another managed baseline must be preserved')
    # Archive a terminal ordinary journal before changing its pointer. Its exact
    # source and attempt directory remain retained; no old finish is replayed.
    rollout = root / 'rollout.json'
    archived = path / 'ordinary-before.json'
    if rollout.exists() or rollout.is_symlink():
        previous = managed_state.read(rollout)
        if previous.get('phase') not in ('complete', 'rolled-back'):
            raise ValueError('A different ordinary rollout is active')
        if archived.exists() or archived.is_symlink():
            if managed_state.read(archived) != previous:
                raise ValueError('Original rollout archive differs')
        else:
            managed_state.persist(archived, previous)
        rollout.unlink()
        tls_material.sync_directory(root)
    if pointer != target_pointer:
        managed_state.persist(root / 'previous.json', context['pointer'])
        managed_state.persist(root / 'current.json', target_pointer)
    # Keep a signed public artifact on A even when all entry hosts are remote.
    # It contains no private signing key or user data.
    settings = entry_settings.load(path)
    managed_state.persist(root / 'catalog.json', json.loads(settings['catalog']))
    return {'schema': 1, 'attempt': attempt, 'baseline': target_ref,
            'data_identity': target_pointer['data_identity'], 'phase': 'committed'}


def validate_result(root, value, path, baseline, plan, settings, context, position, result):
    """Check step-specific public evidence; a planned manifest is insufficient."""
    step = value['steps'][position]; action, node = step['action'], step['node']
    after, attempt = plan['target'], value['attempt']
    target = after['edges'][plan['edge_id']]
    def require(condition):
        if not condition: raise ValueError('Lifecycle result does not prove the expected ' + action + ' step')
    def facts(proof, manifest, *, images=False):
        require(isinstance(proof, dict) and type(proof.get('schema')) is int and proof['schema'] == 1 and proof.get('manifest') == manifest)
        rows = proof.get('processes')
        count = 3 if manifest['role'] == 'core' else len(manifest['images']) - 1
        require(isinstance(rows, list) and len(rows) == count and all(
            isinstance(row, str) and re.fullmatch(r'[a-f0-9]{64} true [^ ]+ [0-9]+', row) for row in rows))
        if images: require(proof.get('images_verified') is True)
        if manifest['role'] == 'core': require(proof.get('data_identity') == context['pointer']['data_identity'])
    def role_manifest(base, name):
        return base['core'] if name == 'core' else base['edges'][name.removeprefix('edge-')]
    if action == 'prepare':
        import host_packages
        require(result.get('installed') is True and json.dumps(result.get('target'), sort_keys=True) == json.dumps(host_packages.binding(after['inventory'], plan['node']), sort_keys=True))
    elif action == 'identity':
        host_registration.registry(baseline['inventory'], after['inventory'], context['public_keys'], result)
    elif action == 'register': require(result == managed_state.read(path / 'registration.json'))
    elif action == 'network':
        require(type(result.get('schema')) is int and result['schema'] == 1 and result.get('node') == node and
                isinstance(result.get('network_sha256'), str) and role_release.SHA.fullmatch(result['network_sha256']))
        if node == plan['node']:
            require(type(result.get('generation')) is int and result['generation'] == node_inventory.edge_assignment(after['inventory'], plan['edge_id'])['generation'])
        else: require(result.get('attempt') == attempt and result.get('private_key_exported') is False and result.get('peers_verified') is True)
    elif action == 'tls':
        require(result.get('material_ready') is True and result.get('manifest') == target)
        certificates = managed_state.read(path / 'certificates.json')
        require(set(certificates) == {'web', 'turn'})
    elif action == 'stage':
        require(result.get('prepared', {}).get('prepared') is True and result['prepared'].get('manifest') == target)
        image = result.get('image', {})
        require(image.get('image_ready') is True and image.get('image') == target['images']['web'] and image.get('credential_persisted') is False)
    elif action in ('claim', 'release', 'rotate-turn'):
        names = entry_lifecycle.role_ids(after['inventory'], node)
        require(isinstance(result.get('roles'), dict) and set(result['roles']) == set(names))
        for name in names:
            proof = result['roles'][name]
            expected = role_manifest(baseline if action == 'claim' else after, name)
            if action == 'rotate-turn': facts(proof, expected, images=True)
            else:
                require(isinstance(proof, dict))
                facts(proof.get('facts'), expected)
                require(proof.get('fence') == ({'attempt': attempt, 'target': role_release.json_digest(expected)} if action == 'claim' else None))
    elif action == 'configure': facts(result, role_manifest(after, node), images=True)
    elif action in ('start', 'verify'):
        facts(result, target, images=True)
        if action == 'verify':
            import entry_probe
            entry_probe.ready(after['public'], after['inventory'], plan['edge_id'])
    elif action == 'verify-turn':
        require(result.get('turn_verified') is True and result.get('edge_id') == node.removeprefix('edge-') and
                result.get('retired_credential_rejected') is plan['rotate_turn_secret'])
    elif action == 'dns':
        saved = managed_state.read(path / 'dns/cutover.json')
        require(saved['phase'] == 'complete' and result.get('phase') == 'complete' and
                result.get('addresses') == [node_inventory.edge_assignment(after['inventory'], plan['edge_id'])['public_ip']])
    elif action == 'verify-dns': require(result.get('dns_target_verified') is True)
    elif action == 'catalog':
        import entry_probe
        require(set(result.get('entries', {})) == set(after['edges']))
        entry_probe.catalogs(after['public'], after['inventory'], settings['catalog'].encode(),
                             context['catalog_key'], baseline['public'])
    elif action == 'commit':
        require(result.get('phase') == 'committed' and result.get('baseline') == value['request']['target'])
    elif action == 'finish': require(result.get('phase') == 'complete' and result.get('maintenance_ready') is True)
    else: raise ValueError('Unknown lifecycle proof kind')


def previous_turn_credential(root, attempt):
    _, path, _, plan, _, context = state(root, attempt)
    if not plan['rotate_turn_secret']:
        raise ValueError('Only a replacement verifies retired TURN credentials')
    content = tls_material.read_material(path / 'turn-previous-secret', private=True)
    if hashlib.sha256(content).hexdigest() != context['turn_before_sha256']:
        raise ValueError('Original TURN epoch changed; do not invent a rejection probe')
    import entry_turn
    return entry_turn.credential(content.decode())


def cancel(root, attempt, source, *, system_root=Path('/')):
    """Cancel only before TLS/credential delivery or any live-host claim.

    Wrong SSH pins, package or CA failures must be recoverable without editing
    a journal. After possible credential delivery use the forward-only resume.
    """
    path = directory(root, attempt)
    archive = path / 'cancelled-journal.json'
    current = root / 'entry-lifecycle/current.json'
    if archive.exists() or archive.is_symlink():
        old = managed_state.read(archive)
        if old['attempt'] != attempt or old['request']['source'] != source:
            raise ValueError('Cancelled attempt source differs')
        if not current.exists() or managed_state.read(current)['attempt'] != attempt:
            return {'schema': 1, 'attempt': attempt, 'phase': 'cancelled', 'live_hosts_unchanged': True}
    value, _, baseline, plan, _, context = state(root, attempt)
    if value['request']['source'] != source:
        raise ValueError('Cancel from the original frozen source')
    first_claim = next(index for index, step in enumerate(value['steps']) if step['action'] == 'claim')
    if value['position'] >= first_claim or (path / 'credential-delivery.json').exists() or (path / 'credential-delivery.json').is_symlink():
        raise ValueError('Credential delivery or a live-host claim may have started; resume forward instead of cancelling')
    pointer, actual, _ = managed_journal.current(root)
    if pointer != context['pointer'] or actual != baseline:
        raise ValueError('Baseline changed; preserve the lifecycle journal')
    network = managed_state.read(system_root / 'var/lib/voicechat-network/desired.json')
    if network['inventory'] != baseline['inventory'] or network['public_keys'] != context['public_keys']:
        raise ValueError('Live network changed; preserve the lifecycle journal')
    import managed_fence
    import role_deploy
    for name in entry_lifecycle.role_ids(baseline['inventory'], 'core'):
        role_root = root / 'core' if name == 'core' else root / 'edges' / name.removeprefix('edge-')
        if role_deploy.in_maintenance(role_root):
            raise ValueError('A live role is already claimed; resume forward')
        manifest = baseline['core'] if name == 'core' else baseline['edges'][name.removeprefix('edge-')]
        managed_fence._committed(role_root, manifest)
    managed_state.persist(archive, value)
    current.unlink(); tls_material.sync_directory(current.parent)
    return {'schema': 1, 'attempt': attempt, 'phase': 'cancelled', 'live_hosts_unchanged': True}
