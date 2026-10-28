"""Install boot restoration for an already prepared, verified Linux node.

Packages and coordinated network intent must exist first. This installs only
owned immutable code and two systemd files; it never restarts Docker. Source
upgrades and adoption of an existing unmanaged installation require migration.
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

SOURCES = ('client_config.py', 'topology.py', 'node_inventory.py', 'tunnel_config.py',
           'tunnel_runtime.py', 'managed_state.py', 'firewall_config.py',
           'firewall_runtime.py', 'network_runtime.py')
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


def install(root=Path('/'), *, run=command):
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
    source = Path(__file__).parent
    contents = {name: (source / name).read_bytes() for name in
                (*SOURCES, 'voicechat-network.service', 'voicechat-docker-network.conf')}
    digest = hashlib.sha256(json.dumps({name: hashlib.sha256(data).hexdigest()
        for name, data in contents.items()}, sort_keys=True).encode()).hexdigest()
    code = 'opt/voicechat/network/' + digest
    files = {code + '/' + name: contents[name] for name in SOURCES}
    files[UNIT] = contents['voicechat-network.service'].replace(b'/opt/voicechat/network', ('/' + code).encode())
    files[DROP_IN] = contents['voicechat-docker-network.conf']
    identity = {'schema': 1, 'source_sha256': digest, 'node': desired['node'],
                'service_id': desired['inventory']['service_id']}
    with managed_state.locked(state_root / 'boot-install') as receipt_root:
        receipt = receipt_root / 'desired.json'
        previous = managed_state.read(receipt) if receipt.exists() or receipt.is_symlink() else None
        if previous is not None:
            fields(previous, (*identity, 'phase'))
            if (type(previous['schema']) is not int or {key: previous[key] for key in identity} != identity or
                    previous['phase'] not in ('prepared', 'complete')):
                raise ValueError('Boot source/identity upgrade requires a separate migration')
        elif run('systemctl', 'list-unit-files', '--no-legend', '--no-pager', 'voicechat-network.service').strip():
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


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    if platform.system() != 'Linux' or os.geteuid() != 0:
        raise SystemExit('Boot installation requires the selected Linux host as root')
    install()
    print('Owned network boot restoration installed; Docker was not restarted.')


if __name__ == '__main__': main()
