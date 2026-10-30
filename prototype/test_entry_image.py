import base64
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import entry_image


class EntryImageTests(unittest.TestCase):
    image = 'ghcr.io/example/voicechat/web@sha256:' + 'a' * 64

    def test_reader_requests_only_one_pull_scope_and_does_not_return_original_auth(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'config.json'
            auth = base64.b64encode(b'operator:original-password').decode()
            path.write_text(json.dumps({'auths': {'ghcr.io': {'auth': auth}}})); path.chmod(0o600)
            response = Mock(status=200); response.read.return_value = b'{"token":"ephemeral-read-bearer","expires_in":120}'
            response.__enter__ = Mock(return_value=response); response.__exit__ = Mock(return_value=False)
            opener = Mock(); opener.open.return_value = response
            with patch.object(entry_image.urllib.request, 'build_opener', return_value=opener):
                result = entry_image.reader(self.image, path)
            request = opener.open.call_args.args[0]
            self.assertIn('scope=repository%3Aexample%2Fvoicechat%2Fweb%3Apull', request.full_url)
            self.assertNotIn('offline_token', request.full_url)
            self.assertEqual(request.get_header('Authorization'), 'Basic ' + auth)
            self.assertEqual(result['actions'], ['pull'])
            self.assertNotIn(auth, str(result)); self.assertNotIn('original-password', str(result))

    def test_pull_bearer_goes_only_to_local_engine_and_is_not_persisted(self):
        engine = Mock(); response = io.BytesIO(b'{"status":"Downloaded"}\n'); response.status = 200
        engine.getresponse.return_value = response
        with patch.object(entry_image, 'present', side_effect=[False, True]), patch.object(entry_image, 'Engine', return_value=engine):
            result = entry_image.pull(self.image, 'ephemeral-read-bearer')
        method, path = engine.request.call_args.args
        self.assertEqual(method, 'POST'); self.assertIn('/images/create?', path)
        auth = json.loads(base64.urlsafe_b64decode(engine.request.call_args.kwargs['headers']['X-Registry-Auth']))
        self.assertEqual(auth, {'serveraddress': 'ghcr.io', 'registrytoken': 'ephemeral-read-bearer'})
        self.assertTrue(result['image_ready']); self.assertFalse(result['credential_persisted'])
        self.assertNotIn('ephemeral', str(result)); engine.close.assert_called_once()

    def test_cached_image_needs_no_token_and_failure_redacts_registry_error(self):
        with patch.object(entry_image, 'present', return_value=True):
            self.assertTrue(entry_image.pull(self.image)['image_ready'])
        engine = Mock(); engine.getresponse.side_effect = RuntimeError('secret-token')
        with patch.object(entry_image, 'present', return_value=False), patch.object(entry_image, 'Engine', return_value=engine):
            with self.assertRaises(ValueError) as error: entry_image.pull(self.image, 'secret-token')
        self.assertNotIn('secret-token', str(error.exception)); engine.close.assert_called_once()


if __name__ == '__main__': unittest.main()
