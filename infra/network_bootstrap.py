"""Install boot restoration for an already prepared, verified Linux node.

Packages and coordinated network intent must exist first. This installs only
owned immutable code and two systemd files; it never restarts Docker. Owned source upgrades use --upgrade and ExecReload. Adoption of an existing
unmanaged installation requires migration.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import stat
import tempfile

import managed_state
import network_runtime
import node_inventory
from topology import fields
from tunnel_config import physical_nodes
from tunnel_runtime import command

SOURCES = network_runtime.SOURCES
UNIT = 'etc/systemd/system/voicechat-network.service'
DROP_IN = 'etc/systemd/system/docker.service.d/50-voicechat-network.conf'


def directory(root, relative, *, create=False):
    current = root
    for part in Path(relative).parts:
        current = current / part
        if current.is_symlink(): raise ValueError('Installation parent cannot be a symlink')
        if not current.exists():
            if not create: continue
            current.mkdir(mode=0o755)
        if current.exists():
            info = current.stat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
                raise ValueError('Installation parents must be owned and not writable by others')
    return current


def existing(path):
    if not path.exists() and not path.is_symlink(): return None
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ValueError('Installed file must be owned and not writable by others')
        return source.read(1024 * 1024 + 1)


def create_file(path, content):
    descriptor, temporary = tempfile.mkstemp(prefix='.voicechat-install-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            os.fchmod(output.fileno(), 0o644)
            output.write(content); output.flush(); os.fsync(output.fileno())
        # link refuses to replace a file inserted after the preflight check.
        os.link(temporary, path)
        parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(parent)
        finally: os.close(parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def source_plan(desired, *, shared_host=False):
    source = Path(__file__).parent
    contents = {name: (source / name).read_bytes() for name in
                (*SOURCES, 'voicechat-network.service', 'voicechat-docker-network.conf')}
    if shared_host:
        name = 'voicechat-docker-network.conf'
        if contents[name].count(b'Requires=voicechat-network.service') != 1:
            raise ValueError('Docker dependency template changed')
        contents[name] = contents[name].replace(b'Requires=voicechat-network.service', b'Wants=voicechat-network.service').replace(
            b'# Docker must not auto-start containers when network intent is missing/invalid.',
            b'# Shared host: unrelated Docker workloads may start after a failed VoiceChat network unit.')
    digest = hashlib.sha256(json.dumps({name: hashlib.sha256(data).hexdigest()
        for name, data in contents.items()}, sort_keys=True).encode()).hexdigest()
    code = 'opt/voicechat/network/' + digest
    files = {code + '/' + name: contents[name] for name in SOURCES}
    files[UNIT] = contents['voicechat-network.service'].replace(b'/opt/voicechat/network', ('/' + code).encode())
    files[DROP_IN] = contents['voicechat-docker-network.conf']
    identity = {'schema': 1, 'source_sha256': digest, 'node': desired['node'],
                'service_id': desired['inventory']['service_id']}
    return identity, files, code


def shared_containers_ready(root, run):
    """Do not relax the global dependency while VoiceChat can bypass its gate."""
    rows = run('docker', 'ps', '-a', '--format',
               '{{.ID}} {{.Label "com.docker.compose.project"}} {{.Label "com.docker.compose.service"}}')
    for row in rows.splitlines():
        parts = row.split()
        if len(parts) != 3: continue  # Unlabelled unrelated containers.
        identifier, project, service = parts
        if project != 'voicechat' and not project.startswith('voicechat-edge-'): continue
        import re
        if not re.fullmatch(r'[a-f0-9]{12,64}', identifier): raise ValueError('Unexpected container identity')
        if project != 'voicechat' and not re.fullmatch(r'voicechat-edge-[a-z][a-z0-9-]{0,31}', project):
            raise ValueError('Unexpected VoiceChat project identity')
        policy = json.loads(run('docker', 'inspect', '--format', '{{json .HostConfig.RestartPolicy}}', identifier))
        expected = 'no'
        if policy.get('Name') != expected or policy.get('MaximumRetryCount', 0) != 0:
            raise ValueError('Migrate VoiceChat restart policies before enabling shared-host Docker ordering')
        unit = 'voicechat-core.service' if project == 'voicechat' else project + '.service'
        content = existing(root / 'etc/systemd/system' / unit)
        if (content is None or b'Requires=docker.service voicechat-network.service' not in content or
                b'WantedBy=docker.service' not in content or b'/opt/voicechat/operators/' not in content or
                b'--watch' not in content or b'Restart=on-failure' not in content):
            raise ValueError('Owned role boot gates are required on a shared Docker host')
        run('systemctl', 'is-enabled', '--quiet', unit)


def install(root=Path('/'), *, run=command, shared_host=False):
    root = Path(root).resolve()
    state_root = directory(root, 'var/lib/voicechat-network')
    info = state_root.stat()
    if info.st_mode & 0o077: raise ValueError('Network state directory must be owner-only')
    desired = managed_state.read(state_root / 'desired.json')
    network_runtime.components(desired)
    local = physical_nodes(desired['inventory'])[desired['node']]
    host_key = ' '.join((root / 'etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    if node_inventory.host_key(host_key) != local['ssh_host_key']:
        raise ValueError('This host does not match the prepared network identity')
    if run('systemctl', 'show', '--property=SystemState', '--value').strip() != 'running':
        raise ValueError('A healthy running systemd host is required')
    for program in ('nft', 'wg', '/usr/bin/python3', 'systemd-analyze'):
        run(program, '--version')
    if shared_host: shared_containers_ready(root, run)
    identity, files, code = source_plan(desired, shared_host=shared_host)
    digest = identity['source_sha256']
    with managed_state.locked(state_root / 'boot-install') as receipt_root:
        receipt = receipt_root / 'desired.json'
        if (receipt_root / 'upgrade.json').exists() or (receipt_root / 'upgrade.json').is_symlink():
            raise ValueError('Resume the pending network source upgrade first')
        previous = managed_state.read(receipt) if receipt.exists() or receipt.is_symlink() else None
        if previous is not None:
            fields(previous, (*identity, 'phase'))
            if (type(previous['schema']) is not int or {key: previous[key] for key in identity} != identity or
                    previous['phase'] not in ('prepared', 'complete')):
                raise ValueError('Boot source/identity upgrade requires a separate migration')
        # systemctl returns exit 1 for a missing exact-name pattern on Debian 12.
        # Inspect the successful full listing so a clean host is not an error.
        elif any(line.split()[:1] == ['voicechat-network.service'] for line in
                 run('systemctl', 'list-unit-files', '--no-legend', '--no-pager').splitlines()):
            raise ValueError('An unclaimed network service is already installed')
        # Inspect every destination before writing the receipt or any code/unit.
        for name, data in files.items():
            directory(root, Path(name).parent)
            actual = existing(root / name)
            if actual is not None and (previous is None or actual != data):
                raise ValueError('Refusing to replace an unclaimed or modified installation file')
        target = root / code
        if target.exists() and any(item.name not in SOURCES and not item.name.startswith('.voicechat-install-')
                                   for item in target.iterdir()):
            raise ValueError('Unexpected files in immutable network code directory')
        managed_state.persist(receipt, {**identity, 'phase': 'prepared'})
        for name, data in files.items():
            path = root / name
            directory(root, Path(name).parent, create=True)
            if existing(path) is None: create_file(path, data)
        run('systemd-analyze', 'verify', '--man=no', str(root / UNIT))
        run('systemctl', 'daemon-reload')
        run('systemctl', 'enable', 'voicechat-network.service')
        run('systemctl', 'start', 'voicechat-network.service')
        run('systemctl', 'is-active', '--quiet', 'voicechat-network.service')
        run('systemctl', 'is-enabled', '--quiet', 'voicechat-network.service')
        managed_state.persist(receipt, {**identity, 'phase': 'complete'})
    return digest


def replace_file(path, content):
    descriptor, temporary = tempfile.mkstemp(prefix='.voicechat-upgrade-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            os.fchmod(output.fileno(), 0o644)
            output.write(content); output.flush(); os.fsync(output.fileno())
        os.replace(temporary, path)
        parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(parent)
        finally: os.close(parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def verify_previous(root, before, previous_files):
    import re
    fields(before, ('schema', 'source_sha256', 'node', 'service_id', 'phase'))
    if (type(before['schema']) is not int or before['schema'] != 1 or before['phase'] != 'complete' or
            not isinstance(before['source_sha256'], str) or not re.fullmatch(r'[a-f0-9]{64}', before['source_sha256'])):
        raise ValueError('A completed verified boot installation is required')
    fields(previous_files, (UNIT, DROP_IN))
    if any(not isinstance(value, str) for value in previous_files.values()):
        raise ValueError('Invalid prior systemd source snapshot')
    code = 'opt/voicechat/network/' + before['source_sha256']
    target = directory(root, code)
    if not target.is_dir() or {item.name for item in target.iterdir()} != set(SOURCES):
        raise ValueError('Prior immutable network source set changed')
    content = {name: existing(target / name) for name in SOURCES}
    if any(value is None for value in content.values()): raise ValueError('Missing prior network source')
    content['voicechat-network.service'] = previous_files[UNIT].encode().replace(
        ('/' + code).encode(), b'/opt/voicechat/network')
    content['voicechat-docker-network.conf'] = previous_files[DROP_IN].encode()
    checksum = hashlib.sha256(json.dumps({name: hashlib.sha256(value).hexdigest()
        for name, value in content.items()}, sort_keys=True).encode()).hexdigest()
    if checksum != before['source_sha256']:
        raise ValueError('Prior boot source/unit checksums do not match the owned receipt')


def upgrade(root=Path('/'), *, run=command, shared_host=None):
    """Resume an owned source upgrade by reload; never restart Docker or restore retired peers."""
    root = Path(root).resolve()
    state_root = directory(root, 'var/lib/voicechat-network')
    if state_root.stat().st_mode & 0o077: raise ValueError('Network state directory must be owner-only')
    desired = managed_state.read(state_root / 'desired.json')
    network_runtime.components(desired)
    local = physical_nodes(desired['inventory'])[desired['node']]
    host_key = ' '.join((root / 'etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    if node_inventory.host_key(host_key) != local['ssh_host_key']:
        raise ValueError('This host does not match the prepared network identity')
    if shared_host is None:
        installed = existing(root / DROP_IN)
        shared_host = installed is not None and b'\nWants=voicechat-network.service\n' in installed
    if shared_host: shared_containers_ready(root, run)
    identity, files, code = source_plan(desired, shared_host=shared_host)
    with managed_state.locked(state_root / 'boot-install') as receipt_root:
        receipt, pending = receipt_root / 'desired.json', receipt_root / 'upgrade.json'
        current = managed_state.read(receipt)
        target = {**identity, 'phase': 'complete'}
        if pending.exists() or pending.is_symlink():
            journal = managed_state.read(pending)
            fields(journal, ('schema', 'before', 'target', 'previous_files'))
            if type(journal['schema']) is not int or journal['schema'] != 1 or journal['target'] != target:
                raise ValueError('Resume the same pending network source upgrade')
            before, previous_files = journal['before'], journal['previous_files']
            if current not in (before, target): raise ValueError('Boot receipt changed during upgrade')
        else:
            before = current
            previous_files = {name: existing(root / name) for name in (UNIT, DROP_IN)}
            if any(value is None for value in previous_files.values()):
                raise ValueError('Missing installed boot files')
            previous_files = {name: value.decode() for name, value in previous_files.items()}
            journal = {'schema': 1, 'before': before, 'target': target, 'previous_files': previous_files}
        verify_previous(root, before, previous_files)
        if any(before[key] != target[key] for key in ('schema', 'node', 'service_id')):
            raise ValueError('Cannot change the host role during source upgrade')
        for name, data in files.items():
            directory(root, Path(name).parent)
            actual = existing(root / name)
            allowed = (previous_files[name].encode(), data) if name in (UNIT, DROP_IN) else (None, data)
            if actual not in allowed: raise ValueError('Unclaimed or modified network installation file')
        target_code = root / code
        if target_code.exists() and any(item.name not in SOURCES and not item.name.startswith('.voicechat-install-')
                                      for item in target_code.iterdir()):
            raise ValueError('Unexpected files in new immutable network source')
        if current == target and not pending.exists():
            if managed_state.read(state_root / 'applied.json') != {'schema': 1,
                    'sha256': network_runtime.fingerprint(desired), 'phase': 'complete'}:
                raise ValueError('Reconcile the managed network before repeating this upgrade')
            return identity['source_sha256']
        run('systemctl', 'is-active', '--quiet', 'voicechat-network.service')
        docker_before = run('systemctl', 'show', 'docker.service', '--property=MainPID',
                            '--property=ExecMainStartTimestampMonotonic')
        managed_state.persist(pending, journal)
        for name, data in files.items():
            path = root / name
            directory(root, Path(name).parent, create=True)
            actual = existing(path)
            if name in (UNIT, DROP_IN):
                if actual != data: replace_file(path, data)
            elif actual is None:
                create_file(path, data)
        run('systemd-analyze', 'verify', '--man=no', str(root / UNIT))
        run('systemctl', 'daemon-reload')
        # Restarting a Requires dependency can stop Docker. ExecReload applies
        # the new code while the oneshot service remains active throughout.
        run('systemctl', 'reload', 'voicechat-network.service')
        if managed_state.read(state_root / 'applied.json') != {'schema': 1,
                'sha256': network_runtime.fingerprint(desired), 'phase': 'complete'}:
            raise ValueError('New network source was not successfully applied')
        if run('systemctl', 'show', 'docker.service', '--property=MainPID',
               '--property=ExecMainStartTimestampMonotonic') != docker_before:
            raise RuntimeError('Docker changed during network source upgrade')
        managed_state.persist(receipt, target)
        pending.unlink()
        parent = os.open(receipt_root, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(parent)
        finally: os.close(parent)
    return identity['source_sha256']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upgrade', action='store_true', help='Upgrade owned source/unit by reload, without restarting Docker')
    parser.add_argument('--shared-host', action='store_const', const=True, default=None,
        help='Keep Docker available for unrelated apps if VoiceChat networking fails; core binds must remain private')
    args = parser.parse_args()
    if platform.system() != 'Linux' or os.geteuid() != 0:
        raise SystemExit('Boot installation requires the selected Linux host as root')
    if args.upgrade:
        upgrade(shared_host=args.shared_host)
    else:
        install(shared_host=bool(args.shared_host))
    print('Owned network boot restoration verified; Docker was not restarted.')


if __name__ == '__main__': main()
