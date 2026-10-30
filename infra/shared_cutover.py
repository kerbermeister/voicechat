"""Move the owned cohost TLS port from Caddy to the warmed shared frontend.

This controls only ingress. Core adoption/data rollback and multi-host release
ordering remain the caller's responsibility. Interrupted rollback releases 443
from HAProxy before restoring Caddy, without changing application databases.
"""
from copy import deepcopy
import json
import os
from pathlib import Path
import re

import edge_deploy
import managed_state
import role_deploy
import role_release
import shared_front
import shared_ingress as ingress
import shared_update
import topology


def business_healthy(target, baseline, *, execute):
    execute(['curl', '--fail', '--silent', '--show-error', '--max-time', '10', '--output', '/dev/null',
             '--noproxy', '*', '--resolve', baseline['domain'] + ':443:127.0.0.1',
             'https://' + baseline['domain'] + '/'])


def _caddy_owned(root, old, updated, profile, *, execute):
    """Accept our two known Caddy layouts, including interrupted recreation."""
    ids = execute(['docker', 'ps', '-aq', '--no-trunc', '--filter',
        'label=com.docker.compose.project=' + old['baseline']['project'],
        '--filter', 'label=com.docker.compose.service=caddy']).decode().split()
    if not ids and (root / 'configuration.json').exists(): return
    if len(ids) != 1 or not re.fullmatch(r'[a-f0-9]{64}', ids[0]):
        raise ValueError('One owned Caddy required during port cutover')
    template = ('{"id":{{json .Id}},"running":{{json .State.Running}},"image":{{json .Image}},'
                '"labels":{{json .Config.Labels}},"mounts":{{json .Mounts}},'
                '"ports":{{json .HostConfig.PortBindings}},"restart":{{json .HostConfig.RestartPolicy}},'
                '"networks":{{json .NetworkSettings.Networks}}}')
    current = json.loads(execute(['docker', 'inspect', '--format', template, ids[0]]))
    mounts = {item['Destination']: item for item in current['mounts']}
    if (current['id'] != ids[0] or current['image'] != old['baseline']['caddy_image_id'] or
            current['labels'].get('com.docker.compose.project') != old['baseline']['project'] or
            current['labels'].get('com.docker.compose.service') != 'caddy' or
            current['restart'] != old['restart'] or set(mounts) != {'/data', '/config', '/etc/caddy'} or
            mounts['/etc/caddy'].get('Type') != 'bind' or mounts['/etc/caddy'].get('RW') is not False or
            mounts['/etc/caddy'].get('Source') != str(root / 'runtime/caddy')):
        raise ValueError('Unknown Caddy process or mount must not be replaced during port cutover')
    for destination, name in (('/data', 'caddy_data'), ('/config', 'caddy_config')):
        if (mounts[destination].get('Type') != 'volume' or mounts[destination].get('RW') is not True or
                mounts[destination].get('Name') != old['volumes'][name]):
            raise ValueError('Caddy data volume changed during port cutover')
    layouts = [record for record in (old, updated) if current['ports'] == record['ports'] and
               (set(current['networks']) == set(record['networks']) or
                (not current['running'] and not current['networks']))]
    if not layouts: raise ValueError('Unknown Caddy ports or networks must not be overwritten')
    if (current['running'] and profile['network'] in current['networks'] and
            current['networks'][profile['network']].get('IPAddress') != profile['legacy_ip']):
        raise ValueError('Caddy shared bridge address changed during port cutover')
    if current['running']:
        active = json.loads(execute(['docker', 'exec', ids[0], 'wget', '-q', '-O', '-', '-T', '5', '-Y', 'off',
                                    'http://127.0.0.1:2019/config/']))
        known = []
        for record in layouts:
            source = root / 'plans' / record['plan'] / 'Caddyfile'
            known.append(json.loads(execute(['docker', 'run', '--rm', '--network', 'none',
                '--env', 'DOMAIN=' + old['baseline']['domain'], '--volume', str(source) + ':/etc/caddy/Caddyfile:ro',
                ingress.CADDY_IMAGE, 'caddy', 'adapt', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile'])))
        if active not in known: raise ValueError('Unknown active Caddy routes must not be overwritten')


def _edge(root, target, front_plan, front_record, warm_model):
    state = edge_deploy.read_state(root, target['edge_id'])
    if state['pending'] is not None or state['current'] is None:
        raise ValueError('A committed edge without pending deployment required before port cutover')
    record = state['current']
    manifest = record['manifest']
    if (manifest['service_id'] != target['public']['service_id'] or
            manifest['identity'] != {key: target['public'][key] for key in ('canonical_origin', 'matrix_server_name')} or
            front_record['service_id'] != manifest['service_id'] or front_record['edge_id'] != manifest['edge_id'] or
            manifest['files']['infra/haproxy.cfg'] != front_record['files']['haproxy.cfg']):
        raise ValueError('Warm frontend does not belong to the committed edge')
    release = role_deploy.release_path(root, record)
    original = json.loads(ingress.read_environment(release / 'infra/compose.shared-front.json'))
    expected = deepcopy(original)
    expected['services']['ingress']['ports'] = [f"127.0.0.1:{front_record['warm_port']}:8443/tcp"]
    if expected != warm_model: raise ValueError('Warm frontend differs from the committed edge source')
    original['services']['ingress']['ports'].append(expected['services']['ingress']['ports'][0])
    if json.loads(ingress.read_environment(front_plan / 'compose.public.json')) != original:
        raise ValueError('Public frontend differs from the committed edge source')
    return record, original


def _read(root, plan, front_plan, intent, *, execute, system_root):
    topology.fields(intent, ('schema', 'operation', 'old', 'plan', 'front_plan', 'edge_manifest_sha256', 'phase'))
    if (type(intent['schema']) is not int or intent['schema'] != 1 or intent['operation'] != 'shared-port-cutover' or
            intent['phase'] not in ('caddy', 'front', 'verify', 'rollback') or
            not isinstance(intent['edge_manifest_sha256'], str) or not re.fullmatch(r'[a-f0-9]{64}', intent['edge_manifest_sha256']) or
            intent['plan'] != plan.name or intent['front_plan'] != front_plan.name):
        raise ValueError('Resume the same valid shared port cutover')
    old = intent['old']
    before, old_files, _, _, environment = ingress._attempt(root, old, system_root=system_root)
    target, files = ingress.read_plan(root, plan, system_root=system_root)
    owner = shared_update._manager(root, execute=execute, system_root=Path(system_root).resolve())
    if owner['operator'] != target['operator'] or before['operator'] != target['operator']:
        raise ValueError('Install the reviewed manager before shared port cutover')
    if before['mode'] != 'legacy-certs' or target['mode'] != 'shared':
        raise ValueError('Shared port cutover requires the prepared legacy certificate mode')
    if ({key: value for key, value in before.items() if key not in ('mode', 'shared_tls')} !=
            {key: value for key, value in target.items() if key not in ('mode', 'shared_tls')}):
        raise ValueError('Port cutover cannot change the installation, host or public topology')
    if set(old['ports']) != {'80/tcp', '443/tcp'} or files['compose.env-line'] != old_files['compose.env-line']:
        raise ValueError('Port cutover requires the known legacy ports and persistent environment')
    business = execute(['git', '--no-pager', '-C', target['repo'], 'show', old['baseline']['head'] + ':deploy/Caddyfile']).decode()
    if ingress.configuration(business, target).encode() != files['Caddyfile']:
        raise ValueError('Shared port cutover differs from reviewed business routes')
    ingress._source_unchanged(target, old['baseline'], execute=execute)
    if ingress.read_environment(Path(target['repo']) / 'deploy/.env') != environment:
        raise ValueError('Business environment changed during port cutover')
    for name, key in (('caddy/Caddyfile', 'Caddyfile'), ('compose.override.yaml', 'compose.override.yaml')):
        if ingress.read_environment(root / 'runtime' / name) not in (old_files[key], files[key]):
            raise ValueError('Unknown ingress runtime must not be overwritten during port cutover')
    front_root = root / 'front'
    front_record, warm_model = shared_front.read_plan(front_root, front_plan, system_root=system_root)
    front_state = managed_state.read(front_root / 'warm.json')
    if front_state not in ({'schema': 1, 'plan': front_plan.name, 'phase': phase} for phase in ('running', 'public')):
        raise ValueError('Owned warmed frontend required before port cutover')
    shared_front._networks(warm_model, execute=execute, owned=True)
    edge_root = Path(target['edge_root'])
    edge, public_model = _edge(edge_root, target, front_plan, front_record, warm_model)
    if role_release.json_digest(edge['manifest']) != intent['edge_manifest_sha256']:
        raise ValueError('Committed edge changed during port cutover')
    updated = deepcopy(old)
    updated['plan'] = plan.name
    updated['ports'] = {'80/tcp': old['ports']['80/tcp']}
    updated['networks'] = sorted({*old['networks'], target['shared_tls']['network']})
    current = managed_state.read(root / 'current.json')
    if shared_update._pointer(current) not in (
            shared_update._pointer(old), shared_update._pointer(updated)):
        raise ValueError('Ingress pointer changed during port cutover')
    if ((front_state['phase'] == 'public' and current['plan'] != plan.name) or
            (intent['phase'] == 'rollback' and current['plan'] == plan.name)):
        raise ValueError('Port cutover commit and rollback ownership conflict')
    _caddy_owned(root, old, updated, target['shared_tls'], execute=execute)
    # The only accepted process states are our old loopback listener or our new
    # public one. A missing container can be resumed after a failed recreation.
    try:
        shared_front._container(front_plan, warm_model, execute=execute, required=False)
    except ValueError:
        shared_front._container(front_plan, public_model, execute=execute, required=False)
    return target, old_files, files, updated, edge, front_record, warm_model, public_model


def activate(root, plan, front_plan, *, execute=role_deploy.run, check_edge=edge_deploy.healthy,
             check_business=business_healthy, system_root=Path('/')):
    """Commit only after trusted edge readiness and neighboring HTTPS succeed."""
    root = Path(root).absolute()
    if root.resolve() != root:
        raise ValueError('Canonical shared ingress required')
    with managed_state.locked(root):
        return _activate_locked(root, plan, front_plan, execute=execute, check_edge=check_edge,
                                check_business=check_business, system_root=system_root)


def _activate_locked(root, plan, front_plan, *, execute=role_deploy.run, check_edge=edge_deploy.healthy,
                     check_business=business_healthy, system_root=Path('/')):
    """Caller holds the shared ingress lock throughout the full installation migration.

    Reusing that lock fences neighboring deployments across core maintenance and
    port takeover; the child locks retain the normal frontend/edge/TLS ordering.
    """
    root, plan, front_plan = (Path(path).absolute() for path in (root, plan, front_plan))
    if root.resolve() != root or front_plan.parent.parent != root / 'front':
        raise ValueError('Canonical shared ingress and its owned frontend required')
    target, _ = ingress.read_plan(root, plan, system_root=system_root)
    edge_root = Path(target['edge_root'])
    with managed_state.locked(root / 'front'), managed_state.locked(edge_root), managed_state.locked(edge_root / 'runtime/tls'):
        if any((root / name).exists() or (root / name).is_symlink() for name in ('pending.json', 'update.json')):
            raise ValueError('Finish pending ingress adoption or business deployment before port cutover')
        journal = root / 'configuration.json'
        if journal.exists() or journal.is_symlink():
            intent = managed_state.read(journal)
        else:
            old, serving, _ = shared_update._current(root, execute=execute, health=check_business, system_root=system_root)
            front_record, warm_model = shared_front.read_plan(root / 'front', front_plan, system_root=system_root)
            shared_front._networks(warm_model, execute=execute, owned=True)
            edge, public_model = _edge(edge_root, target, front_plan, front_record, warm_model)
            if old['plan'] == plan.name and serving['mode'] == 'shared':
                if managed_state.read(root / 'front/warm.json') != {'schema': 1, 'plan': front_plan.name, 'phase': 'public'}:
                    raise ValueError('Committed public frontend ownership changed')
                shared_front._container(front_plan, public_model, execute=execute, required=True)
                check_edge(edge_root, edge, execute=execute)
                return old
            shared_front._container(front_plan, warm_model, execute=execute, required=True)
            check_edge(edge_root, edge, execute=execute, warm_port=front_record['warm_port'])
            intent = {'schema': 1, 'operation': 'shared-port-cutover', 'old': old, 'plan': plan.name,
                      'front_plan': front_plan.name, 'edge_manifest_sha256': role_release.json_digest(edge['manifest']), 'phase': 'caddy'}
            _read(root, plan, front_plan, intent, execute=execute, system_root=system_root)
            execute(['docker', 'run', '--rm', '--network', 'none', '--env', 'DOMAIN=' + old['baseline']['domain'],
                '--mount', 'type=volume,source=' + old['volumes']['caddy_data'] + ',target=/data,readonly,volume-nocopy',
                '--volume', str(plan / 'Caddyfile') + ':/etc/caddy/Caddyfile:ro', ingress.CADDY_IMAGE,
                'caddy', 'validate', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile'])
            managed_state.persist(journal, intent)
        target, old_files, files, updated, edge, front_record, warm_model, public_model = _read(
            root, plan, front_plan, intent, execute=execute, system_root=system_root)
        old = intent['old']
        command = ingress._compose(target, Path(target['repo']) / 'deploy/.env', root / 'runtime/compose.override.yaml')
        environment = {**os.environ, 'PWD': str(Path(target['repo']) / 'deploy')}
        def front(public):
            execute([*shared_front._command(front_plan, public=public), 'up', '-d', '--no-deps', '--no-build',
                '--pull', 'never', '--wait', '--wait-timeout', '30', 'ingress'], env={**os.environ, 'COMPOSE_DISABLE_ENV_FILE': 'true'})
            shared_front._container(front_plan, public_model if public else warm_model, execute=execute, required=True)
        def caddy(content):
            for name, key in (('caddy/Caddyfile', 'Caddyfile'), ('compose.override.yaml', 'compose.override.yaml')):
                ingress._write(root / 'runtime' / name, content[key])
            execute([*command, 'up', '-d', '--no-deps', '--no-build', '--pull', 'never',
                     '--wait', '--wait-timeout', '60', 'caddy'], env=environment)
        def verify(record, content, *, health):
            ingress._verify_live(root, target, content, record, managed=True, execute=execute, health=health)
        def rollback():
            _read(root, plan, front_plan, intent, execute=execute, system_root=system_root)
            front(False)  # Release :443 before Caddy tries to bind it again.
            caddy(old_files)
            verify(old, old_files, health=check_business)
            managed_state.persist(root / 'front/warm.json', {'schema': 1, 'plan': front_plan.name, 'phase': 'running'})
            journal.unlink(); ingress._sync_directory(root)
        if intent['phase'] == 'rollback':
            rollback()
            raise RuntimeError('Interrupted shared port rollback completed; retry the same plan explicitly')
        committed = managed_state.read(root / 'current.json')['plan'] == plan.name
        try:
            if not committed:
                if intent['phase'] == 'caddy':
                    caddy(files)
                    verify(updated, files, health=lambda *args, **kwargs: None)
                    intent['phase'] = 'front'; managed_state.persist(journal, intent)
                if intent['phase'] == 'front':
                    front(True)
                    intent['phase'] = 'verify'; managed_state.persist(journal, intent)
            verify(updated, files, health=check_business)
            shared_front._container(front_plan, public_model, execute=execute, required=True)
            check_edge(edge_root, edge, execute=execute)
            managed_state.persist(root / 'current.json', updated)
            managed_state.persist(root / 'front/warm.json', {'schema': 1, 'plan': front_plan.name, 'phase': 'public'})
            journal.unlink(); ingress._sync_directory(root)
        except Exception:
            if managed_state.read(root / 'current.json')['plan'] != plan.name:
                intent['phase'] = 'rollback'; managed_state.persist(journal, intent)
                rollback()
            raise
        return updated
