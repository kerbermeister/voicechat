"""Owner-only atomic JSON intent and exclusive lock for host network runtimes."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import stat
import tempfile

from topology import unique_object


def read(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError('Managed state must be an owner-only regular file')
        content = source.read(65537)
    if len(content) > 65536:
        raise ValueError('Managed state is too large')
    return json.loads(content.decode('utf-8'), object_pairs_hook=unique_object)


def persist(path, value):
    content = (json.dumps(value, sort_keys=True, allow_nan=False) + '\n').encode('utf-8')
    if len(content) > 65536:
        raise ValueError('Managed state is too large')
    descriptor, temporary = tempfile.mkstemp(prefix='.intent-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(content)
            output.flush(); os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)


@contextmanager
def locked(directory):
    directory = Path(directory)
    if directory.is_symlink(): raise ValueError('Managed directory cannot be a symlink')
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.stat()
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError('Managed directory must be owner-only')
    descriptor = os.open(directory / 'apply.lock', os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(descriptor, 'w') as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError('Managed lock must be an owner-only regular file')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield directory
