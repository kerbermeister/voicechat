"""Fingerprint everything except explicitly client/documentation-only sources."""
import hashlib
from pathlib import Path
import subprocess


def backend_fingerprint(root):
    entries = subprocess.check_output(['git', 'ls-tree', '-rz', 'HEAD'], cwd=root).split(b'\0')
    protected = []
    for entry in entries:
        if not entry:
            continue
        path = entry.split(b'\t', 1)[1].decode()
        if path.startswith(('apps/client/', 'docs/')) or path in (
                'README.md', 'infra/Caddyfile', 'infra/web.Dockerfile'):
            continue
        protected.append(entry)
    return hashlib.sha256(b'\0'.join(protected)).hexdigest()


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    (root/'backend.sha256').write_text(backend_fingerprint(root)+'\n')
