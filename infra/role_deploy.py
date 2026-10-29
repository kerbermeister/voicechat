"""Shared filesystem, command and host-network guards for core/edge rollout."""
from contextlib import contextmanager
from pathlib import Path
import subprocess

import managed_state
import network_runtime
import role_release


def run(arguments, *, env=None):
    result = subprocess.run(arguments, env=env, capture_output=True, timeout=300)
    if result.returncode:
        raise RuntimeError('Role deployment command failed; consult private service logs')
    if len(result.stdout) > 1024 * 1024:
        raise ValueError('Unexpected deployment command response size')
    return result.stdout


def release_path(root, record):
    path = root / 'releases' / role_release.json_digest(record['manifest'])
    if path.resolve() != path or not path.is_dir():
        raise ValueError('Immutable release must be a real directory under releases/<manifest-sha256>')
    role_release.verify_recorded_bundle(path, record['manifest'])
    runtime = path / 'infra/runtime'
    if not runtime.is_symlink() or runtime.resolve() != root / 'runtime':
        raise ValueError('Release must reference the prepared shared role runtime')
    return path



@contextmanager
def network_ready(inventory, node, subnet, *, execute=run, directory=Path('/var/lib/voicechat-network')):
    # Keep replacement/revocation from racing this rollout. Lock ordering is
    # role -> host network -> TLS; network reconciliation never takes TLS.
    with managed_state.locked(directory):
        retirement = directory / 'boot-install/initial-rollback.json'
        if retirement.exists() or retirement.is_symlink():
            raise ValueError('Finish initial network rollback/restoration before deploying roles')
        upgrade = directory / 'boot-install/upgrade.json'
        if upgrade.exists() or upgrade.is_symlink():
            raise ValueError('Finish the interrupted network source upgrade before deploying')
        desired = managed_state.read(directory / 'desired.json')
        firewall, tunnel = network_runtime.components(desired)
        if desired['inventory'] != inventory or desired['node'] != node or desired['edge_subnet'] != subnet:
            raise ValueError('Host networking does not match this node inventory')
        if (managed_state.read(directory / 'applied.json') != {'schema': 1,
                'sha256': network_runtime.fingerprint(desired), 'phase': 'complete'} or
                managed_state.read(directory / 'firewall/desired.json') != firewall or
                managed_state.read(directory / 'tunnel/desired.json') != tunnel):
            raise ValueError('Finish the interrupted host network operation before deploying')
        if execute(['systemctl', 'is-active', 'voicechat-network.service']).strip() != b'active':
            raise ValueError('Managed host network service is not active')
        yield

