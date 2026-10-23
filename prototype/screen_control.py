"""Метаданные экрана в существующей control SQLite. Сеть и медиаключи сюда не входят."""
from contextlib import contextmanager
from pathlib import Path
import sqlite3
import secrets
import time
from uuid import uuid4


class ScreenError(ValueError):
    def __init__(self, code, status=403):
        super().__init__(code)
        self.status = status


class ScreenStore:
    schema_version = 2

    def __init__(self, path, clock=time.time):
        self.path = Path(path)
        self.clock = clock
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.db() as db:
            version = 0
            if db.execute("SELECT 1 FROM sqlite_master WHERE name='screen_schema'").fetchone():
                row = db.execute('SELECT version FROM screen_schema WHERE singleton=1').fetchone()
                if row is None or row[0] not in (1, 2):
                    raise ValueError('unsupported_screen_schema')
                version = row[0]
            # Вся additive-миграция атомарна, включая отметку версии. При ошибке
            # откат не оставляет половину схемы и не затрагивает прежние call tables.
            if version == 0:
                db.executescript(Path(__file__).with_name('screen_schema.sql').read_text())
            if version < 2:
                db.executescript(Path(__file__).with_name('screen_schema_v2.sql').read_text())
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        try:
            with db:
                yield db
        finally:
            db.close()

    def _now(self):
        return int(self.clock() * 1000)

    def _invalidate(self, db, binding_id, terminal=False, retain_owner=False):
        session = db.execute('SELECT * FROM screen_sessions WHERE binding_id=?', (binding_id,)).fetchone()
        if session['generation']:
            db.execute('INSERT OR IGNORE INTO screen_retired VALUES(?,?,?)',
                       (session['generation'], binding_id, session['revision']))
        retain_owner = (retain_owner and not terminal and session['owner_identity'] is not None
                        and session['state'] in ('active','unavailable'))
        db.execute('''UPDATE screen_sessions SET revision=revision+1,roster_version=roster_version+1,
            state=?,owner_identity=?,owner_lease_id=?,generation=NULL,operation_id=NULL,deadline=NULL
            WHERE binding_id=?''', ('ended' if terminal else 'unavailable' if retain_owner else 'idle',
                                  session['owner_identity'] if retain_owner else None,
                                  session['owner_lease_id'] if retain_owner else None, binding_id))
        if terminal:
            db.execute("UPDATE screen_bindings SET state='ended',ended_at=? WHERE id=?", (self._now(), binding_id))

    def _prune(self, db, binding, valid):
        participants = db.execute('SELECT * FROM screen_participants WHERE binding_id=?', (binding['id'],)).fetchall()
        invalid = []
        for participant in participants:
            expired = participant['expires'] <= self._now()
            # Отсутствующий в снимке identity мог вступить, пока выполнялся Matrix IO.
            # Явный None означает проверенное отсутствие устройства/членства.
            keys_changed = (participant['identity'] in valid and
                            valid[participant['identity']] != (participant['curve'], participant['ed']))
            call_expired = False
            if binding['transport'] == 'group':
                call_expired = not db.execute('''SELECT 1 FROM leases l JOIN calls c ON c.id=l.call_id
                    WHERE l.id=? AND l.identity=? AND l.curve=? AND l.ed=? AND l.expires>?
                      AND c.room=? AND c.session=?''', (participant['call_lease_id'], participant['identity'],
                        participant['curve'], participant['ed'], self.clock(), binding['room_id'], binding['call_session'])).fetchone()
            if expired or keys_changed or call_expired:
                invalid.append(participant['identity'])
        if invalid:
            terminal = binding['transport'] == 'direct' or len(invalid) == len(participants)
            owner = db.execute('SELECT owner_identity FROM screen_sessions WHERE binding_id=?',(binding['id'],)).fetchone()[0]
            self._invalidate(db, binding['id'], terminal, retain_owner=owner not in invalid)
            db.executemany('DELETE FROM screen_participants WHERE binding_id=? AND identity=?',
                           [(binding['id'], identity) for identity in invalid])
            if terminal:
                db.execute('DELETE FROM screen_participants WHERE binding_id=?', (binding['id'],))

    def bind(self, who, request, valid):
        """valid — свежие ключи joined devices, полученные доверенным серверным адаптером."""
        identity = who['user_id'] + '/' + who['device_id']
        keys = valid.get(identity)
        if keys is None:
            raise ScreenError('screen_access_denied')
        peer = request.get('peer')
        peer_identity = peer['user_id'] + '/' + peer['device_id'] if peer else None
        if peer_identity and (valid.get(peer_identity) is None or peer['user_id'] == who['user_id']):
            raise ScreenError('screen_binding_mismatch', 409)
        error = None
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            binding = db.execute('SELECT * FROM screen_bindings WHERE room_id=? AND call_session=? AND transport=?',
                                 (request['room_id'], request['call_session'], request['transport'])).fetchone()
            if binding is None:
                binding_id = str(uuid4())
                db.execute('INSERT INTO screen_bindings VALUES(?,?,?,?,?,?,NULL)',
                           (binding_id, request['room_id'], request['call_session'], request['transport'], 'pending', self._now()))
                db.execute('INSERT INTO screen_sessions(binding_id) VALUES(?)', (binding_id,))
                binding = db.execute('SELECT * FROM screen_bindings WHERE id=?', (binding_id,)).fetchone()
            self._prune(db, binding, valid)
            binding = db.execute('SELECT * FROM screen_bindings WHERE id=?', (binding['id'],)).fetchone()
            if binding['state'] == 'ended':
                error = ScreenError('call_ended', 410)
            else:
                current = db.execute('SELECT * FROM screen_participants WHERE binding_id=? AND user_id=?',
                                     (binding['id'], who['user_id'])).fetchone()
                if current and (current['identity'] != identity or current['peer_identity'] != peer_identity):
                    error = ScreenError('screen_binding_mismatch', 409)
                elif request['transport'] == 'group' and not db.execute('''SELECT 1 FROM leases l JOIN calls c ON c.id=l.call_id
                    WHERE l.id=? AND l.identity=? AND l.curve=? AND l.ed=? AND l.expires>?
                    AND c.room=? AND c.session=?''', (request['call_lease_id'], identity, *keys, self.clock(),
                                                    request['room_id'], request['call_session'])).fetchone():
                    error = ScreenError('lease_expired', 410)
                else:
                    participants = db.execute('SELECT * FROM screen_participants WHERE binding_id=?', (binding['id'],)).fetchall()
                    if peer_identity and any(p['identity'] != identity and
                            (p['identity'] != peer_identity or p['peer_identity'] != identity) for p in participants):
                        error = ScreenError('screen_binding_mismatch', 409)
                    elif not current and len(participants) >= (2 if peer else 10):
                        error = ScreenError('screen_access_denied')
                    else:
                        lease = current['lease_id'] if current else secrets.token_hex(32)
                        if not current:
                            db.execute('''INSERT INTO screen_participants
                                (binding_id,identity,user_id,device_id,curve,ed,lease_id,call_lease_id,confirmed,expires,peer_identity)
                                VALUES(?,?,?,?,?,?,?,?,0,?,?)''', (binding['id'], identity, who['user_id'], who['device_id'],
                                    *keys, lease, request.get('call_lease_id'), self._now()+30000, peer_identity))
                            self._invalidate(db, binding['id'], retain_owner=True)
                        else:
                            db.execute('UPDATE screen_participants SET expires=?,call_lease_id=? WHERE lease_id=?',
                                       (self._now()+30000, request.get('call_lease_id'), lease))
                        count = db.execute('SELECT COUNT(*) FROM screen_participants WHERE binding_id=?', (binding['id'],)).fetchone()[0]
                        if not peer or count == 2:
                            db.execute("UPDATE screen_bindings SET state='open' WHERE id=?", (binding['id'],))
                            db.execute('UPDATE screen_participants SET confirmed=1 WHERE binding_id=?', (binding['id'],))
                        result = {'binding_id': binding['id'], 'lease_id': lease}
        if error:
            raise error
        return result

    def authorize(self, who, binding_id, lease, valid, renew=False):
        """Не возвращает секретные leases остальных устройств; отзыв коммитится и при отказе."""
        identity = who['user_id'] + '/' + who['device_id']
        result = None
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            binding = db.execute('SELECT * FROM screen_bindings WHERE id=?', (binding_id,)).fetchone()
            if binding:
                self._prune(db, binding, valid)
                result = db.execute('''SELECT p.* FROM screen_participants p JOIN screen_bindings b ON b.id=p.binding_id
                    WHERE b.id=? AND b.state='open' AND p.confirmed=1 AND p.identity=? AND p.lease_id=?''',
                    (binding_id, identity, lease)).fetchone()
                if result is not None and renew:
                    db.execute('UPDATE screen_participants SET expires=? WHERE lease_id=?', (self._now()+30000, lease))
        if result is None:
            raise ScreenError('screen_access_denied')
        return dict(result)

    def participants(self, binding_id):
        """Служебная выборка для свежего Matrix-запроса; не публичный HTTP snapshot."""
        with self.db() as db:
            return [dict(row) for row in db.execute('SELECT * FROM screen_participants WHERE binding_id=?', (binding_id,))]

    def recover(self):
        """При старте процесса старые допуска и screen rooms только отзываются."""
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            for binding in db.execute("SELECT id FROM screen_bindings WHERE state!='ended'").fetchall():
                self._invalidate(db,binding['id'],terminal=True)
            db.execute('DELETE FROM screen_participants')

    def leave(self, who, binding_id, lease):
        identity = who['user_id'] + '/' + who['device_id']
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            participant = db.execute('SELECT * FROM screen_participants WHERE binding_id=? AND lease_id=?',
                                     (binding_id, lease)).fetchone()
            if participant is None:
                return
            if participant['identity'] != identity:
                raise ScreenError('screen_access_denied')
            binding = db.execute('SELECT * FROM screen_bindings WHERE id=?', (binding_id,)).fetchone()
            count = db.execute('SELECT COUNT(*) FROM screen_participants WHERE binding_id=?', (binding_id,)).fetchone()[0]
            owner = db.execute('SELECT owner_identity FROM screen_sessions WHERE binding_id=?',(binding_id,)).fetchone()[0]
            self._invalidate(db, binding_id, binding['transport'] == 'direct' or count == 1,
                             retain_owner=owner != identity)
            db.execute('DELETE FROM screen_participants WHERE binding_id=? AND (identity=? OR ?)',
                       (binding_id, identity, binding['transport'] == 'direct'))
