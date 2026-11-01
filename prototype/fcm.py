"""FCM HTTP v1 transport. Credentials are read only from an external secret file."""
import base64
import json
import re
import threading
import time
from pathlib import Path

import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding


class FCM:
    def __init__(self, path):
        value = json.loads(Path(path).read_text())
        self.project = value['project_id']
        if value.get('type') != 'service_account' or not re.fullmatch(r'[a-z][a-z0-9-]{4,62}', self.project):
            raise ValueError('Invalid FCM service account')
        self.email = value['client_email']
        self.key = serialization.load_pem_private_key(value['private_key'].encode(), password=None)
        self.lock = threading.Lock()
        self.token = None
        self.expires = 0

    def access_token(self):
        with self.lock:
            if self.token and time.time() < self.expires:
                return self.token
            def encode(value):
                return base64.urlsafe_b64encode(value).rstrip(b'=')
            now = int(time.time())
            claims = {'iss': self.email, 'scope': 'https://www.googleapis.com/auth/firebase.messaging',
                      'aud': 'https://oauth2.googleapis.com/token', 'iat': now, 'exp': now + 3600}
            signing = encode(b'{"alg":"RS256","typ":"JWT"}') + b'.' + encode(json.dumps(claims).encode())
            signature = self.key.sign(signing, padding.PKCS1v15(), hashes.SHA256())
            response = requests.post('https://oauth2.googleapis.com/token', data={
                'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                'assertion': (signing + b'.' + encode(signature)).decode()}, timeout=5, allow_redirects=False)
            if response.status_code != 200:
                raise ValueError('FCM authentication failed')
            result = response.json()
            self.token = result['access_token']
            self.expires = now + min(int(result['expires_in']), 3600) - 60
            return self.token

    def send(self, token, binding, notice, validate_only=False, ttl=86400):
        # No notification payload: Android validates the binding and current server
        # state before displaying anything, including after logout/revocation.
        body = {'validate_only': validate_only, 'message': {
            'token': token, 'data': {'binding': binding, 'notice': notice},
            'android': {'priority': 'high', 'ttl': f'{ttl}s'}}}
        try:
            response = requests.post(f'https://fcm.googleapis.com/v1/projects/{self.project}/messages:send',
                json=body, headers={'Authorization': 'Bearer ' + self.access_token()}, timeout=5, allow_redirects=False)
            if response.status_code == 401:
                with self.lock:
                    self.token = None
            if response.status_code == 404:
                details = response.json().get('error', {}).get('details', [])
                # Only UNREGISTERED means this installation should be removed.
                if any(item.get('errorCode') == 'UNREGISTERED' for item in details):
                    return 410
                return 503
            return response.status_code
        except (requests.RequestException, ValueError, KeyError, TypeError):
            return 503
