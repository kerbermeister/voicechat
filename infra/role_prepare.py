"""Stage a verified immutable role release without starting services or copying secrets."""
import argparse
import os
from pathlib import Path
import stat
import tempfile

import managed_state
import node_inventory
import role_release
from render_roles import bundle, write_bundle
import topology


def directory(path, *, public=False):
    existed = path.exists() or path.is_symlink()
    path.mkdir(mode=0o755 if public else 0o700, exist_ok=True)
    if public and not existed: path.chmod(0o755)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or
            info.st_mode & (0o022 if public else 0o077) or
            (public and stat.S_IMODE(info.st_mode) != 0o755)):
        raise ValueError('Role directory must be owned, real and appropriately private')


def prepare(root, public, inventory, manifest, subnet='10.241.0.0/28'):
    root = Path(root).absolute()
    if root.resolve() != root: raise ValueError('Role root must not traverse symlinks')
    role_release.validate(manifest)
    role, edge = manifest['role'], manifest['edge_id']
    expected = role_release.make(public, inventory, role, manifest['commit'],
        manifest['images']['control' if role == 'core' else 'web'], edge, subnet)
    if expected != manifest: raise ValueError('Candidate does not match reviewed sources and configuration')
    identity = {key: manifest[key] for key in ('schema', 'service_id', 'role', 'edge_id', 'identity')}
    files, runtime = bundle(public, inventory, role, edge, subnet)
    with managed_state.locked(root):
        receipt = root / 'role.json'
        if receipt.exists() or receipt.is_symlink():
            if managed_state.read(receipt) != identity:
                raise ValueError('Role root already belongs to another identity')
        else:
            if any(item.name != 'apply.lock' for item in root.iterdir()):
                raise ValueError('Existing role data requires explicit adoption')
            managed_state.persist(receipt, identity)
        directory(root / 'releases')
        directory(root / 'runtime')
        for name in runtime:
            # TLS publication owns service directories (including TURN's 0750
            # group-readable mount). Do not recreate or chmod them on rollout.
            if name in ('runtime/tls/web', 'runtime/tls/turn'): continue
            relative = Path(name).relative_to('runtime')
            path = root / 'runtime'
            for part in relative.parts:
                path /= part
                directory(path, public=path.name in ('catalog', 'android-updates', 'macos-updates'))
        target = root / 'releases' / role_release.json_digest(manifest)
        if target.exists() or target.is_symlink():
            role_release.verify_bundle(target, manifest, public, inventory, subnet)
            if (managed_state.read(target / 'release.json') != manifest or
                    not (target / 'infra/runtime').is_symlink() or
                    (target / 'infra/runtime').resolve() != root / 'runtime'):
                raise ValueError('Installed release metadata or runtime mount changed')
            return target
        with tempfile.TemporaryDirectory(prefix='.prepare-', dir=root / 'releases') as temporary:
            staged = Path(temporary) / 'release'
            write_bundle(staged, files, runtime)
            # Only empty directories generated in this private staging tree are
            # removed. Runtime keys, catalogs and older release mounts stay put.
            for path in sorted((staged / 'infra/runtime').rglob('*'), key=lambda p: len(p.parts), reverse=True):
                path.rmdir()
            (staged / 'infra/runtime').rmdir()
            (staged / 'infra/runtime').symlink_to(root / 'runtime', target_is_directory=True)
            managed_state.persist(staged / 'release.json', manifest)
            role_release.verify_bundle(staged, manifest, public, inventory, subnet)
            for path in sorted(staged.rglob('*'), key=lambda p: len(p.parts), reverse=True):
                if path.is_symlink(): continue
                descriptor = os.open(path, os.O_RDONLY)
                try: os.fsync(descriptor)
                finally: os.close(descriptor)
            descriptor = os.open(staged, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(descriptor)
            finally: os.close(descriptor)
            os.rename(staged, target)
            descriptor = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(descriptor)
            finally: os.close(descriptor)
        return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--topology', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--edge-subnet', default='10.241.0.0/28')
    args = parser.parse_args()
    public = topology.load(args.topology)
    target = prepare(args.root, public, node_inventory.load(args.inventory, public),
                     role_release.load(args.manifest), args.edge_subnet)
    print('Prepared immutable role release: ' + str(target))


if __name__ == '__main__': main()
