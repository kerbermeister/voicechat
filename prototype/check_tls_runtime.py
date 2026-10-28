"""Check real Linux serving ownership and interrupted TLS publication, offline."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

from check_three_vps import image
from check_route_tls import run_process

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
IMAGE = image('configure')


def inside():
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise ValueError('Use the disposable Linux root container')
    import tls_runtime
    import test_tls_runtime
    suite = unittest.defaultTestLoader.loadTestsFromModule(test_tls_runtime)
    if not unittest.TextTestRunner().run(suite).wasSuccessful(): raise SystemExit(1)
    fixture = test_tls_runtime.TLSRuntimeTests
    fixture.setUpClass()
    try:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'tls'
            for service, stem in [('web', 'old'), ('turn', 'turn.routes.test')]:
                tls_runtime.publish(root, fixture.public, 'b', service,
                    fixture.source / (stem + '.crt'), fixture.source / (stem + '.key'),
                    ca_file=fixture.source / 'ca.crt', minimum_validity_days=1)
            key = root / 'turn/turn.key'
            info = key.stat()
            assert (info.st_uid, info.st_gid, info.st_mode & 0o777) == (0, 10001, 0o640)
            assert (root / 'turn').stat().st_mode & 0o777 == 0o750
            assert (root / 'web/web.key').stat().st_mode & 0o777 == 0o600
            # cwd is established while root, like a mount exposed directly at
            # /tls. The child then has only coturn's UID/GID, no extra groups.
            child = '''from pathlib import Path
assert b'PRIVATE KEY' in Path('turn.key').read_bytes()
assert b'CERTIFICATE' in Path('turn.crt').read_bytes()
try: Path('turn.key').write_bytes(b'corrupt')
except PermissionError: pass
else: raise AssertionError('TURN can modify private material')
try: Path('../web/web.key').read_bytes()
except PermissionError: pass
else: raise AssertionError('TURN can read web private key')
'''
            subprocess.run([sys.executable, '-c', child], cwd=root / 'turn',
                           user=10001, group=10001, extra_groups=[], check=True)
            print('PASS: Linux TLS publisher resume/rollback, root-owned 0640 TURN key readable by UID/GID 10001, write/web-key access denied.')
    finally:
        fixture.doClassCleanups()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inside', action='store_true')
    args = parser.parse_args()
    if args.inside:
        inside()
    else:
        name = 'voicechat-tls-permissions-' + uuid.uuid4().hex[:12]
        try:
            run_process(['docker', 'run', '--rm', '--name', name, '--pull', 'never', '--network', 'none',
                '--memory', '128m', '--cpus', '.5',
                '--read-only', '--cap-drop', 'ALL', '--cap-add', 'CHOWN', '--cap-add', 'SETUID', '--cap-add', 'SETGID',
                '--security-opt', 'no-new-privileges:true', '--tmpfs', '/tmp:rw,nosuid,nodev,size=32m',
                '--env', 'PYTHONDONTWRITEBYTECODE=1', '--mount', f'type=bind,source={ROOT},target=/source,readonly',
                IMAGE, 'python3', '/source/prototype/check_tls_runtime.py', '--inside'])
        finally:
            run_process(['docker', 'rm', '--force', name], check=False, capture_output=True, timeout=20)


if __name__ == '__main__': main()
