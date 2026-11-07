from pathlib import Path
import json
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

    def test_android_failure_restores_gradle_entrypoint_and_removes_injection(self):
        client = self.root / 'apps/client'
        main = client / 'android/app/src/main/kotlin/dev/voicechat/voicechat_probe/MainActivity.kt'
        main.parent.mkdir(parents=True)
        main.write_text('super.configureFlutterEngine(flutterEngine)\n')
        gradle = client / 'android/app/build.gradle.kts'
        gradle.write_text('dependencies {\n}\n')
        plugin = self.root / 'test-plugin/android/build.gradle'
        plugin.parent.mkdir(parents=True)
        plugin.write_text("implementation 'io.github.webrtc-sdk:android:150.7871.04'\n")
        config = client / '.dart_tool/package_config.json'
        config.parent.mkdir()
        config.write_text(json.dumps({'packages': [{'name': 'flutter_webrtc',
            'rootUri': plugin.parent.parent.as_uri()}]}))
        (client / 'integration_test/NativeAVMarker.kt').write_text('// synthetic\n')
        subprocess.run(['git', 'add', '.'], cwd=self.root, check=True, capture_output=True)
        subprocess.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                        'commit', '-qm', 'Android fixture'], cwd=self.root, check=True, capture_output=True)
        before = {path: path.read_bytes() for path in (main, gradle)}
        with self.assertRaisesRegex(ValueError, 'probe failed'):
            with native_av_fixture(self.root, 'emulator-5554', 'arm64-v8a'):
                self.assertIn('android-arm64', gradle.read_text())
                self.assertNotIn('android-x64', gradle.read_text())
                raise ValueError('probe failed')
        self.assertTrue(all(path.read_bytes() == data for path, data in before.items()))
        self.assertFalse((client / 'android/app/src/debug/kotlin/dev/voicechat/voicechat_probe/NativeAVMarker.kt').exists())


if __name__ == '__main__':
    unittest.main()
