"""Keep the owned ingress overlay when the neighboring application deploys.

The journal resumes the same fetched Git revision after an interruption. It does
not restore application databases or pretend to roll back unrelated migrations.
"""
import argparse
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import uuid

import managed_state
import network_bootstrap
import role_bootstrap
import role_prepare
from role_deploy import run
import shared_ingress as ingress
import topology


def _hash(content):
    return hashlib.sha256(content).hexdigest()


def _ids(target, execute):
    identifiers = execute(['docker', 'ps', '-aq', '--no-trunc', '--filter',
        'label=com.docker.compose.project=' + target['baseline']['project'], '--filter', 'label=com.docker.compose.service=caddy']).decode().split()
    if len(identifiers) != 1 or not re.fullmatch(r'[a-f0-9]{64}', identifiers[0]):
        raise ValueError('One managed Caddy container required')
    return identifiers


def _current(root, *, execute, health, system_root):
    if (root / 'pending.json').exists() or (root / 'pending.json').is_symlink():
        raise ValueError('Finish the interrupted ingress adoption before business deployment')
    record = managed_state.read(root / 'current.json')
    target, files, _, _, expected = ingress._attempt(root, record, system_root=system_root)
    if ingress.read_environment(Path(target['repo']) / 'deploy/.env') != expected:
        raise ValueError('Managed business environment changed; explicit configuration update required')
    for name, content in (('caddy/Caddyfile', files['Caddyfile']), ('compose.override.yaml', files['compose.override.yaml'])):
        if ingress.read_environment(root / 'runtime' / name) != content: raise ValueError('Managed ingress runtime changed')
    # Other deployments and host reboots may legitimately restart neighbors
    # between operations. Preserve the processes observed for this operation.
    observed = deepcopy(record)
    observed['baseline']['neighbors'] = ingress.snapshot({record['baseline']['project'], 'voicechat'},
        excluding=_ids(record, execute), execute=execute)
    ingress._verify_live(root, target, files, observed, managed=True, execute=execute, health=health)
    return observed, target, files


def _wrapper(root, operator):
    ingress.absolute_path(str(root))
    source = '/opt/voicechat/operators/' + operator['operator_sha256'] + '/infra/shared_update.py'
    return ('#!/bin/sh\nset -eu\numask 077\nexec /usr/bin/python3 -B ' + source + ' --root ' + str(root) + ' "$@"\n').encode()


def _origin(repo, *, execute):
    value = execute(['git', '--no-pager', '-C', str(repo), 'config', '--get', 'remote.origin.url']).decode().strip()
    if (len(value) > 1024 or any(character.isspace() for character in value) or
            not (re.fullmatch(r'git@[A-Za-z0-9.-]+:[A-Za-z0-9_./-]+', value) or
                 re.fullmatch(r'https://[A-Za-z0-9.-]+/[A-Za-z0-9_./-]+', value) or
                 re.fullmatch(r'/[A-Za-z0-9_./-]+', value))):
        raise ValueError('Credential-free deployment Git origin required')
    return value


def install(root, *, execute=run, health=ingress._https_health, system_root=Path('/')):
    """Install only an owned functional delegate after successful adoption."""
    root, system_root = Path(root).absolute(), Path(system_root).resolve()
    if root.resolve() != root: raise ValueError('Canonical shared ingress root required')
    with managed_state.locked(root):
        if (root / 'update.json').exists() or (root / 'update.json').is_symlink():
            raise ValueError('Finish the pending business deployment first')
        record, target, _ = _current(root, execute=execute, health=health, system_root=system_root)
        ingress.read_plan(root, root / 'plans' / record['plan'], system_root=system_root)
        operator = target['operator']
        if 'shared_update.py' not in operator['files']: raise ValueError('Restage and adopt with the reviewed manager sources')
        content = _wrapper(root, operator)
        receipt = {'schema': 1, 'root': str(root), 'operator': operator, 'origin': _origin(Path(target['repo']), execute=execute),
                   'wrapper_sha256': _hash(content)}
        directory = network_bootstrap.directory(system_root, 'usr/local/sbin', create=True)
        path = directory / 'voicechat-shared-deploy'
        existing = network_bootstrap.existing(path)
        previous = root / 'manager.json'
        if previous.exists() or previous.is_symlink():
            old = managed_state.read(previous)
            role_bootstrap.verify_record(system_root, old['operator'])
            if old['root'] != str(root) or existing not in (content, _wrapper(root, old['operator'])):
                raise ValueError('Existing manager wrapper changed or belongs to another root')
        elif existing not in (None, content):
            raise ValueError('Unowned manager executable must not be replaced')
        if existing != content: ingress._write(path, content, mode=0o755)
        if path.stat().st_mode & 0o777 != 0o755: raise ValueError('Manager wrapper permissions changed')
        managed_state.persist(previous, receipt)
        return receipt


def _manager(root, *, execute, system_root):
    receipt = managed_state.read(root / 'manager.json')
    topology.fields(receipt, ('schema', 'root', 'operator', 'origin', 'wrapper_sha256'))
    if type(receipt['schema']) is not int or receipt['schema'] != 1 or receipt['root'] != str(root):
        raise ValueError('Invalid manager owner')
    role_bootstrap.verify_record(system_root, receipt['operator'])
    content = _wrapper(root, receipt['operator'])
    path = system_root / 'usr/local/sbin/voicechat-shared-deploy'
    if (receipt['wrapper_sha256'] != _hash(content) or network_bootstrap.existing(path) != content or
            path.stat().st_mode & 0o777 != 0o755):
        raise ValueError('Manager executable differs from its owner')
    return receipt


def _git_state(target, record, *, execute):
    git = ['git', '--no-pager', '-C', target['repo']]
    if execute([*git, 'branch', '--show-current']).strip() != b'main': raise ValueError('Business main branch required')
    execute([*git, 'diff', '--cached', '--quiet'])
    changed = execute([*git, 'diff', '--no-ext-diff', '--name-only', 'HEAD', '--']).decode().splitlines()
    if set(changed) - {'deploy/Caddyfile'}: raise ValueError('Unrelated business working changes must be preserved')
    ingress._source_unchanged(target, record['baseline'], execute=execute)
    return git


def _preview(root, target, record, revision, git, *, execute, system_root):
    """Parse proposed Compose/routes before changing the business checkout."""
    repo = Path(target['repo'])
    business = execute([*git, 'show', revision + ':deploy/Caddyfile']).decode()
    configuration = ingress.legacy_config(business, target['public'])
    candidate = ingress._store_plan_locked(root, target, configuration, system_root=system_root)
    source = execute([*git, 'show', revision + ':deploy/docker-compose.yml'])
    with tempfile.TemporaryDirectory(prefix='voicechat-business-preview-') as temporary:
        temporary = Path(temporary)
        proposed = temporary / 'docker-compose.yml'; ingress._write(proposed, source)
        environment = temporary / 'snapshot.env'
        ingress._write(environment, ingress.read_environment(repo / 'deploy/.env'))
        before = ingress.compose_config(repo, environment, repo / 'deploy/docker-compose.yml',
            root / 'runtime/compose.override.yaml', execute=execute)
        after = ingress.compose_config(repo, environment, proposed, candidate / 'compose.override.yaml', execute=execute)
        old, new = before['services']['caddy'], after['services']['caddy']
        if (before['name'] != after['name'] or new['image'] != ingress.CADDY_IMAGE or
                new.get('restart') != 'unless-stopped' or new['ports'] != old['ports'] or
                new['volumes'] != old['volumes'] or new['networks'] != old['networks'] or
                new['environment'] != old['environment'] or
                {after['networks'][name]['name'] for name in new['networks']} != set(record['networks']) or
                any(after['volumes'][name]['name'] != record['volumes'][name] for name in record['volumes'])):
            raise ValueError('Business update changes protected ingress identity, ports, mounts or environment')
        path = temporary / 'Caddyfile'; ingress._write(path, configuration.encode())
        execute(['docker', 'run', '--rm', '--network', 'none', '--env', 'DOMAIN=' + record['baseline']['domain'],
            '--volume', str(path) + ':/etc/caddy/Caddyfile:ro', ingress.CADDY_IMAGE,
            'caddy', 'validate', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile'])
    return candidate, _hash(business.encode()), _hash(source)


def _pointer(record):
    value = deepcopy(record)
    value['baseline'].pop('neighbors', None)
    return value


def update(root, *, execute=run, health=ingress._https_health, system_root=Path('/')):
    """Resume or apply one fast-forward deploy, retaining the ingress overlay."""
    root, system_root = Path(root).absolute(), Path(system_root).resolve()
    if root.resolve() != root: raise ValueError('Canonical shared root required')
    with managed_state.locked(root):
        owner = _manager(root, execute=execute, system_root=system_root)
        journal = root / 'update.json'
        if not journal.exists() and not journal.is_symlink():
            record, target, files = _current(root, execute=execute, health=health, system_root=system_root)
            if owner['operator'] != target['operator']: raise ValueError('Manager and ingress sources differ')
            repo = Path(target['repo'])
            if _origin(repo, execute=execute) != owner['origin']: raise ValueError('Business Git origin changed')
            git = _git_state(target, record, execute=execute)
            execute([*git, 'fetch', '--no-tags', 'origin', 'main'])
            revision = execute([*git, 'rev-parse', 'FETCH_HEAD']).decode().strip()
            if not re.fullmatch(r'[a-f0-9]{40}', revision): raise ValueError('Invalid fetched business revision')
            execute([*git, 'merge-base', '--is-ancestor', record['baseline']['head'], revision])
            if revision == record['baseline']['head']: return record
            changed = execute([*git, 'diff', '--no-ext-diff', '--name-only', record['baseline']['head'], revision, '--']).decode().splitlines()
            candidate, source_hash, compose_hash = _preview(root, target, record, revision, git,
                execute=execute, system_root=system_root)
            application = any(path not in ('.github/workflows/deploy.yml', 'deploy/Caddyfile', 'README.md') and
                              not path.startswith('docs/') for path in changed)
            role_prepare.directory(root / 'updates')
            attempt = uuid.uuid4().hex; directory = root / 'updates' / attempt
            role_prepare.directory(directory)
            ingress._write(directory / 'original.Caddyfile', ingress.read_environment(repo / 'deploy/Caddyfile'))
            intent = {'schema': 1, 'attempt': attempt, 'old': record, 'plan': candidate.name, 'revision': revision,
                      'source_sha256': source_hash, 'compose_sha256': compose_hash,
                      'application': application, 'phase': 'prepared'}
            managed_state.persist(journal, intent)
        else:
            intent = managed_state.read(journal)
        topology.fields(intent, ('schema', 'attempt', 'old', 'plan', 'revision', 'source_sha256', 'compose_sha256', 'application', 'phase'))
        if (type(intent['schema']) is not int or intent['schema'] != 1 or intent['phase'] not in ('prepared', 'checkout', 'applying') or
                type(intent['application']) is not bool or not re.fullmatch(r'[a-f0-9]{32}', intent['attempt']) or
                not re.fullmatch(r'[a-f0-9]{40}', intent['revision']) or not re.fullmatch(r'[a-f0-9]{64}', intent['plan'])):
            raise ValueError('Invalid business update journal')
        record = intent['old']
        target, _, _, _, expected = ingress._attempt(root, record, system_root=system_root)
        if target['operator'] != owner['operator']: raise ValueError('Update owner sources changed')
        candidate_target, files = ingress.read_plan(root, root / 'plans' / intent['plan'], system_root=system_root, current_sources=False)
        if candidate_target != target: raise ValueError('Business update cannot change the VoiceChat ingress target')
        old_files = ingress.read_plan(root, root / 'plans' / record['plan'], system_root=system_root, current_sources=False)[1]
        if ingress.read_environment(root / 'runtime/compose.override.yaml') != files['compose.override.yaml']:
            raise ValueError('Managed Compose override changed during update')
        path = root / 'runtime/caddy/Caddyfile'
        if ingress.read_environment(path) not in (old_files['Caddyfile'], files['Caddyfile']):
            raise ValueError('Managed routes changed externally during update')
        repo = Path(target['repo']); git = ['git', '--no-pager', '-C', str(repo)]
        if _origin(repo, execute=execute) != owner['origin']: raise ValueError('Business Git origin changed')
        if ingress.read_environment(repo / 'deploy/.env') != expected: raise ValueError('Business environment changed during update')
        current = managed_state.read(root / 'current.json')
        updated = deepcopy(record)
        updated['plan'] = intent['plan']
        updated['baseline'].update(head=intent['revision'], source_sha256=intent['source_sha256'], compose_sha256=intent['compose_sha256'])
        if _pointer(current) not in (_pointer(record), _pointer(updated)):
            raise ValueError('Ingress pointer changed during business update')
        if intent['phase'] == 'prepared':
            _git_state(target, record, execute=execute)
            intent['phase'] = 'checkout'; managed_state.persist(journal, intent)
        if intent['phase'] == 'checkout':
            head = execute([*git, 'rev-parse', 'HEAD']).decode().strip()
            if head not in (record['baseline']['head'], intent['revision']): raise ValueError('Business revision changed during checkout')
            source = repo / 'deploy/Caddyfile'
            observed = ingress.read_environment(source)
            old = ingress.read_environment(root / 'updates' / intent['attempt'] / 'original.Caddyfile')
            if _hash(old) != record['baseline']['source_sha256']: raise ValueError('Business source recovery snapshot changed')
            tracked = execute([*git, 'show', head + ':deploy/Caddyfile'])
            if observed not in (old, tracked): raise ValueError('Business Caddyfile changed externally')
            execute([*git, 'diff', '--cached', '--quiet'])
            changed = execute([*git, 'diff', '--no-ext-diff', '--name-only', 'HEAD', '--']).decode().splitlines()
            if set(changed) - {'deploy/Caddyfile'}: raise ValueError('Unrelated working changes during checkout')
            if observed != tracked: execute([*git, 'restore', '--source=HEAD', '--', 'deploy/Caddyfile'])
            execute([*git, 'merge', '--ff-only', intent['revision']])
            intent['phase'] = 'applying'; managed_state.persist(journal, intent)
        _git_state(target, updated, execute=execute)
        if ingress.read_environment(path) not in (old_files['Caddyfile'], files['Caddyfile']):
            raise ValueError('Managed routes changed externally during update')
        command = ingress._compose(target, repo / 'deploy/.env', root / 'runtime/compose.override.yaml')
        environment = {**os.environ, 'PWD': str(repo / 'deploy')}
        if intent['application']:
            execute([*command, 'pull'], env=environment)
            execute([*command, 'up', '-d', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '180', '--remove-orphans'], env=environment)
        # Directory mount remains attached across atomic replacement. Reload is
        # required even when Compose's service hash has not changed.
        if ingress.read_environment(path) != files['Caddyfile']:
            ingress._write(path, files['Caddyfile'])
        updated['baseline']['neighbors'] = ingress.snapshot({record['baseline']['project'], 'voicechat'},
            excluding=_ids(updated, execute), execute=execute) if intent['application'] else record['baseline']['neighbors']
        reload = [*command, 'exec', '-T', 'caddy', 'caddy', 'reload', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile']
        try:
            if intent['application'] or old_files['Caddyfile'] != files['Caddyfile']:
                execute(reload, env=environment)
            ingress._verify_live(root, target, files, updated, managed=True, execute=execute, health=health)
        except Exception:
            if (ingress.read_environment(repo / 'deploy/.env') != expected or
                    ingress.read_environment(root / 'runtime/compose.override.yaml') != files['compose.override.yaml']):
                raise ValueError('Refusing recovery commands with an externally changed Compose environment')
            _git_state(target, updated, execute=execute)
            if ingress.read_environment(path) not in (old_files['Caddyfile'], files['Caddyfile']):
                raise ValueError('Refusing to overwrite externally changed routes during recovery')
            # Keep the fetched target pending, but restore the known routes so
            # a rejected/lost reload cannot leave a bad config for the next boot.
            ingress._write(path, old_files['Caddyfile'])
            execute(reload, env=environment)
            ingress._verify_live(root, target, old_files, updated, managed=True, execute=execute, health=health)
            raise
        managed_state.persist(root / 'current.json', updated)
        journal.unlink(); ingress._sync_directory(root)
        return updated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('command', choices=('avito-update',))
    args = parser.parse_args()
    # The wrapper always executes the sealed package which owns this host.
    owner = managed_state.read(args.root / 'manager.json')
    expected = Path('/opt/voicechat/operators') / owner['operator']['operator_sha256'] / 'infra/shared_update.py'
    if Path(__file__).resolve() != expected: raise ValueError('Run the installed immutable manager')
    update(args.root)
    print('Business deployment healthy; managed VoiceChat ingress preserved.')


if __name__ == '__main__': main()
