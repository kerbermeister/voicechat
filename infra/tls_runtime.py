"""Publish a validated TLS pair inside a stable service mount; no process reload."""
import argparse
import os
from pathlib import Path
import re
import stat
import tempfile

import managed_state
import tls_material
from topology import load


def directory(path, mode, group):
    if not path.exists() and not path.is_symlink():
        path.mkdir(mode=mode)
    info = path.lstat()
    # Resume a crash between mkdir and setting the serving group. Only empty,
    # private, owner-controlled directories can be completed this way.
    if (stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and
            info.st_gid in (os.getegid(), group) and stat.S_IMODE(info.st_mode) in (mode, 0o700) and
            not any(path.iterdir())):
        if os.geteuid() == 0: os.chown(path, 0, group)
        path.chmod(mode)
        info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or
            info.st_gid != group or stat.S_IMODE(info.st_mode) != mode):
        raise ValueError('Unexpected TLS directory ownership, permissions or type')


def write_serving(root, path, content, mode, group):
    descriptor, temporary = tempfile.mkstemp(prefix='.tls-write-', dir=root)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            if os.geteuid() == 0: os.fchown(output.fileno(), 0, group)
            os.fchmod(output.fileno(), mode)
            output.write(content)
            output.flush(); os.fsync(output.fileno())
        # Never replace an existing generation file, even after a crash.
        os.link(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def link_target(path):
    if not path.exists() and not path.is_symlink(): return None
    if not path.is_symlink(): raise ValueError('TLS selector must be a managed symlink')
    target = os.readlink(path)
    if not re.fullmatch(r'generations/[a-f0-9]{64}', target):
        raise ValueError('TLS selector escapes the generation directory')
    return target.split('/')[1]


def publish(root, public, edge_id, service, chain_file, key_file, *, ca_file=None, minimum_validity_days=7):
    with managed_state.locked(root) as root:
        return _publish_locked(root, public, edge_id, service, chain_file, key_file,
                               ca_file=ca_file, minimum_validity_days=minimum_validity_days)


def _publish_locked(root, public, edge_id, service, chain_file, key_file, *, ca_file=None, minimum_validity_days=7):
    """Caller must hold managed_state.locked(root) through publication/reload."""
    names = tls_material.names(public, edge_id, service)
    if service == 'turn' and os.geteuid() != 0:
        raise ValueError('TURN TLS publication requires root to set group 10001')
    group = 10001 if service == 'turn' else os.getegid()
    dir_mode, file_mode = (0o750, 0o640) if service == 'turn' else (0o700, 0o600)
    identity = {'service_id': public['service_id'], 'edge_id': edge_id, 'service': service,
                'canonical_origin': public['canonical_origin'], 'matrix_server_name': public['matrix_server_name'],
                'names': names}
    verified = tls_material.stage(root / '.verified', public, edge_id, service, chain_file, key_file,
                                  ca_file=ca_file, minimum_validity_days=minimum_validity_days)
    generation = verified.name
    mounted = root / service
    receipt = root / (service + '.json')
    previous = None
    if receipt.exists() or receipt.is_symlink():
        state = managed_state.read(receipt)
        if (not isinstance(state, dict) or set(state) != {'schema', 'identity', 'desired', 'previous', 'phase'} or
                type(state['schema']) is not int or state['schema'] != 1 or state['identity'] != identity or
                state['phase'] not in ('prepared', 'selected') or
                not isinstance(state['desired'], str) or not re.fullmatch(r'[a-f0-9]{64}', state['desired']) or
                (state['previous'] is not None and (not isinstance(state['previous'], str) or
                    not re.fullmatch(r'[a-f0-9]{64}', state['previous'])))):
            raise ValueError('Invalid or foreign TLS publication state')
        previous = (state['previous'] if state['phase'] == 'prepared' or state['desired'] == generation
                    else state['desired'])
        if state['phase'] == 'prepared' and state['desired'] != generation:
            raise ValueError('Finish the interrupted TLS publication before selecting another pair')
        # A selected pair may remain in memory until reload. Do not call
        # this receipt "active" or interpret it as successful activation.
        selected = link_target(mounted / 'current')
        allowed = {state['desired']} if state['phase'] == 'selected' else {previous, generation}
        if selected not in allowed: raise ValueError('TLS selector differs from recorded state')
    else:
        if mounted.is_symlink() or (mounted.exists() and
                (not mounted.is_dir() or any(mounted.iterdir()))):
            raise ValueError('Refusing to adopt existing TLS material')
        state = None
    if state is None or state['phase'] == 'selected':
        state = {'schema': 1, 'identity': identity, 'desired': generation,
                 'previous': previous, 'phase': 'prepared'}
        managed_state.persist(receipt, state)
    # A renderer creates empty owner-only service directories. Once an
    # intent exists, an interrupted initial ownership change is resumable.
    if mounted.exists() and not mounted.is_symlink() and not any(mounted.iterdir()):
        info = mounted.stat()
        if info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ValueError('Unsafe initial TLS mount directory')
        if os.geteuid() == 0: os.chown(mounted, 0, group)
        mounted.chmod(dir_mode)
    directory(mounted, dir_mode, group)
    versions = mounted / 'generations'
    directory(versions, dir_mode, group)
    selected_directory = versions / generation
    directory(selected_directory, dir_mode, group)
    expected = {service + '.crt', service + '.key'}
    if any(item.name not in expected for item in selected_directory.iterdir()):
        raise ValueError('Unexpected file in TLS generation')
    for name in sorted(expected):
        content = tls_material.read_material(verified / name, private=True)
        target = selected_directory / name
        if target.exists() or target.is_symlink():
            info = target.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_gid != group or
                    stat.S_IMODE(info.st_mode) != file_mode or tls_material.read_material(target) != content):
                raise ValueError('Published TLS generation was modified')
        else:
            write_serving(root, target, content, file_mode, group)
        alias = mounted / name
        if alias.exists() or alias.is_symlink():
            if not alias.is_symlink() or os.readlink(alias) != 'current/' + name:
                raise ValueError('Unexpected TLS certificate alias')
        else: alias.symlink_to('current/' + name)
    tls_material.sync_directory(selected_directory)
    tls_material.sync_directory(versions)
    if link_target(mounted / 'current') != generation:
        temporary = mounted / '.next'
        if temporary.exists() or temporary.is_symlink():
            if not temporary.is_symlink() or os.readlink(temporary) != 'generations/' + generation:
                raise ValueError('Unexpected pending TLS selector')
        else: temporary.symlink_to('generations/' + generation)
        os.replace(temporary, mounted / 'current')
    tls_material.sync_directory(mounted)
    managed_state.persist(receipt, {**state, 'phase': 'selected'})
    return {'generation': generation, 'previous': previous, 'reload_required': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True, help='Private runtime/tls directory')
    parser.add_argument('--topology', type=Path, required=True)
    parser.add_argument('--edge', required=True)
    parser.add_argument('--service', choices=('web', 'turn'), required=True)
    parser.add_argument('--chain', type=Path, required=True)
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--ca-file', type=Path, help='Explicit isolated test CA')
    parser.add_argument('--minimum-validity-days', type=int, default=7)
    args = parser.parse_args()
    result = publish(args.root, load(args.topology), args.edge, args.service, args.chain, args.key,
                     ca_file=args.ca_file, minimum_validity_days=args.minimum_validity_days)
    print('TLS pair selected on disk; reload and TLS handshake verification still required: ' + result['generation'])


if __name__ == '__main__': main()
