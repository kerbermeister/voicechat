from contextlib import contextmanager
import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
import prepare_android_webrtc as sdk


class NativeSdkDownloadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.cache = Path(temporary.name)
        self.payload = b'synthetic native SDK archive'
        self.version = '150.7871.04-vc1'
        self.manifest = {'release_artifact_version': self.version, 'artifacts': {'android': {
            'url': f'https://github.com/kerbermeister/voicechat/releases/download/webrtc-sdk-{self.version}/libwebrtc.aar',
            'sha256': hashlib.sha256(self.payload).hexdigest(), 'size_bytes': len(self.payload)}}}

    @contextmanager
    def response(self, payload):
        yield io.BytesIO(payload)

    def test_verified_download_cache_and_corruption_rejection(self):
        with patch.object(sdk, 'urlopen', return_value=self.response(self.payload)) as download:
            repository = sdk.prepare(self.manifest, self.cache)
            download.assert_called_once()
        with patch.object(sdk, 'urlopen') as download:
            self.assertEqual(sdk.prepare(self.manifest, self.cache), repository)
            download.assert_not_called()
        aar = next(repository.rglob('*.aar'))
        self.assertEqual(aar.read_bytes(), self.payload)
        aar.write_bytes(b'corrupted cached binary')
        with self.assertRaisesRegex(ValueError, 'Cached native SDK'):
            sdk.prepare(self.manifest, self.cache)
        self.assertEqual(aar.read_bytes(), b'corrupted cached binary')

    def test_android_version_is_independent_of_macos_version(self):
        self.manifest['artifacts']['android']['release_artifact_version'] = self.version
        self.manifest['release_artifact_version'] = '150.7871.04-vc999'
        with patch.object(sdk, 'urlopen', return_value=self.response(self.payload)):
            repository = sdk.prepare(self.manifest, self.cache)
        self.assertEqual(next(repository.rglob('*.aar')).parent.name, self.version)

    def test_changed_maven_metadata_is_rejected(self):
        with patch.object(sdk, 'urlopen', return_value=self.response(self.payload)):
            repository = sdk.prepare(self.manifest, self.cache)
        pom = next(repository.rglob('*.pom'))
        pom.write_text('<project>different coordinates</project>')
        with self.assertRaisesRegex(ValueError, 'metadata'):
            sdk.prepare(self.manifest, self.cache)
        self.assertEqual(pom.read_text(), '<project>different coordinates</project>')

    def test_bad_response_is_never_published(self):
        for payload in (b'short', b'x' * len(self.payload), self.payload + b'oversized'):
            with self.subTest(payload_size=len(payload)):
                with patch.object(sdk, 'urlopen', return_value=self.response(payload)):
                    with self.assertRaises(ValueError):
                        sdk.prepare(self.manifest, self.cache)
                self.assertFalse(list(self.cache.rglob('*.aar')))
                self.assertFalse(list(self.cache.rglob('tmp*')))

    def test_unexpected_source_and_path_version_are_rejected_before_network(self):
        with patch.object(sdk, 'urlopen') as download:
            self.manifest['artifacts']['android']['url'] = 'https://example.invalid/sdk.aar'
            with self.assertRaisesRegex(ValueError, 'origin'):
                sdk.prepare(self.manifest, self.cache)
            self.manifest['release_artifact_version'] = '../escape'
            with self.assertRaisesRegex(ValueError, 'version'):
                sdk.prepare(self.manifest, self.cache)
            download.assert_not_called()

    def test_symlink_archive_is_rejected_without_touching_target(self):
        expected = self.manifest['artifacts']['android']['sha256']
        directory = self.cache / expected / 'maven/io/github/webrtc-sdk/android' / self.version
        directory.mkdir(parents=True)
        foreign = self.cache / 'foreign'
        foreign.write_bytes(b'preserve me')
        (directory / f'android-{self.version}.aar').symlink_to(foreign)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            sdk.prepare(self.manifest, self.cache)
        self.assertEqual(foreign.read_bytes(), b'preserve me')
