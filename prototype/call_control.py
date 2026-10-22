"""Persistent SFU leases and media generations. Never stores Matrix tokens or media keys."""
from contextlib import contextmanager
from pathlib import Path
import secrets
import sqlite3
import threading
import time


class CallError(ValueError):
    def __init__(self, code, status=403):
        super().__init__(code)
        self.status = status


class CallStore:
    lease_seconds = 30
    limit = 10

    def __init__(self, path, media_api, clock=time.time):
        self.path, self.media_api, self.clock = Path(path), media_api, clock
        self.lock = threading.RLock()
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.db() as db:
            db.executescript('''
              CREATE TABLE IF NOT EXISTS calls(
                id INTEGER PRIMARY KEY, room TEXT NOT NULL, session TEXT NOT NULL,
                video INTEGER NOT NULL, generation TEXT NOT NULL, ready_at REAL NOT NULL,
                UNIQUE(room, session));
              CREATE TABLE IF NOT EXISTS leases(
                id TEXT PRIMARY KEY, call_id INTEGER NOT NULL, user_id TEXT NOT NULL UNIQUE,
                identity TEXT NOT NULL UNIQUE, curve TEXT NOT NULL, ed TEXT NOT NULL,
                expires REAL NOT NULL);
              CREATE TABLE IF NOT EXISTS retired(name TEXT PRIMARY KEY);
            ''')
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            with db: yield db
        finally:
            db.close()

    def _rotate(self, db, call):
        db.execute('INSERT OR IGNORE INTO retired VALUES(?)', (call['generation'],))
        db.execute('UPDATE calls SET generation=?,ready_at=? WHERE id=?',
                   ('vc-' + secrets.token_hex(24), self.clock() + .6, call['id']))

    def _cleanup(self):
        # Retire durably before touching the SFU; retry deletion after any crash/failure.
        with self.db() as db:
            old = [r['name'] for r in db.execute('SELECT name FROM retired')]
        for name in old:
            self.media_api('DeleteRoom', {'room': name})
            with self.db() as db: db.execute('DELETE FROM retired WHERE name=?', (name,))

    def recover(self):
        with self.lock:
            with self.db() as db:
                db.execute('BEGIN IMMEDIATE')
                for call in db.execute('SELECT * FROM calls').fetchall(): self._rotate(db, call)
                db.execute('DELETE FROM leases')
            self._cleanup()

    def sweep(self):
        with self.lock:
            with self.db() as db:
                db.execute('BEGIN IMMEDIATE')
                expired = db.execute('SELECT DISTINCT call_id FROM leases WHERE expires<=?', (self.clock(),)).fetchall()
                db.execute('DELETE FROM leases WHERE expires<=?', (self.clock(),))
                for row in expired:
                    call = db.execute('SELECT * FROM calls WHERE id=?', (row['call_id'],)).fetchone()
                    self._rotate(db, call)
            self._cleanup()

    def roster(self, room, session):
        with self.db() as db:
            return [dict(row) for row in db.execute('SELECT l.* FROM leases l JOIN calls c ON c.id=l.call_id WHERE c.room=? AND c.session=?', (room, session))]

    def admission(self, room, session, video, who, curve, ed, lease=None, reconnect=None, valid=None, checked=None):
        identity = who['user_id'] + '/' + who['device_id']
        with self.lock:
            self.sweep()
            with self.db() as db:
                db.execute('BEGIN IMMEDIATE')
                call = db.execute('SELECT * FROM calls WHERE room=? AND session=?', (room, session)).fetchone()
                if call is None:
                    if lease: raise CallError('lease_expired', 410)
                    db.execute('INSERT INTO calls(room,session,video,generation,ready_at) VALUES(?,?,?,?,?)',
                               (room, session, int(video), 'vc-' + secrets.token_hex(24), self.clock() + .6))
                    call = db.execute('SELECT * FROM calls WHERE room=? AND session=?', (room, session)).fetchone()
                if bool(call['video']) != video: raise CallError('call_mode_changed', 409)
                if valid is not None:
                    invalid = [row['id'] for row in db.execute('SELECT * FROM leases WHERE call_id=?', (call['id'],))
                               if (checked is None or row['id'] in checked) and valid.get(row['identity']) != (row['curve'], row['ed'])]
                    if invalid:
                        db.executemany('DELETE FROM leases WHERE id=?', [(key,) for key in invalid])
                        self._rotate(db, call)
                current = db.execute('SELECT * FROM leases WHERE user_id=?', (who['user_id'],)).fetchone()
                if lease:
                    if current is None or current['id'] != lease or current['identity'] != identity or current['call_id'] != call['id']:
                        raise CallError('lease_expired', 410)
                    if current['curve'] != curve or current['ed'] != ed:
                        raise CallError('device_key_changed')
                    if reconnect == call['generation']: self._rotate(db, call)
                    db.execute('UPDATE leases SET expires=? WHERE id=?', (self.clock() + self.lease_seconds, lease))
                else:
                    if current:
                        if current['identity'] != identity or current['call_id'] != call['id']:
                            raise CallError('answered_elsewhere', 409)
                        lease = current['id']
                        if current['curve'] != curve or current['ed'] != ed: raise CallError('device_key_changed')
                        db.execute('UPDATE leases SET expires=? WHERE id=?', (self.clock() + self.lease_seconds, lease))
                    else:
                        if db.execute('SELECT COUNT(*) FROM leases WHERE call_id=?', (call['id'],)).fetchone()[0] >= self.limit:
                            raise CallError('call_full', 409)
                        lease = secrets.token_hex(32)
                        db.execute('INSERT INTO leases VALUES(?,?,?,?,?,?,?)',
                                   (lease, call['id'], who['user_id'], identity, curve, ed, self.clock() + self.lease_seconds))
                        self._rotate(db, call)
            self._cleanup()
            with self.db() as db:
                call = db.execute('SELECT * FROM calls WHERE id=?', (call['id'],)).fetchone()
                roster = [dict(row) for row in db.execute('SELECT identity,curve,ed FROM leases WHERE call_id=? ORDER BY identity', (call['id'],))]
            # A short settling window coalesces simultaneous joins into one transport rebuild.
            if self.clock() < call['ready_at']: raise CallError('generation_settling', 409)
            self.media_api('CreateRoom', {'name': call['generation'], 'max_participants': self.limit,
                                         'empty_timeout': 60, 'departure_timeout': 30})
            return {'lease_id': lease, 'generation': call['generation'], 'roster': roster,
                    'lease_seconds': self.lease_seconds, 'identity': identity}

    def leave(self, who, lease):
        with self.lock:
            with self.db() as db:
                db.execute('BEGIN IMMEDIATE')
                row = db.execute('SELECT * FROM leases WHERE id=?', (lease,)).fetchone()
                if row is None: return
                if row['identity'] != who['user_id'] + '/' + who['device_id']: raise CallError('forbidden')
                call = db.execute('SELECT * FROM calls WHERE id=?', (row['call_id'],)).fetchone()
                db.execute('DELETE FROM leases WHERE id=?', (lease,))
                self._rotate(db, call)
            self._cleanup()
