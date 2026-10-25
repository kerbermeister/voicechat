"""Contact consent metadata only; no Matrix access tokens, media or private keys."""
from contextlib import contextmanager
import sqlite3
import time
import uuid
import hashlib
import json
import re
import secrets
from pathlib import Path

DEFAULT_PATH = Path(__file__).resolve().parents[1] / '.prototype/contacts/contacts.sqlite'

class ContactError(ValueError):
    pass

class ContactStore:
    def __init__(self, path=DEFAULT_PATH):
        self.path = Path(path)
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript('''
              CREATE TABLE IF NOT EXISTS policies(user_id TEXT PRIMARY KEY, allow_direct INTEGER NOT NULL CHECK(allow_direct IN (0,1)));
              CREATE TABLE IF NOT EXISTS contacts(
                pair TEXT PRIMARY KEY, id TEXT NOT NULL UNIQUE, sender TEXT NOT NULL, recipient TEXT NOT NULL,
                room_id TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','accepted','declined','cancelled')),
                created INTEGER NOT NULL, updated INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS contact_links(
                id TEXT PRIMARY KEY, owner TEXT NOT NULL, created INTEGER NOT NULL,
                claimant TEXT, room_id TEXT, device_id TEXT, payload TEXT,
                audience TEXT, event_id TEXT);
            ''')
    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        try:
            with db: yield db
        finally:
            db.close()
    @staticmethod
    def pair(first, second):
        if not all(isinstance(u, str) and u.startswith('@') and ':' in u and len(u) <= 255 and not any(c.isspace() for c in u) for u in (first, second)) or first == second:
            raise ContactError('invalid_user')
        return '\0'.join(sorted((first, second)))
    def policy(self, user):
        with self.connect() as db:
            row = db.execute('SELECT allow_direct FROM policies WHERE user_id=?', (user,)).fetchone()
            return bool(row['allow_direct']) if row else True
    def set_policy(self, user, allow):
        if type(allow) is not bool:
            raise ContactError('invalid_policy')
        with self.connect() as db:
            db.execute('INSERT INTO policies VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET allow_direct=excluded.allow_direct', (user, int(allow)))
    def list(self, user):
        with self.connect() as db:
            return [dict(r) for r in db.execute('SELECT id,sender,recipient,room_id,state,created,updated FROM contacts WHERE sender=? OR recipient=? ORDER BY updated DESC', (user,user))]
    def request(self, sender, recipient, room):
        pair = self.pair(sender, recipient)
        if not isinstance(room, str) or not room.startswith('!') or len(room) > 255:
            raise ContactError('invalid_room')
        now = int(time.time() * 1000)
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            existing = db.execute('SELECT * FROM contacts WHERE pair=?', (pair,)).fetchone()
            if existing and existing['state'] == 'cancelled':
                db.execute('DELETE FROM contacts WHERE pair=?', (pair,))
                existing = None
            if existing:
                if existing['state'] == 'accepted' and existing['room_id'] != room:
                    db.execute('UPDATE contacts SET sender=?,recipient=?,room_id=?,updated=? WHERE pair=?', (sender,recipient,room,now,pair))
                if existing['state'] == 'pending' and existing['sender'] == recipient:
                    db.execute("UPDATE contacts SET state='accepted',updated=? WHERE pair=?", (now,pair))
                return dict(db.execute('SELECT id,sender,recipient,room_id,state,created,updated FROM contacts WHERE pair=?', (pair,)).fetchone())
            row = db.execute('SELECT allow_direct FROM policies WHERE user_id=?', (recipient,)).fetchone()
            state = 'accepted' if row is None or row['allow_direct'] else 'pending'
            db.execute('INSERT INTO contacts VALUES(?,?,?,?,?,?,?,?)', (pair,uuid.uuid4().hex,sender,recipient,room,state,now,now))
            return dict(db.execute('SELECT id,sender,recipient,room_id,state,created,updated FROM contacts WHERE pair=?', (pair,)).fetchone())
    def decide(self, user, request_id, action):
        if action not in ('accept','decline','cancel'):
            raise ContactError('invalid_action')
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT * FROM contacts WHERE id=?', (request_id,)).fetchone()
            if row is None or user != row['sender' if action == 'cancel' else 'recipient']:
                raise ContactError('forbidden')
            state = {'accept':'accepted','decline':'declined','cancel':'cancelled'}[action]
            if row['state'] != 'pending' and row['state'] != state:
                raise ContactError('already_decided')
            db.execute('UPDATE contacts SET state=?,updated=? WHERE id=?', (state,int(time.time()*1000),request_id))
            return state
    def accepted(self, first, second):
        with self.connect() as db:
            row = db.execute('SELECT state FROM contacts WHERE pair=?', (self.pair(first,second),)).fetchone()
            return row is not None and row['state'] == 'accepted'

    @staticmethod
    def link_id(token):
        if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', token):
            raise ContactError('invalid_link')
        return hashlib.sha256(token.encode()).hexdigest()

    def create_link(self, owner):
        token = secrets.token_urlsafe(32)
        now = int(time.time() * 1000)
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            count = db.execute('SELECT count(*) FROM contact_links WHERE owner=? AND created>?', (owner, now - 86400000)).fetchone()[0]
            if count >= 100: raise ContactError('link_limit')
            db.execute('INSERT INTO contact_links(id,owner,created) VALUES(?,?,?)', (self.link_id(token), owner, now))
        return token

    def inspect_link(self, user, token):
        with self.connect() as db:
            row = db.execute('SELECT * FROM contact_links WHERE id=?', (self.link_id(token),)).fetchone()
            if row is None: raise ContactError('invalid_link')
            if row['claimant'] not in (None, user): raise ContactError('link_used')
            existing = None if user == row['owner'] else db.execute('SELECT room_id FROM contacts WHERE pair=?', (self.pair(user, row['owner']),)).fetchone()
            return {'id': row['id'], 'owner': row['owner'], 'claimed': row['claimant'] == user,
                    'accepted': row['room_id'] is not None,
                    'room_id': row['room_id'] or (existing['room_id'] if existing else None),
                    'prepared': row['payload'] is not None, 'event_id': row['event_id']}

    def accept_link(self, user, token, room):
        identifier = self.link_id(token)
        if not isinstance(room, str) or not room.startswith('!') or len(room) > 255:
            raise ContactError('invalid_room')
        now = int(time.time() * 1000)
        with self.connect() as db:
            # Claim and mutual consent commit together, including across processes.
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT * FROM contact_links WHERE id=?', (identifier,)).fetchone()
            if row is None: raise ContactError('invalid_link')
            pair = self.pair(user, row['owner'])
            if row['claimant'] not in (None, user): raise ContactError('link_used')
            if row['room_id'] is None:
                existing = db.execute('SELECT * FROM contacts WHERE pair=?', (pair,)).fetchone()
                if existing:
                    db.execute("UPDATE contacts SET state='accepted',room_id=?,updated=? WHERE pair=?", (room, now, pair))
                else:
                    db.execute('INSERT INTO contacts VALUES(?,?,?,?,?,?,?,?)', (pair, uuid.uuid4().hex, user, row['owner'], room, 'accepted', now, now))
                db.execute('UPDATE contact_links SET claimant=?,room_id=? WHERE id=?', (user, room, identifier))
        return self.inspect_link(user, token)

    def claim_link(self, user, token):
        identifier = self.link_id(token)
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT owner,claimant FROM contact_links WHERE id=?', (identifier,)).fetchone()
            if row is None: raise ContactError('invalid_link')
            self.pair(user, row['owner'])
            if row['claimant'] not in (None, user): raise ContactError('link_used')
            db.execute('UPDATE contact_links SET claimant=? WHERE id=?', (user, identifier))
        return self.inspect_link(user, token)

    def greeting(self, user, identifier):
        if not isinstance(identifier, str) or not re.fullmatch(r'[a-f0-9]{64}', identifier):
            raise ContactError('invalid_link')
        with self.connect() as db:
            row = db.execute('SELECT * FROM contact_links WHERE id=? AND claimant=?', (identifier, user)).fetchone()
        if row is None or row['room_id'] is None: raise ContactError('forbidden')
        return {'id': hashlib.sha256(('contact-link:' + identifier).encode()).hexdigest(),
                'user_id': user, 'device_id': row['device_id'], 'room_id': row['room_id'],
                'payload': json.loads(row['payload']) if row['payload'] else None,
                'audience': row['audience'], 'event_id': row['event_id']}

    def prepare_greeting(self, user, identifier, device, payload, audience):
        self.greeting(user, identifier)
        with self.connect() as db:
            # First sealed envelope wins; retries from another device use that same sender.
            db.execute('UPDATE contact_links SET device_id=?,payload=?,audience=? WHERE id=? AND claimant=? AND payload IS NULL AND event_id IS NULL',
                       (device, json.dumps(payload), audience, identifier, user))
        return self.greeting(user, identifier)

    def finish_greeting(self, user, identifier, event):
        if not isinstance(event, str) or not event.startswith('$'):
            raise ContactError('publication_unconfirmed')
        with self.connect() as db:
            db.execute('UPDATE contact_links SET event_id=?,payload=NULL WHERE id=? AND claimant=?', (event, identifier, user))
