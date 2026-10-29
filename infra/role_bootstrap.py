"""Install an owned per-role systemd boot gate without restarting applications.

Systemd owns both runtime crash recovery and ordering at daemon startup. A failed VoiceChat network gates only VoiceChat on a shared Docker host.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

import managed_state
import network_bootstrap
import topology
from tunnel_runtime import command

LEGACY_SOURCES = ('role_boot.py', 'role_bootstrap.py', 'core_deploy.py', 'edge_deploy.py',
    'role_deploy.py', 'role_prepare.py', 'role_release.py', 'render_roles.py', 'role_config.py',
    'render_edge.py', 'edge_config.py', 'deploy.py', 'tls_activation.py', 'tls_runtime.py',
    'tls_material.py', 'client_config.py', 'topology.py', 'node_inventory.py', 'managed_state.py',
    'network_bootstrap.py', 'network_runtime.py', 'firewall_runtime.py', 'firewall_config.py',
    'tunnel_runtime.py', 'tunnel_config.py')
SHARED_SOURCES = (*LEGACY_SOURCES, 'shared_ingress.py')
MANAGER_SOURCES = (*SHARED_SOURCES, 'shared_update.py')
CONFIG_SOURCES = (*MANAGER_SOURCES, 'shared_config.py')
CAPTURE_SOURCES = (*CONFIG_SOURCES, 'cohost_tls.py')
SOURCES = (*CAPTURE_SOURCES, 'shared_front.py', 'shared_cutover.py')


def unit_name(role, edge_id):
    if role not in ('core', 'edge') or (role == 'core' and edge_id is not None) or (
            role == 'edge' and (not isinstance(edge_id, str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,31}', edge_id))):
        raise ValueError('Invalid boot role identity')
    return 'voicechat-' + ('core' if role == 'core' else 'edge-' + edge_id) + '.service'


def plan(root, role, edge_id):
    name = unit_name(role, edge_id)
    if root.resolve() != root or not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(root)):
        raise ValueError('Owned absolute ASCII role path required for systemd')
    contents = {key: (Path(__file__).parent / key).read_bytes() for key in SOURCES}
    hashes = {key: hashlib.sha256(value).hexdigest() for key, value in contents.items()}
    digest = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    code = 'opt/voicechat/operators/' + digest + '/infra'
    unit = f'''[Unit]
Description=Start committed VoiceChat {role} after its private network
Requires=docker.service voicechat-network.service
After=docker.service voicechat-network.service
PartOf=docker.service

[Service]
Type=notify
NotifyAccess=main
Restart=on-failure
RestartSec=2
ExecStart=/usr/bin/python3 /{code}/role_boot.py --root {root} --role {role}{' --edge ' + edge_id if edge_id else ''} --watch
TimeoutStartSec=420
Environment=PYTHONDONTWRITEBYTECODE=1
UMask=0077

[Install]
WantedBy=docker.service
'''.encode()
    target = {'schema': 1, 'role': role, 'edge_id': edge_id, 'root': str(root),
              'operator_sha256': digest, 'files': hashes, 'unit_sha256': hashlib.sha256(unit).hexdigest()}
    return name, code, contents, unit, target


def verify_record(system_root, record):
    topology.fields(record, ('schema', 'role', 'edge_id', 'root', 'operator_sha256', 'files', 'unit_sha256'))
    name = unit_name(record['role'], record['edge_id'])
    if type(record['schema']) is not int or record['schema'] != 1 or not isinstance(record['files'], dict):
        raise ValueError('Invalid boot ownership record')
    if set(record['files']) not in (set(SOURCES), set(CAPTURE_SOURCES), set(CONFIG_SOURCES), set(MANAGER_SOURCES), set(SHARED_SOURCES), set(LEGACY_SOURCES)) or any(not isinstance(value, str) or not re.fullmatch(r'[a-f0-9]{64}', value) for value in record['files'].values()):
        raise ValueError('Invalid boot source hashes')
    if hashlib.sha256(json.dumps(record['files'], sort_keys=True).encode()).hexdigest() != record['operator_sha256']:
        raise ValueError('Boot source identity changed')
    directory = network_bootstrap.directory(system_root, 'opt/voicechat/operators/' + record['operator_sha256'] + '/infra')
    if not directory.is_dir() or {item.name for item in directory.iterdir()} != set(record['files']):
        raise ValueError('Immutable operator source set changed')
    for key, checksum in record['files'].items():
        data = network_bootstrap.existing(directory / key)
        if data is None or hashlib.sha256(data).hexdigest() != checksum: raise ValueError('Operator source changed')
    return name


def check_sources(system_root, code, contents):
    operator = network_bootstrap.directory(system_root, code)
    if operator.exists() and {item.name for item in operator.iterdir()} - set(contents):
        raise ValueError('Unexpected import in immutable operator source')
    for key, value in contents.items():
        data = network_bootstrap.existing(operator / key)
        if data not in (None, value): raise ValueError('Immutable operator source collision')


def install_sources(system_root, code, contents):
    """Stage the same reviewed package without activating a role or Docker."""
    check_sources(system_root, code, contents)
    operator = network_bootstrap.directory(system_root, code, create=True)
    for key, value in contents.items():
        if network_bootstrap.existing(operator / key) is None:
            network_bootstrap.create_file(operator / key, value)


def ready(root, role, edge_id=None, *, system_root=Path('/'), run=command):
    root, system_root = Path(root).absolute(), Path(system_root).resolve()
    name, code, contents, unit, target = plan(root, role, edge_id)
    directory = root / 'runtime/boot'
    if (directory / 'pending.json').exists() or (directory / 'pending.json').is_symlink():
        raise ValueError('Finish the interrupted role boot installation')
    record = managed_state.read(directory / 'current.json')
    if record != target: raise ValueError('Install the reviewed role boot operator before deployment')
    verify_record(system_root, record)
    actual = network_bootstrap.existing(system_root / 'etc/systemd/system' / name)
    if actual != unit: raise ValueError('Owned boot unit changed')
    run('systemctl', 'is-enabled', '--quiet', name)


def install(root, role, edge_id=None, *, system_root=Path('/'), run=command):
    root, system_root = Path(root).absolute(), Path(system_root).resolve()
    name, code, contents, unit, target = plan(root, role, edge_id)
    with managed_state.locked(root):
        owner = managed_state.read(root / 'role.json')
        if owner.get('role') != role or owner.get('edge_id') != edge_id:
            raise ValueError('Prepared role ownership required before boot installation')
        with managed_state.locked(root / 'runtime/boot') as state_root:
            current, pending = state_root / 'current.json', state_root / 'pending.json'
            previous = managed_state.read(current) if current.exists() or current.is_symlink() else None
            if previous:
                if verify_record(system_root, previous) != name or previous['root'] != str(root):
                    raise ValueError('Boot service belongs to another role')
            if pending.exists() or pending.is_symlink():
                journal = managed_state.read(pending)
                topology.fields(journal, ('target', 'previous'))
                if journal != {'target': target, 'previous': previous}:
                    # A crash after current commit still resumes the same intent.
                    if journal.get('target') != target or previous != target:
                        raise ValueError('Resume the same pending boot source installation')
            else:
                journal = {'target': target, 'previous': previous}
            destination = system_root / 'etc/systemd/system' / name
            network_bootstrap.directory(system_root, destination.parent.relative_to(system_root))
            actual = network_bootstrap.existing(destination)
            allowed = {None, unit}
            before = journal['previous']
            if before is not None:
                verify_record(system_root, before)
                if actual is not None and hashlib.sha256(actual).hexdigest() == before['unit_sha256']:
                    allowed.add(actual)
            if actual not in allowed or (before is None and actual is not None and not pending.exists()):
                raise ValueError('Refusing to replace an unclaimed or modified boot unit')
            check_sources(system_root, code, contents)
            managed_state.persist(pending, journal)
            install_sources(system_root, code, contents)
            network_bootstrap.directory(system_root, destination.parent.relative_to(system_root), create=True)
            if actual is None: network_bootstrap.create_file(destination, unit)
            elif actual != unit: network_bootstrap.replace_file(destination, unit)
            run('systemd-analyze', 'verify', '--man=no', str(destination))
            run('systemctl', 'daemon-reload')
            run('systemctl', 'enable', name)
            run('systemctl', 'is-enabled', '--quiet', name)
            managed_state.persist(current, target)
            pending.unlink()
            descriptor = os.open(state_root, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(descriptor)
            finally: os.close(descriptor)
    return target


def service_command(*args):
    result = subprocess.run(args, capture_output=True, timeout=450)
    if result.returncode: raise RuntimeError('Role runtime monitor operation failed; consult private service logs')
    return result.stdout.decode()


def activate(root, role, edge_id=None, *, run=service_command):
    name = unit_name(role, edge_id)
    run('systemctl', 'reset-failed', name)
    pid = run('systemctl', 'show', name, '--property=MainPID', '--value').strip()
    state = run('systemctl', 'show', name, '--property=ActiveState', '--value').strip()
    # Upgrade the former oneshot gate without restarting application containers.
    operation = 'restart' if pid == '0' and state == 'active' else 'start'
    run('systemctl', operation, name)


@contextmanager
def monitor_after(root, role, edge_id=None, *, activate=activate):
    """Restore monitoring only after the caller has released deployment locks."""
    failure = None
    try:
        yield
    except BaseException as error:
        failure = error
        raise
    finally:
        try:
            path = root / 'state.json'
            if path.exists() or path.is_symlink():
                state = managed_state.read(path)
                pending = state.get('pending')
                backup = root / 'runtime/backup.json'
                maintenance = role == 'core' and (backup.exists() or backup.is_symlink())
                if not maintenance and state.get('current') is not None and (pending is None or pending.get('phase') == 'prepared'):
                    activate(root, role, edge_id)
        except Exception:
            if failure is None: raise
            failure.add_note('Role runtime monitor could not be activated; consult private service logs.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--role', choices=('core', 'edge'), required=True)
    parser.add_argument('--edge')
    args = parser.parse_args()
    install(args.root, args.role, args.edge)
    print('Role boot gate installed and enabled. Docker and application containers were not restarted.')


if __name__ == '__main__': main()
