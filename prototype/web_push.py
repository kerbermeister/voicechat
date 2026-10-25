"""Matrix push gateway. Pushes contain no message, sender, room or encryption keys."""
import base64
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import threading
import time
from urllib.parse import urlsplit

APP_ID = 'dev.voicechat.web'

class PushError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def validate_subscription(value):
    if not isinstance(value, dict) or set(value) - {'endpoint', 'expirationTime', 'keys'}:
        raise PushError('invalid_subscription')
    endpoint = value.get('endpoint')
    if not isinstance(endpoint, str) or not 20 <= len(endpoint) <= 2048:
        raise PushError('invalid_endpoint')
    try:
        uri = urlsplit(endpoint)
        # Only browser push providers are destinations; arbitrary URLs would allow SSRF.
        allowed = uri.hostname in {'web.push.apple.com', 'fcm.googleapis.com', 'updates.push.services.mozilla.com'} or (
            uri.hostname is not None and uri.hostname.endswith('.push.apple.com'))
        if uri.scheme != 'https' or uri.port not in (None, 443) or uri.username or uri.password or uri.fragment or not allowed:
            raise ValueError()
    except ValueError:
        raise PushError('invalid_endpoint') from None
    keys = value.get('keys')
    if not isinstance(keys, dict) or set(keys) != {'auth', 'p256dh'}:
        raise PushError('invalid_keys')
    for name, size in [('auth', 16), ('p256dh', 65)]:
        key = keys[name]
        if not isinstance(key, str) or not re.fullmatch(r'[A-Za-z0-9_-]{20,90}={0,2}', key):
            raise PushError('invalid_keys')
        try:
            decoded = base64.urlsafe_b64decode(key + '=' * (-len(key) % 4))
        except ValueError:
            raise PushError('invalid_keys') from None
        if len(decoded) != size or name == 'p256dh' and decoded[0] != 4:
            raise PushError('invalid_keys')
        if name == 'p256dh':
            from cryptography.hazmat.primitives.asymmetric import ec
            try:
                ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), decoded)
            except ValueError:
                raise PushError('invalid_keys') from None
    return {'endpoint': endpoint, 'keys': keys}


class PushStore:
    def __init__(self, directory, origin, deliver=None):
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        import fcntl
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.directory / 'subscriptions.sqlite'
        self.key = self.directory / 'vapid.pem'
        self.origin = origin.rstrip('/')
        uri = urlsplit(self.origin)
        if uri.scheme not in ('https', 'http') or not uri.hostname or uri.path or uri.query or uri.fragment:
            raise ValueError('Invalid push origin')
        self._lock = threading.Lock()
        self._sending = set()
        self.deliver = deliver or self._deliver
        with (self.directory / 'key.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if not self.key.exists():
                private = ec.generate_private_key(ec.SECP256R1())
                temporary = self.directory / 'vapid.tmp'
                with os.fdopen(os.open(temporary, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600), 'wb') as output:
                    output.write(private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, self.key)
            private = serialization.load_pem_private_key(self.key.read_bytes(), password=None)
            raw = private.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
            self.public_key = base64.urlsafe_b64encode(raw).rstrip(b'=').decode()
        with self.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS subscriptions (
                    token TEXT PRIMARY KEY, user TEXT NOT NULL, device TEXT NOT NULL,
                    endpoint TEXT UNIQUE NOT NULL, subscription TEXT NOT NULL, updated INTEGER NOT NULL,
                    UNIQUE(user, device));
                CREATE TABLE IF NOT EXISTS deliveries (
                    token TEXT NOT NULL, event TEXT NOT NULL, sent INTEGER NOT NULL,
                    PRIMARY KEY(token, event));
                CREATE INDEX IF NOT EXISTS delivery_time ON deliveries(sent);
            ''')
        os.chmod(self.path, 0o600)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        try:
            with db:
                yield db
        finally:
            db.close()

    def register(self, user, device, subscription):
        subscription = validate_subscription(subscription)
        token = secrets.token_urlsafe(32)
        with self.connect() as db:
            if db.execute('SELECT COUNT(*) FROM subscriptions WHERE user=?', (user,)).fetchone()[0] >= 20 and not db.execute('SELECT 1 FROM subscriptions WHERE user=? AND device=?', (user, device)).fetchone():
                raise PushError('too_many_devices', 429)
            db.execute('DELETE FROM subscriptions WHERE (user=? AND device=?) OR endpoint=?', (user, device, subscription['endpoint']))
            db.execute('INSERT INTO subscriptions VALUES (?,?,?,?,?,?)', (token, user, device, subscription['endpoint'], json.dumps(subscription), int(time.time())))
            db.execute('DELETE FROM deliveries WHERE sent<? OR token NOT IN (SELECT token FROM subscriptions)', (int(time.time()) - 86400 * 7,))
        return token

    def tokens(self, user, device):
        with self.connect() as db:
            return [row[0] for row in db.execute('SELECT token FROM subscriptions WHERE user=? AND device=?', (user, device))]

    def remove(self, user, device):
        with self.connect() as db:
            tokens = [row[0] for row in db.execute('SELECT token FROM subscriptions WHERE user=? AND device=?', (user, device))]
            db.execute('DELETE FROM subscriptions WHERE user=? AND device=?', (user, device))
        return tokens

    def _deliver(self, subscription, payload):
        from pywebpush import webpush, WebPushException
        from requests import Session, RequestException
        class NoRedirectSession(Session):
            def request(self, *args, **kwargs):
                kwargs['allow_redirects'] = False
                return super().request(*args, **kwargs)
        try:
            with NoRedirectSession() as session:
                response = webpush(subscription_info=subscription, data=json.dumps(payload), vapid_private_key=str(self.key), vapid_claims={'sub': self.origin}, ttl=60, timeout=5, headers={'Urgency': 'high'}, requests_session=session)
                return response.status_code
        except WebPushException as error:
            return error.response.status_code if error.response is not None else 503
        except RequestException:
            return 503

    def notify(self, body):
        notification = body.get('notification') if isinstance(body, dict) else None
        if not isinstance(notification, dict): raise PushError('invalid_notification')
        devices = notification.get('devices')
        if not isinstance(devices, list) or len(devices) > 20: raise PushError('invalid_devices')
        event = notification.get('event_id')
        if event is not None and (not isinstance(event, str) or not 1 <= len(event) <= 255): raise PushError('invalid_event')
        rejected = []
        for device in devices:
            if not isinstance(device, dict) or device.get('app_id') != APP_ID: continue
            token = device.get('pushkey')
            if not isinstance(token, str) or len(token) != 43:
                continue
            with self.connect() as db:
                row = db.execute('SELECT subscription FROM subscriptions WHERE token=?', (token,)).fetchone()
                delivered = db.execute('SELECT 1 FROM deliveries WHERE token=? AND event=?', (token, event)).fetchone()
            if row is None:
                rejected.append(token)
                continue
            if not event or delivered: continue  # Count-only updates do not alert.
            with self._lock:
                if token in self._sending or len(self._sending) >= 8: raise PushError('push_busy', 503)
                self._sending.add(token)
            try:
                # Recheck under the in-flight guard; concurrent retries must not duplicate a push.
                with self.connect() as db:
                    if db.execute('SELECT 1 FROM deliveries WHERE token=? AND event=?', (token, event)).fetchone(): continue
                code = self.deliver(json.loads(row[0]), {'title': 'VoiceChat', 'body': 'Новое сообщение или входящий звонок', 'binding': token})
                with self.connect() as db:
                    if code in (404, 410):
                        db.execute('DELETE FROM subscriptions WHERE token=?', (token,))
                        rejected.append(token)
                    elif 200 <= code < 300:
                        db.execute('INSERT OR IGNORE INTO deliveries VALUES (?,?,?)', (token, event, int(time.time())))
                        db.execute('DELETE FROM deliveries WHERE sent<?', (int(time.time()) - 86400 * 7,))
                    else:
                        raise PushError('push_unavailable', 503)
            finally:
                with self._lock: self._sending.discard(token)
        return {'rejected': rejected}
