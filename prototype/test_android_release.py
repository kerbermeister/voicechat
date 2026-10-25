import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'infra'))
import android_release as release


class AndroidReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)/'server'
        self.root.mkdir()

    def candidate(self, build=2, name='1.1.0', content=b'apk'):
        folder = Path(self.temp.name)/('candidate-'+str(build))
        folder.mkdir(exist_ok=True)
        (folder/'voicechat.apk').write_bytes(content)
        data = dict(schema=1, applicationId=release.PACKAGE, versionName=name, versionCode=build,
                    minSdk=24, apkPath=f'/updates/android/{build}/voicechat.apk', sizeBytes=len(content),
                    sha256=hashlib.sha256(content).hexdigest(), notes='Changes')
        (folder/'latest.json').write_text(json.dumps(data))
        return folder, data

    def publish(self, candidate):
        release.publish(candidate, self.root, 'https://updates.test', verify=lambda *_: None)

    def test_version_and_changelog_match(self):
        name, code, notes = release.version()
        self.assertRegex(name, r'^\d+\.\d+\.\d+$')
        self.assertGreater(code, 0)
        self.assertTrue(notes)

    def test_failed_public_verification_keeps_old_pointer_and_retry_is_safe(self):
        first, old = self.candidate()
        self.publish(first)
        second, new = self.candidate(3, '1.1.1')
        def fail(*_): raise OSError('public server unavailable')
        with self.assertRaises(OSError): release.publish(second, self.root, 'https://updates.test', verify=fail)
        self.assertEqual(release.load_manifest(self.root/'latest.json'), old)
        self.publish(second)
        self.assertEqual(release.load_manifest(self.root/'latest.json'), new)
        self.assertEqual(release.load_manifest(self.root/'previous.json'), old)
        self.publish(second)
        self.assertEqual(release.load_manifest(self.root/'previous.json'), old)

    def test_immutable_build_and_monotonic_versions_even_after_withdrawal(self):
        first, _ = self.candidate()
        self.publish(first)
        first, _ = self.candidate(content=b'other')
        with self.assertRaisesRegex(ValueError, 'immutable'): self.publish(first)
        same_version, _ = self.candidate(3, '1.1.0')
        with self.assertRaisesRegex(ValueError, 'increase'): self.publish(same_version)
        third, _ = self.candidate(4, '1.1.1')
        self.publish(third)
        with patch.object(release, 'verify_public'):
            release.withdraw(self.root, 'https://updates.test')
        between, _ = self.candidate(3, '1.1.2')
        with self.assertRaisesRegex(ValueError, 'increase'): self.publish(between)

    def test_corrupted_candidate_and_duplicate_fields_are_rejected(self):
        candidate, _ = self.candidate()
        (candidate/'voicechat.apk').write_bytes(b'bad')
        with self.assertRaisesRegex(ValueError, 'checksum'): self.publish(candidate)
        self.assertFalse((self.root/'latest.json').exists())
        path = candidate/'latest.json'
        path.write_text(path.read_text().replace('{', '{"schema":1,', 1))
        with self.assertRaisesRegex(ValueError, 'Duplicate'): release.load_manifest(path)

    def test_unexpected_paths_types_and_sizes(self):
        _, data = self.candidate()
        for change in ({'versionCode': True}, {'apkPath': '/../../secret'}, {'sizeBytes': release.MAX_APK+1}, {'notes': ''}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                release.validate_manifest({**data, **change})

    def test_concurrent_publishers_are_serialized(self):
        import threading
        first, old = self.candidate()
        second, new = self.candidate(3, '1.1.1')
        entered, proceed, second_verification = (threading.Event() for _ in range(3))
        errors = []
        def verify_first(*_):
            entered.set()
            if not proceed.wait(3): raise TimeoutError('test publication did not resume')
        def run(candidate, verify):
            try: release.publish(candidate, self.root, 'https://updates.test', verify=verify)
            except Exception as error: errors.append(error)
        a = threading.Thread(target=run, args=(first, verify_first))
        b = threading.Thread(target=run, args=(second, lambda *_: second_verification.set()))
        a.start()
        self.assertTrue(entered.wait(2))
        b.start()
        self.assertFalse(second_verification.wait(.1))
        proceed.set()
        a.join(3); b.join(3)
        self.assertFalse(a.is_alive() or b.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(release.load_manifest(self.root/'latest.json'), new)
        self.assertEqual(release.load_manifest(self.root/'previous.json'), old)

    def test_withdrawing_first_release_disables_channel_without_deleting_apk(self):
        candidate, data = self.candidate()
        self.publish(candidate)
        release.withdraw(self.root, 'https://updates.test')
        self.assertFalse((self.root/'latest.json').exists())
        self.assertEqual(release.load_manifest(self.root/'withdrawn.json'), data)
        self.assertTrue((self.root/'2/voicechat.apk').exists())

class AndroidAcceptanceGateTests(unittest.TestCase):
    def test_publication_requires_exact_accepted_checksum_before_ssh(self):
        import publish_android_ssh
        data = dict(versionCode=2, sha256='a'*64)
        with patch.object(sys, 'argv', ['publish_android_ssh.py', '/tmp/candidate']), \
             patch.object(publish_android_ssh, 'load_manifest', return_value=data), \
             patch.dict('os.environ', {'ANDROID_ACCEPTED_BUILD':'2','ANDROID_ACCEPTED_SHA256':'b'*64}), \
             patch.object(publish_android_ssh, 'connection') as connection:
            with self.assertRaisesRegex(SystemExit, 'exact APK checksum'):
                publish_android_ssh.main()
            connection.assert_not_called()


if __name__ == '__main__': unittest.main()
