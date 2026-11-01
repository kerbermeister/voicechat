import base64
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from fcm import FCM


class FCMTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        path = Path(self.directory.name) / 'test.json'
        path.write_text(json.dumps({'type': 'service_account', 'project_id': 'test-project',
            'client_email': 'sender@test-project.iam.gserviceaccount.com',
            'private_key': self.key.private_bytes(serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()}))
        self.sender = FCM(path)

    def test_signed_oauth_assertion_and_private_data_free_wakeup(self):
        auth = Mock(status_code=200)
        auth.json.return_value = {'access_token': 'oauth-token', 'expires_in': 3600}
        sent = Mock(status_code=200)
        with patch('fcm.requests.post', side_effect=[auth, sent, sent]) as post:
            self.assertEqual(self.sender.send('installation', 'binding', 'notice'), 200)
            self.assertEqual(self.sender.send('installation', 'binding', 'notice'), 200)
        self.assertEqual(post.call_count, 3)  # Cached access token, not a JWT per push.
        assertion = post.call_args_list[0].kwargs['data']['assertion']
        header, payload, signature = assertion.split('.')
        self.key.public_key().verify(base64.urlsafe_b64decode(signature + '=' * (-len(signature) % 4)),
            (header + '.' + payload).encode(), padding.PKCS1v15(), hashes.SHA256())
        claims = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
        self.assertEqual(claims['scope'], 'https://www.googleapis.com/auth/firebase.messaging')
        request = post.call_args_list[1]
        self.assertEqual(request.kwargs['json']['message']['data'], {'binding': 'binding', 'notice': 'notice'})
        self.assertEqual(request.kwargs['json']['message']['android'], {'priority': 'high', 'ttl': '86400s'})
        self.assertNotIn('notification', request.kwargs['json']['message'])
        self.assertFalse(request.kwargs['allow_redirects'])
        self.assertTrue(request.args[0].startswith('https://fcm.googleapis.com/v1/projects/test-project/'))

    def test_only_provider_unregistered_is_permanent(self):
        with patch.object(self.sender, 'access_token', return_value='test'):
            for details, expected in [([], 503), ([{'errorCode': 'UNREGISTERED'}], 410)]:
                response = Mock(status_code=404)
                response.json.return_value = {'error': {'details': details}}
                with patch('fcm.requests.post', return_value=response):
                    self.assertEqual(self.sender.send('t', 'b', 'n'), expected)
            self.sender.token = 'expired'
            with patch('fcm.requests.post', return_value=Mock(status_code=401)):
                self.assertEqual(self.sender.send('t', 'b', 'n'), 401)
            self.assertIsNone(self.sender.token)
