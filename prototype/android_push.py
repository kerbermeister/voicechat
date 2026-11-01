"""Device-scoped Android wakeups and short-lived incoming call notifications.

Bindings grant access only to notification routing, never Matrix or media keys.
"""
import re
import secrets
import time

from web_push import PushStore, PushError

APP_ID = 'dev.voicechat.android'


def validate_fcm_token(token):
    if not isinstance(token, str) or not re.fullmatch(r'[!-~]{20,4096}', token):
        raise PushError('invalid_fcm_token')


class AndroidPushStore(PushStore):
    def __init__(self, directory, origin, deliver, validate):
        super().__init__(directory, origin)
        self.send = deliver
        self.validate = validate
        with self.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS android_devices (
                    binding TEXT PRIMARY KEY, user TEXT NOT NULL, device TEXT NOT NULL,
                    token TEXT UNIQUE NOT NULL, UNIQUE(user, device));
                CREATE TABLE IF NOT EXISTS android_notices (
                    id TEXT PRIMARY KEY, binding TEXT NOT NULL, event TEXT NOT NULL,
                    room TEXT NOT NULL, expires INTEGER NOT NULL,
                    UNIQUE(binding, event));
                CREATE TABLE IF NOT EXISTS push_calls (
                    id TEXT PRIMARY KEY, room TEXT NOT NULL, session TEXT NOT NULL UNIQUE,
                    caller TEXT NOT NULL, caller_device TEXT NOT NULL, expires INTEGER NOT NULL,
                    ended INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS android_deliveries (
                    binding TEXT NOT NULL, event TEXT NOT NULL, sent INTEGER NOT NULL,
                    PRIMARY KEY(binding, event));
                CREATE TABLE IF NOT EXISTS push_call_users (
                    call_id TEXT NOT NULL, user TEXT NOT NULL, state TEXT NOT NULL,
                    device TEXT, PRIMARY KEY(call_id, user));
                CREATE TABLE IF NOT EXISTS call_wakes (
                    binding TEXT NOT NULL, notice TEXT NOT NULL, retry INTEGER NOT NULL, version TEXT NOT NULL,
                    PRIMARY KEY(binding, notice));
            ''')

    def register_android(self, user, device, token):
        validate_fcm_token(token)
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            current = db.execute('SELECT binding,token FROM android_devices WHERE user=? AND device=?', (user, device)).fetchone()
            if current and current[1] == token:
                return current[0]
            if not current and db.execute('SELECT COUNT(*) FROM android_devices WHERE user=?', (user,)).fetchone()[0] >= 20:
                raise PushError('too_many_devices', 429)
            db.execute('DELETE FROM android_devices WHERE (user=? AND device=?) OR token=?', (user, device, token))
            binding = secrets.token_urlsafe(32)
            db.execute('INSERT INTO android_devices VALUES(?,?,?,?)', (binding, user, device, token))
            db.execute('DELETE FROM android_notices WHERE binding NOT IN (SELECT binding FROM android_devices)')
            return binding

    def rotate(self, binding, token):
        validate_fcm_token(token)
        if not isinstance(binding, str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', binding):
            raise PushError('unauthorized', 401)
        with self.connect() as db:
            row = db.execute('SELECT user,device FROM android_devices WHERE binding=?', (binding,)).fetchone()
        if row is None or not self.validate(row[0], row[1], ''):
            raise PushError('device_revoked', 403)
        with self.connect() as db:
            # Token ownership cannot be stolen from another authenticated binding.
            if db.execute('SELECT 1 FROM android_devices WHERE token=? AND binding!=?', (token, binding)).fetchone():
                raise PushError('token_conflict', 409)
            db.execute('UPDATE android_devices SET token=? WHERE binding=?', (token, binding))
        return {'ok': True}

    def android_tokens(self, user, device):
        with self.connect() as db:
            return [r[0] for r in db.execute('SELECT binding FROM android_devices WHERE user=? AND device=?', (user, device))]

    def remove_android(self, user, device):
        tokens = self.android_tokens(user, device)
        with self.connect() as db:
            db.execute('DELETE FROM android_devices WHERE user=? AND device=?', (user, device))
            db.execute('DELETE FROM android_notices WHERE binding NOT IN (SELECT binding FROM android_devices)')
        return tokens

    def resolve(self, binding, notice):
        if not isinstance(binding, str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', binding):
            raise PushError('unauthorized', 401)
        if not isinstance(notice, str) or not re.fullmatch(r'[A-Za-z0-9_-]{32}', notice):
            raise PushError('invalid_notice')
        with self.connect() as db:
            target = db.execute('SELECT user,device FROM android_devices WHERE binding=?', (binding,)).fetchone()
            call = db.execute('SELECT c.room,c.session,c.expires,c.ended,u.state,u.device '
                'FROM push_calls c JOIN push_call_users u ON u.call_id=c.id '
                'WHERE c.id=? AND u.user=?', (notice, target[0] if target else '')).fetchone()
            row = db.execute('SELECT d.user,d.device,n.room,n.event,n.expires FROM android_notices n '
                'JOIN android_devices d ON d.binding=n.binding WHERE n.binding=? AND n.id=?', (binding, notice)).fetchone()
        if target and call:
            if not self.validate(target[0], target[1], call[0]):
                raise PushError('device_revoked', 403)
            ringing = not call[3] and call[4] == 'ringing' and call[2] > time.time()
            return {'room': call[0], 'session': call[1], 'expires': call[2],
                    'kind': 'call' if ringing else 'dismiss', 'call': notice}
        if row is None or row[4] <= time.time():
            raise PushError('notification_expired', 410)
        # Also checked on every receive/click, so a queued FCM cannot revive a revoked device.
        if not self.validate(row[0], row[1], row[2]):
            raise PushError('device_revoked', 403)
        with self.connect() as db:
            ringing = db.execute('SELECT c.id,c.session,c.expires FROM push_calls c '
                'JOIN push_call_users u ON u.call_id=c.id WHERE c.room=? AND u.user=? '
                'AND c.ended=0 AND c.expires>? AND u.state=? ORDER BY c.expires DESC LIMIT 1',
                (row[2], row[0], int(time.time()), 'ringing')).fetchone()
        if ringing:
            return {'room': row[2], 'session': ringing[1], 'expires': ringing[2], 'kind': 'call', 'call': ringing[0]}
        return {'room': row[2], 'event': row[3], 'expires': row[4]}

    def call_action(self, user, device, body, members=None):
        action, session = body.get('action'), body.get('session')
        if not isinstance(session, str) or not re.fullmatch(r'[A-Za-z0-9._:\-]{1,128}', session):
            raise PushError('invalid_session')
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            call = db.execute('SELECT id,room,caller,caller_device,expires,ended FROM push_calls WHERE session=?', (session,)).fetchone()
            if action == 'invite':
                room = body.get('room')
                if not members or user not in members or len(members) > 10:
                    raise PushError('invalid_audience', 403)
                if call:
                    if (call[1], call[2], call[3]) != (room, user, device):
                        raise PushError('call_conflict', 409)
                else:
                    if db.execute('SELECT COUNT(*) FROM push_calls WHERE caller=? AND expires>? AND ended=0',
                            (user, int(time.time()))).fetchone()[0] >= 3:
                        raise PushError('too_many_calls', 429)
                    identifier = secrets.token_urlsafe(24)
                    db.execute('INSERT INTO push_calls VALUES(?,?,?,?,?,?,0)',
                        (identifier, room, session, user, device, int(time.time()) + 45))
                    db.executemany('INSERT INTO push_call_users VALUES(?,?,?,NULL)',
                        [(identifier, member, 'ringing') for member in members if member != user])
                    call = db.execute('SELECT id,room,caller,caller_device,expires,ended FROM push_calls WHERE id=?', (identifier,)).fetchone()
            elif call is None:
                raise PushError('call_not_found', 404)
            elif action == 'end':
                if (call[2], call[3]) != (user, device): raise PushError('forbidden', 403)
                db.execute('UPDATE push_calls SET ended=1 WHERE id=?', (call[0],))
            elif action in ('accept', 'decline'):
                target = db.execute('SELECT state,device FROM push_call_users WHERE call_id=? AND user=?', (call[0], user)).fetchone()
                if not target: raise PushError('forbidden', 403)
                if call[5] or call[4] <= time.time(): raise PushError('call_expired', 410)
                if target[0] != 'ringing' and (target[0], target[1]) != (action, device):
                    raise PushError('answered_elsewhere', 409)
                db.execute('UPDATE push_call_users SET state=?,device=? WHERE call_id=? AND user=?',
                    (action, device, call[0], user))
            elif action != 'status':
                raise PushError('invalid_action')
            audience = db.execute('SELECT user,state,device FROM push_call_users WHERE call_id=?', (call[0],)).fetchall()
            if user != call[2] and not any(row[0] == user for row in audience):
                raise PushError('forbidden', 403)
            ended = db.execute('SELECT ended FROM push_calls WHERE id=?', (call[0],)).fetchone()[0]
            db.execute('DELETE FROM push_call_users WHERE call_id IN (SELECT id FROM push_calls WHERE expires<?)', (int(time.time()) - 86400,))
            db.execute('DELETE FROM push_calls WHERE expires<?', (int(time.time()) - 86400,))
        if action != 'status':
            self.wake_call(call[0], call[1], [row[0] for row in audience] if action in ('invite', 'end') else [user])
        return {'call': call[0], 'ended': bool(ended) or call[4] <= time.time(),
                'declined': bool(audience) and all(row[1] == 'decline' for row in audience),
                'answered': any(row[1] == 'accept' for row in audience),
                'available': any(row[0] == user and (row[1] == 'ringing' or (row[1], row[2]) == ('accept', device)) for row in audience)}

    def wake_call(self, notice, room, users):
        with self.connect() as db:
            devices = db.execute('SELECT binding,user FROM android_devices').fetchall()
            db.executemany('INSERT OR REPLACE INTO call_wakes VALUES(?,?,0,?)',
                [(binding, notice, secrets.token_hex(16)) for binding, user in devices if user in users])

    def advance(self):
        with self.connect() as db:
            db.execute('DELETE FROM call_wakes WHERE binding NOT IN (SELECT binding FROM android_devices) '
                'OR notice NOT IN (SELECT id FROM push_calls WHERE expires>?)', (int(time.time()) - 45,))
            jobs = db.execute('SELECT w.binding,w.notice,d.user,d.device,d.token,c.room,w.version FROM call_wakes w '
                'JOIN android_devices d ON d.binding=w.binding JOIN push_calls c ON c.id=w.notice '
                'WHERE w.retry<=? LIMIT 8', (int(time.time()),)).fetchall()
        for binding, notice, user, device, token, room, version in jobs:
            try:
                if not self.validate(user, device, room):
                    with self.connect() as db:
                        db.execute('DELETE FROM call_wakes WHERE binding=? AND notice=? AND version=?', (binding, notice, version))
                    continue
                code = self.send(token, binding, notice, ttl=45)
                if code == 410:
                    self.remove_android(user, device)
                with self.connect() as db:
                    if 200 <= code < 300 or code == 410:
                        db.execute('DELETE FROM call_wakes WHERE binding=? AND notice=? AND version=?', (binding, notice, version))
                    else:
                        db.execute('UPDATE call_wakes SET retry=? WHERE binding=? AND notice=? AND version=?',
                            (int(time.time()) + 3, binding, notice, version))
            except OSError:
                # Matrix signalling still works; a failed provider cannot undo call state.
                continue

    def bound_call_action(self, binding, body):
        notice = body.get('notice')
        current = self.resolve(binding, notice)
        if current.get('kind') != 'call' or body.get('action') != 'decline':
            raise PushError('call_expired', 410)
        with self.connect() as db:
            user, device = db.execute('SELECT user,device FROM android_devices WHERE binding=?', (binding,)).fetchone()
        return self.call_action(user, device, {'action': 'decline', 'session': current['session']})

    def notify(self, body):
        # Preserve the existing Web Push path for mixed Matrix callbacks.
        result = super().notify(body)
        notification = body['notification']
        if not any(isinstance(device, dict) and device.get('app_id') == APP_ID for device in notification['devices']):
            return result
        event, room = notification.get('event_id'), notification.get('room_id')
        if not event:
            return result
        if not isinstance(room, str) or not 1 <= len(room) <= 255:
            raise PushError('invalid_room')
        for device in notification['devices']:
            if not isinstance(device, dict) or device.get('app_id') != APP_ID:
                continue
            binding = device.get('pushkey')
            if not isinstance(binding, str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', binding):
                continue
            with self._lock:
                if binding in self._sending or len(self._sending) >= 8:
                    raise PushError('push_busy', 503)
                self._sending.add(binding)
            try:
                with self.connect() as db:
                    row = db.execute('SELECT user,device,token FROM android_devices WHERE binding=?', (binding,)).fetchone()
                    sent = db.execute('SELECT 1 FROM android_deliveries WHERE binding=? AND event=?', (binding, event)).fetchone()
                if row is None:
                    result['rejected'].append(binding)
                    continue
                if sent:
                    continue
                if not self.validate(row[0], row[1], room):
                    continue
                notice = secrets.token_urlsafe(24)
                with self.connect() as db:
                    db.execute('DELETE FROM android_notices WHERE expires<=?', (int(time.time()),))
                    db.execute('INSERT OR IGNORE INTO android_notices VALUES(?,?,?,?,?)',
                        (notice, binding, event, room, int(time.time()) + 86400))
                    notice = db.execute('SELECT id FROM android_notices WHERE binding=? AND event=?', (binding, event)).fetchone()[0]
                code = self.send(row[2], binding, notice)
                with self.connect() as db:
                    if code == 410:
                        db.execute('DELETE FROM android_devices WHERE binding=?', (binding,))
                        result['rejected'].append(binding)
                    elif 200 <= code < 300:
                        db.execute('INSERT OR IGNORE INTO android_deliveries VALUES(?,?,?)', (binding, event, int(time.time())))
                        db.execute('DELETE FROM android_deliveries WHERE sent<?', (int(time.time()) - 86400 * 7,))
                    else:
                        raise PushError('push_unavailable', 503)
            finally:
                with self._lock:
                    self._sending.discard(binding)
        return result
