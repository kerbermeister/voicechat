"""Durable ciphertext jobs. Matrix publication is idempotent by job ID, never by an access token."""
from contextlib import contextmanager
import base64
import hashlib
import json
from pathlib import Path
import sqlite3
import threading
import time


class ScheduleError(ValueError):
    def __init__(self, code, status=400):
        super().__init__(code)
        self.status = status


def scheduled_audience(state):
    members = {e['state_key']: e['content'].get('membership') for e in state
               if e.get('type') == 'm.room.member' and e.get('content', {}).get('membership') in ('join', 'invite')}
    marker = next((e['content'] for e in state if e.get('type') == 'dev.voicechat.kind' and e.get('state_key') == ''), None)
    if marker is not None:
        owner, peer = marker.get('owner'), marker.get('peer')
        if marker.get('kind') != 'direct' or not isinstance(owner, str) or not isinstance(peer, str) or owner == peer:
            raise ScheduleError('invalid_direct_room', 403)
        if set(members) != {owner, peer}:
            raise ScheduleError('invalid_direct_room', 403)
        return set(members)
    return {user for user, membership in members.items() if membership == 'join'}


def validate_envelope(payload, device, curve, policy):
    fields = {'algorithm', 'ciphertext', 'session_id', 'sender_key', 'device_id'}
    if not isinstance(payload, dict) or not fields <= payload.keys() or payload.keys() - fields - {'m.relates_to', 'dev.voicechat.ttl_seconds'}:
        raise ScheduleError('invalid_encrypted_payload')
    if payload['algorithm'] != 'm.megolm.v1.aes-sha2' or payload['device_id'] != device or payload['sender_key'] != curve:
        raise ScheduleError('device_key_changed', 409)
    for field, maximum in (('ciphertext', 61440), ('session_id', 43), ('sender_key', 43)):
        value = payload[field]
        if not isinstance(value, str) or not 1 <= len(value) <= maximum:
            raise ScheduleError('invalid_encrypted_payload')
        try:
            decoded = base64.b64decode(value + '=' * (-len(value) % 4), validate=True)
        except (ValueError, TypeError):
            raise ScheduleError('invalid_encrypted_payload') from None
        if field != 'ciphertext' and len(decoded) != 32:
            raise ScheduleError('invalid_encrypted_payload')
    if 'm.relates_to' in payload:
        relation = payload['m.relates_to']
        if not isinstance(relation, dict) or set(relation) != {'m.in_reply_to'} or not isinstance(relation['m.in_reply_to'], dict) or set(relation['m.in_reply_to']) != {'event_id'}:
            raise ScheduleError('invalid_reply')
        event = relation['m.in_reply_to']['event_id']
        if not isinstance(event, str) or not event.startswith('$') or len(event) > 255:
            raise ScheduleError('invalid_reply')
    from client_policy import expiry_content
    expiry_content(payload, policy, 0)


def audience_digest(members, device_keys):
    identities = []
    for user in sorted(members):
        for device, data in sorted(device_keys.get(user, {}).items()):
            keys = data.get('keys', {})
            curve, ed = keys.get('curve25519:' + device), keys.get('ed25519:' + device)
            if not isinstance(curve, str) or not isinstance(ed, str):
                raise ScheduleError('invalid_device_keys')
            identities.append([user, device, curve, ed])
    encoded = json.dumps([sorted(members), identities], ensure_ascii=False, separators=(',', ':')).encode()
    return hashlib.sha256(encoded).hexdigest()


class ScheduledStore:
    def __init__(self, path, publish, clock=time.time):
        self.path, self.publish, self.clock = Path(path), publish, clock
        self.lock = threading.RLock()
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.db() as db:
            db.executescript('''
              CREATE TABLE IF NOT EXISTS messages(
                id TEXT PRIMARY KEY, user_id TEXT NOT NULL, device_id TEXT NOT NULL,
                room_id TEXT NOT NULL, due INTEGER NOT NULL, payload TEXT,
                audience TEXT NOT NULL, state TEXT NOT NULL, error TEXT,
                event_id TEXT, next_attempt INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0);
              CREATE INDEX IF NOT EXISTS scheduled_due ON messages(state,next_attempt,due);
            ''')
            # A crashed publication is retried with the same Matrix transaction ID.
            db.execute("UPDATE messages SET state='retry',next_attempt=? WHERE state='sending'", (int(self.clock() * 1000),))
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            with db: yield db
        finally:
            db.close()

    @staticmethod
    def identifier(user, device, transaction):
        if not isinstance(transaction, str) or not 1 <= len(transaction) <= 128:
            raise ScheduleError('invalid_transaction')
        return hashlib.sha256(json.dumps([user, device, transaction], ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()

    def put(self, user, device, transaction, room, due, payload, audience, maximum_seconds):
        identifier = self.identifier(user, device, transaction)
        now = int(self.clock() * 1000)
        encoded = json.dumps(payload, separators=(',', ':'))
        if not isinstance(room, str) or not room.startswith('!') or len(room) > 255:
            raise ScheduleError('invalid_room')
        if len(encoded.encode()) > 65536 or not isinstance(payload, dict):
            raise ScheduleError('invalid_payload')
        if not isinstance(audience, str) or len(audience) != 64:
            raise ScheduleError('invalid_audience')
        with self.lock, self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            old = db.execute('SELECT room_id FROM messages WHERE id=?', (identifier,)).fetchone()
            if old is not None:
                if old['room_id'] != room: raise ScheduleError('transaction_reused', 409)
                return identifier
            if type(due) is not int or not now < due <= now + maximum_seconds * 1000:
                raise ScheduleError('invalid_schedule_time')
            count = db.execute("SELECT count(*) FROM messages WHERE user_id=? AND payload IS NOT NULL", (user,)).fetchone()[0]
            if count >= 100: raise ScheduleError('too_many_scheduled_messages', 409)
            db.execute('INSERT INTO messages(id,user_id,device_id,room_id,due,payload,audience,state,next_attempt) VALUES(?,?,?,?,?,?,?,?,?)',
                       (identifier, user, device, room, due, encoded, audience, 'pending', due))
        return identifier

    def get(self, user, identifier):
        with self.db() as db:
            row = db.execute('SELECT * FROM messages WHERE user_id=? AND id=?', (user, identifier)).fetchone()
        if row is None: raise ScheduleError('not_found', 404)
        result = dict(row)
        result['payload'] = None if row['payload'] is None else json.loads(row['payload'])
        return result

    def list(self, user):
        with self.db() as db:
            return [dict(row) for row in db.execute('''
                SELECT id,room_id,due,state,error,event_id FROM messages WHERE user_id=?
                ORDER BY payload IS NULL,CASE WHEN payload IS NOT NULL THEN due END ASC,due DESC LIMIT 200
            ''', (user,))]

    def cancel(self, user, identifier):
        with self.lock, self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT state,attempts FROM messages WHERE user_id=? AND id=?', (user, identifier)).fetchone()
            if row is None: raise ScheduleError('not_found', 404)
            if row['state'] in ('sending', 'sent') or row['state'] == 'retry' and row['attempts'] > 0:
                raise ScheduleError('already_publishing', 409)
            db.execute("UPDATE messages SET state='cancelled',payload=NULL,error=NULL WHERE id=?", (identifier,))

    def withdraw(self, user, device, transaction, room):
        identifier = self.identifier(user, device, transaction)
        if not isinstance(room, str) or not room.startswith('!') or len(room) > 255:
            raise ScheduleError('invalid_room')
        with self.lock, self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            old = db.execute('SELECT room_id FROM messages WHERE id=?', (identifier,)).fetchone()
            if old is None:
                # Tombstone also stops an earlier create whose HTTP reply was lost.
                db.execute("INSERT INTO messages(id,user_id,device_id,room_id,due,audience,state,next_attempt) VALUES(?,?,?,?,0,'','cancelled',0)",
                           (identifier, user, device, room))
            elif old['room_id'] != room:
                raise ScheduleError('transaction_reused', 409)
        self.cancel(user, identifier)

    def advance(self):
        now = int(self.clock() * 1000)
        with self.lock, self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute("SELECT * FROM messages WHERE state IN ('pending','retry','sending') AND due<=? AND next_attempt<=? ORDER BY due LIMIT 1", (now, now)).fetchone()
            if row is None: return False
            db.execute("UPDATE messages SET state='sending',attempts=attempts+1,next_attempt=? WHERE id=?", (now + 30000, row['id']))
        job = dict(row)
        job['payload'] = json.loads(row['payload'])
        try:
            event = self.publish(job)
            if not isinstance(event, str) or not event.startswith('$'):
                raise ValueError('Publication not confirmed')
        except Exception as error:
            permanent = isinstance(error, ScheduleError) and error.status in (400, 401, 403, 404, 409, 410)
            code = str(error) if permanent else 'server_unavailable'
            retry = int(self.clock() * 1000) + min(60000, 1000 * 2 ** min(row['attempts'], 6))
            with self.lock, self.db() as db:
                db.execute('UPDATE messages SET state=?,error=?,next_attempt=? WHERE id=?',
                           ('failed' if permanent else 'retry', code, retry, row['id']))
        else:
            with self.lock, self.db() as db:
                db.execute("UPDATE messages SET state='sent',event_id=?,payload=NULL,error=NULL WHERE id=?", (event, row['id']))
        return True
