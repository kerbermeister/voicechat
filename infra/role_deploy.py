"""Shared filesystem, command and host-network guards for core/edge rollout."""
from contextlib import contextmanager
from pathlib import Path
import subprocess
import re

import managed_state
import network_runtime
import role_release
import topology


def pending_rollout(root):
    """Read the role-bound maintenance fence owned by the full coordinator."""
    root = Path(root).absolute()
    path = root / 'runtime/full-rollout.json'
    if not path.exists() and not path.is_symlink(): return None
    value = managed_state.read(path)
    topology.fields(value, ('schema', 'operation', 'root', 'attempt', 'target', 'owner'))
    if (type(value['schema']) is not int or value['schema'] != 1 or value['operation'] != 'full-rollout' or
            root.resolve() != root or value['root'] != str(root) or
            any(not isinstance(value[key], str) or not re.fullmatch(r'[a-f0-9]{64}', value[key])
                for key in ('attempt', 'target', 'owner')) or
            value['owner'] != role_release.json_digest(managed_state.read(root / 'role.json'))):
        raise ValueError('Invalid or foreign full rollout fence; explicit recovery required')
    return value


def require_rollout_owner(root, attempt=None, manifest=None):
    pending = pending_rollout(root)
    if pending is None:
        if attempt is not None: raise ValueError('Full rollout owner has no role maintenance fence')
    elif attempt != pending['attempt'] or manifest is None or role_release.json_digest(manifest) != pending['target']:
        raise ValueError('Finish the full rollout before a separate role operation')


def run(arguments, *, env=None, input=None):
    result = subprocess.run(arguments, env=env, input=input, capture_output=True, timeout=300)
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

