from pathlib import Path
import subprocess
import tempfile
import unittest

from native_av_fixture import native_av_fixture


class NativeFixtureTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.main = self.root / 'apps/client/macos/Runner/MainFlutterWindow.swift'
        self.main.parent.mkdir(parents=True)
        self.original = b'RegisterGeneratedPlugins(registry: flutterViewController)\n'
        self.main.write_bytes(self.original)
        fixture = self.root / 'apps/client/integration_test/native_av_marker.swift'
        fixture.parent.mkdir()
        fixture.write_text('// synthetic test fixture\n')
        def git(*args):
            return subprocess.run(['git', *args], cwd=self.root, check=True, capture_output=True)
        git('init', '-q')
        git('add', '.')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'Fixture')

    def test_restores_source_after_success_and_test_failure(self):
        for fail in (False, True):
            try:
                with native_av_fixture(self.root, 'macos'):
                    self.assertIn(b'NativeAVMarker.install', self.main.read_bytes())
                    if fail:
                        raise ValueError('Synthetic test failure')
            except ValueError:
                self.assertTrue(fail)
            self.assertEqual(self.main.read_bytes(), self.original)

    def test_refuses_preexisting_user_changes(self):
        changed = self.original + b'// user change\n'
        self.main.write_bytes(changed)
        with self.assertRaisesRegex(RuntimeError, 'clean app entry'):
            with native_av_fixture(self.root, 'macos'):
                self.fail('Dirty source must not be instrumented')
        self.assertEqual(self.main.read_bytes(), changed)

    def test_does_not_overwrite_concurrent_source_change(self):
        with self.assertRaisesRegex(RuntimeError, 'changed during'):
            with native_av_fixture(self.root, 'macos'):
                self.main.write_bytes(b'// concurrent user change\n')
        self.assertEqual(self.main.read_bytes(), b'// concurrent user change\n')


if __name__ == '__main__':
    unittest.main()
