import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
import prepare_turn_build


class PinnedTurnBuildTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.inputs = self.root / 'turn'
        self.inputs.mkdir()
        self.archive = b'public source fixture'
        self.patch = b'reviewed patch fixture'
        self.manifest = {
            'source_revision': '1' * 40,
            'source_archive_url': 'https://codeload.github.com/coturn/coturn/tar.gz/' + '1' * 40,
            'source_sha256': hashlib.sha256(self.archive).hexdigest(),
            'patch_sha256': hashlib.sha256(self.patch).hexdigest(),
            'base_image': 'coturn/coturn@sha256:' + '2' * 64,
        }
        (self.inputs / 'udp-eperm.patch').write_bytes(self.patch)
        self.context = self.root / 'context'
        self.location = patch.object(prepare_turn_build, '__file__', str(self.root / 'prepare_turn_build.py'))
        self.location.start()
        self.addCleanup(self.location.stop)

    def save(self):
        (self.inputs / 'source.json').write_text(json.dumps(self.manifest))

    def test_verified_source_cache_and_patch_are_reused(self):
        self.save()
        with patch.object(prepare_turn_build, 'urlopen', return_value=io.BytesIO(self.archive)) as download:
            prepare_turn_build.prepare(self.context)
            download.assert_called_once()
        with patch.object(prepare_turn_build, 'urlopen') as download:
            prepare_turn_build.prepare(self.context)
            download.assert_not_called()
        self.assertEqual((self.context / 'udp-eperm.patch').read_bytes(), self.patch)
        self.assertIn(self.manifest['source_sha256'] + '  source.tar.gz', (self.context / 'checksums.txt').read_text())

    def test_corrupt_remote_source_is_not_written(self):
        self.save()
        with patch.object(prepare_turn_build, 'urlopen', return_value=io.BytesIO(b'corrupt')):
            with self.assertRaisesRegex(ValueError, 'archive checksum'):
                prepare_turn_build.prepare(self.context)
        self.assertFalse((self.context / 'source.tar.gz').exists())

    def test_wrong_origin_or_unpinned_base_is_rejected_before_network(self):
        for field, value in [('source_archive_url', 'https://untrusted.invalid/source'),
                             ('source_revision', 'main'), ('base_image', 'coturn/coturn:latest')]:
            with self.subTest(field=field):
                old = self.manifest[field]
                self.manifest[field] = value
                self.save()
                with patch.object(prepare_turn_build, 'urlopen') as download:
                    with self.assertRaises(ValueError):
                        prepare_turn_build.prepare(self.context)
                    download.assert_not_called()
                self.manifest[field] = old

    def test_modified_patch_never_reaches_build_context(self):
        self.save()
        (self.inputs / 'udp-eperm.patch').write_bytes(b'changed')
        with patch.object(prepare_turn_build, 'urlopen', return_value=io.BytesIO(self.archive)):
            with self.assertRaisesRegex(ValueError, 'patch checksum'):
                prepare_turn_build.prepare(self.context)
        self.assertFalse((self.context / 'udp-eperm.patch').exists())


if __name__ == '__main__':
    unittest.main()
