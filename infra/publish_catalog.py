"""Atomically publish a verified catalog to one local runtime directory."""
import argparse
import fcntl
import os
from pathlib import Path
import tempfile

from route_catalog import read_envelope, verify
from topology import load


def publish(directory, envelope, public, bootstrap, *, initialize=False):
    # Reject invalid input before touching runtime. The lock then serializes
    # comparison and replacement of the single signed revision/content record.
    verify(envelope, public, bootstrap)
    destination = Path(directory) / 'routes.json'
    lock = os.open(Path(directory) / '.publish.lock', os.O_WRONLY | os.O_CREAT, 0o600)
    with os.fdopen(lock, 'w') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        previous = None
        if destination.exists():
            if initialize:
                raise ValueError('Catalog already initialized')
            previous = verify(read_envelope(destination), public, bootstrap, restoring=True)
        elif not initialize:
            raise ValueError('Catalog state missing; initialize only a new runtime explicitly')
        current = verify(envelope, public, bootstrap, previous=previous)
        if previous is not None and current.revision == previous.revision:
            return current
        # Rename within the bind-mounted directory; replacing the directory or
        # binding the individual file would leave a running Caddy on the old inode.
        descriptor, temporary = tempfile.mkstemp(prefix='.routes-', dir=directory)
        try:
            with os.fdopen(descriptor, 'wb') as output:
                os.fchmod(output.fileno(), 0o644)
                output.write(envelope)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, destination)
            directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            Path(temporary).unlink(missing_ok=True)
        return current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, required=True)
    parser.add_argument('--catalog-key-file', type=Path, required=True)
    parser.add_argument('--bootstrap-topology', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--initialize', action='store_true')
    args = parser.parse_args()
    envelope = read_envelope(args.catalog)
    current = publish(args.directory, envelope, args.catalog_key_file.read_text().strip(),
                      load(args.bootstrap_topology), initialize=args.initialize)
    print(f'Accepted local catalog revision {current.revision}')


if __name__ == '__main__':
    main()
