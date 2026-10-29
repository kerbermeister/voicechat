"""Temporarily isolate the marked VM's peerless network for full migration proofs.

The original intent/key is moved intact, never regenerated. Callers must remove
only their fixture roles/containers before leaving this context. An unfinished
fixture is preserved for explicit recovery instead of removing unknown services.
"""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import network_bootstrap
import network_runtime
import role_deploy
import tls_material
import tunnel_config


@contextmanager
def isolated_network(directory, *, execute=role_deploy.run, run=network_bootstrap.command):
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise ValueError('Use the marked disposable Linux VM as root')
    base = Path('/srv/voicechat-edge-fixture')
    directory = Path(directory)
    network = Path('/var/lib/voicechat-network')
    key = ' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    if (sys.platform != 'linux' or os.geteuid() != 0 or directory.resolve() != directory or
            directory.parent != base or base.is_symlink() or
            json.loads(network_bootstrap.existing(base / '.disposable-vm')) != {
                'kind':'voicechat-disposable-vm','ssh_host_key_sha256':hashlib.sha256(key.encode()).hexdigest()}):
        raise ValueError('Use an owned directory on the marked disposable VM')
    if directory.stat().st_mode & 0o077 or directory.stat().st_uid != os.geteuid():
        raise ValueError('Private fixture directory required')
    if directory.stat().st_dev != network.parent.stat().st_dev:
        raise ValueError('Atomic same-filesystem network preservation required')
    original, temporary = directory/'original-network', directory/'temporary-network'
    receipt = directory/'network-isolation.json'
    if any(path.exists() or path.is_symlink() for path in (original,temporary,receipt)):
        raise ValueError('Resume the existing isolated network fixture explicitly')
    raw = network_bootstrap.existing(network/'desired.json')
    desired = managed_state.read(network/'desired.json')
    if desired['node'] != 'core' or set(tunnel_config.physical_nodes(desired['inventory'])) != {'core'}:
        raise ValueError('Only a healthy initial peerless VM network may be isolated')
    with role_deploy.network_ready(desired['inventory'],'core',desired['edge_subnet'],
                                  execute=execute,directory=network):
        pass
    fingerprint = network_runtime.fingerprint(desired)
    record = {'schema':1,'fingerprint':fingerprint,'desired_sha256':hashlib.sha256(raw).hexdigest(),
              'original':str(original),'phase':'retiring'}
    managed_state.persist(receipt,record)
    archived = False
    try:
        network_bootstrap.retire_initial(Path('/'),fingerprint,run=run)
        network.rename(original); archived = True
        tls_material.sync_directory(network.parent);tls_material.sync_directory(directory)
        managed_state.persist(receipt,{**record,'phase':'isolated'})
        yield
    finally:
        if archived:
            if network.exists() or network.is_symlink():
                # The normal retirement guard requires all fixture roles and
                # containers gone; multi-host revocations cannot use this path.
                fresh = managed_state.read(network/'desired.json')
                if fresh['node'] != 'core' or set(tunnel_config.physical_nodes(fresh['inventory'])) != {'core'}:
                    raise ValueError('Unexpected network must be preserved for explicit recovery')
                network_bootstrap.retire_initial(Path('/'),network_runtime.fingerprint(fresh),run=run)
                network.rename(temporary)
            original.rename(network)
            tls_material.sync_directory(network.parent);tls_material.sync_directory(directory)
        if network_bootstrap.existing(network/'desired.json') != raw:
            raise ValueError('Original VM network intent changed; explicit recovery required')
        network_bootstrap.install(Path('/'),run=run,shared_host=True,restore_initial=fingerprint)
        with role_deploy.network_ready(desired['inventory'],'core',desired['edge_subnet'],
                                      execute=execute,directory=network):
            pass
        managed_state.persist(receipt,{**record,'phase':'restored'})
