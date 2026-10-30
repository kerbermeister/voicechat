"""Fingerprint everything except explicitly client/documentation-only sources."""
import hashlib
from pathlib import Path
import subprocess


# Only these deployed application sources may change without updating edge
# operators. Unknown paths, workflow, vendor and shared deployment code stay
# protected. Tests still affect backend_fingerprint and run in every CI mode.
CORE_ONLY = {
    'infra/control.Dockerfile', 'infra/push-requirements.txt', 'infra/supervise.py',
    *('prototype/' + name for name in (
        'token_server.py', 'call_control.py', 'scheduled_messages.py', 'contacts.py',
        'link_preview.py', 'client_policy.py', 'client-policy.json', 'voicechat_policy.py',
        'screen_control.py', 'screen_schema.sql', 'screen_schema_v2.sql',
        'screen_protocol.py', 'screen_access.py', 'screen_transitions.py', 'screen_http.py',
        'screen_status.py', 'web_push.py')),
}


def protected_entries(root):
    entries = subprocess.check_output(['git', 'ls-tree', '-rz', 'HEAD'], cwd=root).split(b'\0')
    for entry in entries:
        if not entry:
            continue
        path = entry.split(b'\t', 1)[1].decode()
        if path.startswith(('apps/client/', 'docs/')) or path in (
                'README.md', 'infra/Caddyfile', 'infra/web.Dockerfile'):
            continue
        yield path, entry


def backend_fingerprint(root):
    return hashlib.sha256(b'\0'.join(entry for _, entry in protected_entries(root))).hexdigest()


def core_scope_fingerprint(root):
    def test(path):
        value = Path(path)
        return value.parent.as_posix() == 'prototype' and value.name.startswith('test_') and value.suffix == '.py'
    return hashlib.sha256(b'\0'.join(entry for path, entry in protected_entries(root)
                                    if path not in CORE_ONLY and not test(path))).hexdigest()


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    (root/'backend.sha256').write_text(backend_fingerprint(root)+'\n')
    (root/'core-scope.sha256').write_text(core_scope_fingerprint(root)+'\n')
