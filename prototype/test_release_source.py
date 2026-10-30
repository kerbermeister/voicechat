from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'infra'))
import release_source


class CoreSourceFingerprintTests(unittest.TestCase):
    def test_only_explicit_core_application_and_test_changes_preserve_boundary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.STDOUT)
            git('init', '-q');git('config', 'user.name', 'Fixture');git('config', 'user.email', 'fixture@example.invalid')
            def commit(name):
                path = root/name;path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name);git('add', '.');git('commit', '-qm', 'fixture')
                return release_source.backend_fingerprint(root), release_source.core_scope_fingerprint(root)
            initial, guard = commit('infra/edge_deploy.py')
            for name in ('prototype/token_server.py', 'infra/control.Dockerfile', 'prototype/test_token_server.py'):
                backend, current = commit(name)
                self.assertNotEqual(backend, initial)
                self.assertEqual(current, guard)
            backend, current = commit('docs/change.md')
            self.assertEqual(current, guard)
            for name in ('infra/role_boot.py', '.github/workflows/deploy.yml', 'vendor/runtime.rs', 'unknown-runtime-file'):
                _, changed = commit(name)
                self.assertNotEqual(changed, guard)
                guard = changed


if __name__ == '__main__':
    unittest.main()
