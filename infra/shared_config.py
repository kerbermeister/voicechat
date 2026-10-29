"""Prepare Caddy-managed cohost certificates before the shared port cutover."""
import argparse
from copy import deepcopy
import hashlib
import os
from pathlib import Path
import re
import socket
import ssl
import time
from urllib.parse import urlsplit

import managed_state
from role_deploy import run
import shared_ingress as ingress
import shared_update
import topology


def certificates_healthy(target, *, timeout=180):
    """Require real trusted SNI handshakes, including the newly managed TURN name."""
    edge = next(item for item in target['public']['edges'] if item['id'] == target['edge_id'])
    names = sorted({urlsplit(target['public']['canonical_origin']).hostname, edge['turn_host']})
    context = ssl.create_default_context()
    deadline = time.monotonic() + timeout
    while True:
        try:
            result = {}
            for name in names:
                with socket.create_connection(('127.0.0.1', 443), timeout=5) as transport:
                    with context.wrap_socket(transport, server_hostname=name) as connection:
                        result[name] = hashlib.sha256(connection.getpeercert(binary_form=True)).hexdigest()
            return result
        except OSError:
            if time.monotonic() >= deadline: raise RuntimeError('Cohost certificate issuance did not become ready') from None
            time.sleep(1)


def _read(root, intent, *, execute, system_root):
    topology.fields(intent, ('schema', 'old', 'plan', 'phase'))
    if (type(intent['schema']) is not int or intent['schema'] != 1 or
            intent['phase'] not in ('applying', 'rollback') or not re.fullmatch(r'[a-f0-9]{64}', intent['plan'])):
        raise ValueError('Invalid ingress certificate preparation journal')
    old = intent['old']
    before, old_files, _, _, expected = ingress._attempt(root, old, system_root=system_root)
    target, files = ingress.read_plan(root, root / 'plans' / intent['plan'], system_root=system_root)
    owner = shared_update._manager(root, execute=execute, system_root=Path(system_root).resolve())
    if owner['operator'] != target['operator']:
        raise ValueError('Install the reviewed manager before changing ingress configuration')
    if before['mode'] not in ('legacy', 'legacy-certs') or target['mode'] != 'legacy-certs':
        raise ValueError('Certificate preparation cannot perform the shared port cutover')
    if ({key: value for key, value in before.items() if key not in ('mode', 'operator')} !=
            {key: value for key, value in target.items() if key not in ('mode', 'operator')}):
        raise ValueError('Certificate preparation cannot change the installation or host')
    if files['compose.override.yaml'] != old_files['compose.override.yaml'] or files['compose.env-line'] != old_files['compose.env-line']:
        raise ValueError('Certificate preparation cannot change Caddy ports or mounts')
    business = execute(['git', '--no-pager', '-C', target['repo'], 'show', old['baseline']['head'] + ':deploy/Caddyfile']).decode()
    if ingress.legacy_certificates_config(business, target['public'], target['edge_id']).encode() != files['Caddyfile']:
        raise ValueError('Certificate plan does not match reviewed business routes')
    if (ingress.read_environment(Path(target['repo']) / 'deploy/.env') != expected or
            ingress.read_environment(root / 'runtime/compose.override.yaml') != files['compose.override.yaml']):
        raise ValueError('Managed Compose environment changed during certificate preparation')
    ingress._source_unchanged(target, old['baseline'], execute=execute)
    if ingress.read_environment(root / 'runtime/caddy/Caddyfile') not in (old_files['Caddyfile'], files['Caddyfile']):
        raise ValueError('Unknown Caddy routes must not be overwritten')
    updated = deepcopy(old); updated['plan'] = intent['plan']
    current = managed_state.read(root / 'current.json')
    if shared_update._pointer(current) not in (shared_update._pointer(old), shared_update._pointer(updated)):
        raise ValueError('Ingress pointer changed during certificate preparation')
    return before, target, old_files, files, updated


def prepare_certificates(root, plan, *, execute=run, health=ingress._https_health,
                         certify=certificates_healthy, system_root=Path('/')):
    """Reload only certificate sinks, keeping all container processes and data.

    A handled failure restores known routes. Process death resumes the same
    immutable plan; an interrupted rollback finishes before a fresh attempt.
    """
    root, plan = Path(root).absolute(), Path(plan).absolute()
    if root.resolve() != root or not root.is_dir(): raise ValueError('Prepared canonical shared root required')
    with managed_state.locked(root):
        if (root / 'update.json').exists() or (root / 'update.json').is_symlink():
            raise ValueError('Finish the pending business deployment before certificate preparation')
        journal = root / 'configuration.json'
        if journal.exists() or journal.is_symlink():
            intent = managed_state.read(journal)
            if plan != root / 'plans' / intent['plan']: raise ValueError('Resume the same certificate plan')
        else:
            old, _, _ = shared_update._current(root, execute=execute, health=health, system_root=system_root)
            target, files = ingress.read_plan(root, plan, system_root=system_root)
            if old['plan'] == plan.name:
                if target['mode'] != 'legacy-certs': raise ValueError('Certificate preparation plan required')
                return {'current': old, 'certificates': certify(target)}
            intent = {'schema': 1, 'old': old, 'plan': plan.name, 'phase': 'applying'}
            _read(root, intent, execute=execute, system_root=system_root)
            # Validate provisioned modules before replacing the mounted file.
            execute(['docker', 'run', '--rm', '--network', 'none', '--env', 'DOMAIN=' + old['baseline']['domain'],
                '--volume', str(plan / 'Caddyfile') + ':/etc/caddy/Caddyfile:ro', ingress.CADDY_IMAGE,
                'caddy', 'validate', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile'])
            managed_state.persist(journal, intent)
        before, target, old_files, files, updated = _read(root, intent, execute=execute, system_root=system_root)
        command = ingress._compose(target, Path(target['repo']) / 'deploy/.env', root / 'runtime/compose.override.yaml')
        environment = {**os.environ, 'PWD': str(Path(target['repo']) / 'deploy')}
        reload = [*command, 'exec', '-T', 'caddy', 'caddy', 'reload', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile']
        processes = ingress.snapshot({'voicechat', updated['baseline']['project']}, execute=execute)
        neighbors = ingress.snapshot({'voicechat', updated['baseline']['project']}, excluding=shared_update._ids(updated, execute), execute=execute)
        updated['baseline']['neighbors'] = neighbors
        def verify(content, record):
            ingress._verify_live(root, target, content, record, managed=True, execute=execute, health=health)
            if ingress.snapshot({'voicechat', updated['baseline']['project']}, execute=execute) != processes:
                raise ValueError('Certificate reload changed a container process')
        def rollback():
            _read(root, intent, execute=execute, system_root=system_root)
            ingress._write(root / 'runtime/caddy/Caddyfile', old_files['Caddyfile'])
            execute(reload, env=environment)
            restored = deepcopy(intent['old']); restored['baseline']['neighbors'] = neighbors
            verify(old_files, restored)
            journal.unlink(); ingress._sync_directory(root)
        if intent['phase'] == 'rollback':
            rollback()
            raise RuntimeError('Interrupted certificate rollback completed; retry the plan')
        # A crash after committing the pointer only requires validation/cleanup.
        if managed_state.read(root / 'current.json')['plan'] == plan.name:
            verify(files, updated)
            certificates = certify(target)
            journal.unlink(); ingress._sync_directory(root)
            return {'current': updated, 'certificates': certificates}
        try:
            ingress._write(root / 'runtime/caddy/Caddyfile', files['Caddyfile'])
            execute(reload, env=environment)
            verify(files, updated)
            certificates = certify(target)
            verify(files, updated)
            managed_state.persist(root / 'current.json', updated)
            journal.unlink(); ingress._sync_directory(root)
        except Exception:
            if managed_state.read(root / 'current.json')['plan'] != plan.name:
                intent['phase'] = 'rollback'; managed_state.persist(journal, intent)
                rollback()
            raise
        return {'current': updated, 'certificates': certificates}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--plan', type=Path, required=True)
    args = parser.parse_args()
    prepare_certificates(args.root, args.plan)
    print('Cohost HTTPS certificates verified; working legacy routes retained.')


if __name__ == '__main__': main()
