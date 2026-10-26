import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('publish_macos', Path(__file__).resolve().parents[1] / 'infra/publish_macos.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class MacOSPublishTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.root = self.directory / 'published'
        self.origin = 'https://example.com'

    def candidate(self, build, previous=None):
        path = self.directory / ('candidate-' + build)
        path.mkdir()
        (path / 'VoiceChat.zip').write_bytes(b'zip fixture ' + build.encode())
        (path / 'VoiceChat.dmg').write_bytes(b'dmg fixture ' + build.encode())
        (path / 'appcast.xml').write_text(f'''<rss xmlns:sparkle="{m.SPARKLE}"><channel><item><enclosure
          sparkle:version="{build}" sparkle:edSignature="fixture-signature"
          url="{self.origin}/updates/macos/{build}/VoiceChat.zip"
          length="{(path / 'VoiceChat.zip').stat().st_size}"/></item></channel></rss>''')
        manifest = {'build': build, 'distributable': True, 'sourceDirty': False,
                    'architecture': 'arm64', 'feedURL': self.origin + '/updates/macos/appcast.xml',
                    'previousFeedSha256': previous,
                    'files': {p.name: m.digest(p) for p in path.iterdir()}}
        (path / 'release.json').write_text(json.dumps(manifest))
        return path, manifest

    def promote(self, path, manifest):
        m.publish(path, self.root, self.origin, manifest['build'], manifest['files']['VoiceChat.zip'])

    def test_atomic_feed_and_immutable_archives_with_safe_retry(self):
        first, manifest = self.candidate('2')
        self.promote(first, manifest)
        original = (self.root / 'appcast.xml').read_bytes()
        self.promote(first, manifest)
        self.assertEqual((self.root / 'appcast.xml').read_bytes(), original)
        stale, stale_manifest = self.candidate('3')
        with self.assertRaises(ValueError):
            self.promote(stale, stale_manifest)
        self.assertEqual((self.root / 'appcast.xml').read_bytes(), original)
        self.assertFalse((self.root / '3').exists())
        next_path, next_manifest = self.candidate('4', m.digest(self.root / 'appcast.xml'))
        self.promote(next_path, next_manifest)
        self.assertEqual(m.digest(self.root / 'appcast.xml'), next_manifest['files']['appcast.xml'])
        self.assertTrue((self.root / '2/VoiceChat.zip').is_file())
        # Revoking a feed item must not permit a lower number than an archive
        # that was already distributed to users.
        (self.root / '9').mkdir()
        older, older_manifest = self.candidate('5', m.digest(self.root / 'appcast.xml'))
        with self.assertRaises(ValueError):
            self.promote(older, older_manifest)

    def test_corruption_unaccepted_and_unsigned_candidates_cannot_publish(self):
        path, manifest = self.candidate('2')
        with self.assertRaises(ValueError):
            m.publish(path, self.root, self.origin, '2', 'different-checksum')
        manifest['distributable'] = False
        (path / 'release.json').write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            self.promote(path, manifest)
        manifest['distributable'] = True
        (path / 'release.json').write_text(json.dumps(manifest))
        (path / 'VoiceChat.zip').write_bytes(b'corrupt')
        with self.assertRaises(ValueError):
            self.promote(path, manifest)
        self.assertFalse(self.root.exists())


if __name__ == '__main__':
    unittest.main()
