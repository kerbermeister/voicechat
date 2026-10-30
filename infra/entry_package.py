"""Create the same complete Git-bound public source delivery for an entry operation."""
import gzip
import hashlib
import io
import json
import os
import tempfile
from pathlib import Path
import subprocess
import tarfile

import release_delivery
import release_source
import ssh_deploy


def create(checkout, path, hints, web):
    checkout, path = Path(checkout).resolve(), Path(path)
    git = ['git', '-C', str(checkout)]
    commit = subprocess.check_output([*git, 'rev-parse', 'HEAD']).decode().strip()
    backend = release_source.backend_fingerprint(checkout)
    guard = release_source.core_scope_fingerprint(checkout)
    if hints['backend'] != backend or hints['core_guard'] != guard or web not in hints['web'].values():
        raise ValueError('Install the matching full release before preparing entry source delivery')
    manifest = {'schema': 1, 'commit': commit, 'origin': hints['origin'], 'control': hints['control'], 'web': web}
    files = {}
    for entry in subprocess.check_output([*git, 'ls-tree', '-rz', 'HEAD']).split(b'\0'):
        if not entry: continue
        header, name = entry.split(b'\t', 1); name = name.decode()
        if not (name.startswith('infra/') or name in {'prototype/' + item for item in release_delivery.POLICIES}): continue
        if header.split()[0] not in (b'100644', b'100755'):
            raise ValueError('Only regular reviewed deployment sources allowed')
        files[name] = subprocess.check_output([*git, 'show', commit + ':' + name])
    files.update({'release.json': json.dumps(manifest).encode(), 'backend.sha256': backend.encode(),
                  'core-scope.sha256': guard.encode()})
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w') as archive:
        for name, content in sorted(files.items()):
            member = tarfile.TarInfo(name); member.mode = 0o600; member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
    raw = gzip.compress(buffer.getvalue(), mtime=0)
    source = hashlib.sha256(raw).hexdigest()
    unpacked, receipt = release_delivery.unpack(raw, source, commit)
    ssh_deploy.verify_checkout(unpacked, receipt, checkout)
    if path.exists() or path.is_symlink():
        if path.is_symlink() or path.read_bytes() != raw:
            raise ValueError('Existing operator source archive belongs to another operation')
    else:
        descriptor, temporary = tempfile.mkstemp(prefix='.entry-source-', dir=path.parent)
        try:
            with os.fdopen(descriptor, 'wb') as output:
                os.fchmod(output.fileno(), 0o600); output.write(raw); output.flush(); os.fsync(output.fileno())
            os.link(temporary, path)
            parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(parent)
            finally: os.close(parent)
        finally:
            Path(temporary).unlink(missing_ok=True)
    return {'schema': 1, 'commit': commit, 'source': source, 'manifest': manifest}
