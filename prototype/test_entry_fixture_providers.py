"""The disposable registry must preserve and verify the saved OCI image graph."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import entry_fixture_providers as fixture


class EntryFixtureProviderTests(unittest.TestCase):
    def image(self, root, *, corrupt=False):
        blobs = {}
        def blob(raw, media):
            digest = 'sha256:' + hashlib.sha256(raw).hexdigest()
            blobs[digest] = raw
            return {'digest': digest, 'size': len(raw), 'mediaType': media}
        config = blob(b'{"architecture":"amd64","os":"linux"}', 'application/vnd.oci.image.config.v1+json')
        layer = blob(b'synthetic compressed layer', 'application/vnd.oci.image.layer.v1.tar+gzip')
        manifest = blob(json.dumps({'schemaVersion': 2, 'mediaType': 'application/vnd.oci.image.manifest.v1+json',
            'config': config, 'layers': [layer]}).encode(), 'application/vnd.oci.image.manifest.v1+json')
        index = blob(json.dumps({'schemaVersion': 2, 'mediaType': 'application/vnd.oci.image.index.v1+json',
            'manifests': [manifest]}).encode(), 'application/vnd.oci.image.index.v1+json')
        (root / 'expected-images.json').write_text(json.dumps({'web': index['digest']}))
        with tarfile.open(root / 'raw-web.tar', 'w') as archive:
            for digest, raw in blobs.items():
                if corrupt and digest == layer['digest']: raw = b'x' * len(raw)
                info = tarfile.TarInfo('blobs/sha256/' + digest.removeprefix('sha256:'))
                info.size = len(raw); archive.addfile(info, io.BytesIO(raw))
        return index, manifest, config, blobs

    def test_containerd_index_id_is_preserved_with_verified_graph(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); index, manifest, config, blobs = self.image(root)
            self.assertNotEqual(index['digest'], config['digest'])
            with patch.object(fixture, 'owned'), patch.object(fixture.subprocess, 'check_output', return_value=(index['digest']+'\n').encode()), patch('builtins.print'):
                fixture.build(root)
            repo = json.loads((root/'registry/repositories.json').read_text())['voicechat-fixture/mesh-web']
            self.assertEqual(repo['digest'], index['digest'])
            self.assertEqual(set(repo['blobs']), set(blobs))
            self.assertEqual(set(repo['manifests']), {index['digest'], manifest['digest']})
            for digest, raw in blobs.items():
                self.assertEqual((root/'registry/blobs'/digest.removeprefix('sha256:')).read_bytes(), raw)

    def test_saved_blob_corruption_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); index, _, _, _ = self.image(root, corrupt=True)
            with patch.object(fixture, 'owned'), patch.object(fixture.subprocess, 'check_output', return_value=(index['digest']+'\n').encode()):
                with self.assertRaisesRegex(ValueError, 'digest changed'): fixture.build(root)
            self.assertFalse((root/'registry/repositories.json').exists())
