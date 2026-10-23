"""Перехват: durable намерение → SFU IO без SQL-транзакции → fenced commit."""
import hashlib
import json
import secrets
import threading
from screen_control import ScreenError


class ScreenTransitions:
    def __init__(self, store, media_api):
        self.store, self.media_api = store, media_api
        # Один control-процесс: сериализуем короткие SFU-переходы, не допуская
        # параллельной обработки одной операции. После crash намерение остаётся в БД.
        self.lock = threading.RLock()

    def command(self, action, who, binding_id, lease, valid, request_id, revision):
        if action not in ('claim', 'stop'):
            raise ScreenError('invalid_request', 400)
        with self.lock:
            self.store.authorize(who, binding_id, lease, valid)
            actor = who['user_id'] + '/' + who['device_id']
            fingerprint = hashlib.sha256(json.dumps({'action': action, 'revision': revision, 'lease_id': lease}, sort_keys=True).encode()).hexdigest()
            with self.store.db() as db:
                db.execute('BEGIN IMMEDIATE')
                current = db.execute('SELECT * FROM screen_sessions WHERE binding_id=?', (binding_id,)).fetchone()
                participant = db.execute('''SELECT 1 FROM screen_participants p JOIN screen_bindings b ON b.id=p.binding_id
                    WHERE b.id=? AND b.state='open' AND p.identity=? AND p.lease_id=? AND p.expires>?''',
                    (binding_id, actor, lease, self.store._now())).fetchone()
                if not participant:
                    raise ScreenError('screen_access_denied')
                receipt = db.execute('SELECT * FROM screen_commands WHERE binding_id=? AND actor_identity=? AND request_id=?',
                                     (binding_id, actor, request_id)).fetchone()
                if receipt and receipt['fingerprint'] != fingerprint:
                    raise ScreenError('idempotency_conflict', 409)
                if not receipt:
                    if current['state'] == 'switching':
                        raise ScreenError('screen_transition_in_progress', 409)
                    if current['revision'] != revision:
                        raise ScreenError('screen_revision_conflict', 409)
                    if action == 'stop' and current['owner_identity'] != actor:
                        raise ScreenError('screen_not_owner', 409)
                    operation = secrets.token_hex(32)
                    if current['generation']:
                        db.execute('INSERT OR IGNORE INTO screen_retired VALUES(?,?,?)',
                                   (current['generation'], binding_id, revision))
                    generation = 'screen-' + secrets.token_hex(24) if action == 'claim' else None
                    db.execute('''UPDATE screen_sessions SET revision=revision+1,state='switching',
                        owner_identity=?,owner_lease_id=?,generation=?,operation_id=?,deadline=? WHERE binding_id=?''',
                        (actor if action == 'claim' else None, lease if action == 'claim' else None,
                         generation, operation, self.store._now()+15000, binding_id))
                    db.execute('''INSERT INTO screen_commands(binding_id,actor_identity,request_id,operation,fingerprint,
                        expected_revision,status,created_at) VALUES(?,?,?,?,?,?,'pending',?)''',
                        (binding_id, actor, request_id, action, fingerprint, revision, self.store._now()))
            self._finish(binding_id)
            with self.store.db() as db:
                row = db.execute('SELECT * FROM screen_commands WHERE binding_id=? AND actor_identity=? AND request_id=?',
                                 (binding_id, actor, request_id)).fetchone()
                return {key: row[key] for key in ('request_id', 'status', 'result_revision', 'error_code')}

    def _cleanup(self, binding_id):
        with self.store.db() as db:
            retired = [row['generation'] for row in db.execute('SELECT generation FROM screen_retired WHERE binding_id=?', (binding_id,))]
        for generation in retired:
            self.media_api('DeleteRoom', {'room': generation})
            with self.store.db() as db:
                db.execute('DELETE FROM screen_retired WHERE generation=?', (generation,))

    def _finish(self, binding_id):
        with self.store.db() as db:
            session = db.execute('SELECT * FROM screen_sessions WHERE binding_id=?', (binding_id,)).fetchone()
        if session is None:
            return
        try:
            self._cleanup(binding_id)
            if session['state'] != 'switching':
                with self.store.db() as db:
                    db.execute("UPDATE screen_commands SET status='failed',error_code='screen_revision_conflict' WHERE binding_id=? AND status='pending'", (binding_id,))
                return
            expired = session['deadline'] <= self.store._now()
            generation = session['generation']
            if generation and not expired:
                self.media_api('CreateRoom', {'name': generation, 'max_participants': 10,
                                             'empty_timeout': 60, 'departure_timeout': 30})
            with self.store.db() as db:
                db.execute('BEGIN IMMEDIATE')
                current = db.execute('SELECT * FROM screen_sessions WHERE binding_id=?', (binding_id,)).fetchone()
                binding = db.execute('SELECT state FROM screen_bindings WHERE id=?', (binding_id,)).fetchone()
                lease = db.execute('SELECT 1 FROM screen_participants WHERE binding_id=? AND lease_id=? AND expires>?',
                                   (binding_id, session['owner_lease_id'], self.store._now())).fetchone()
                stale = current['operation_id'] != session['operation_id'] or binding['state'] != 'open'
                expired = expired or session['deadline'] <= self.store._now() or bool(generation and not lease)
                if generation and (stale or expired):
                    db.execute('INSERT OR IGNORE INTO screen_retired VALUES(?,?,?)', (generation, binding_id, session['revision']))
                if not stale:
                    db.execute('''UPDATE screen_sessions SET state=?,generation=?,owner_identity=?,owner_lease_id=?,
                        operation_id=NULL,deadline=NULL WHERE binding_id=? AND operation_id=?''',
                        ('active' if generation and not expired else 'idle', generation if not expired else None,
                         session['owner_identity'] if not expired else None,
                         session['owner_lease_id'] if not expired else None, binding_id, session['operation_id']))
                db.execute('''UPDATE screen_commands SET status=?,result_revision=?,error_code=?
                    WHERE binding_id=? AND status='pending' AND expected_revision=?''',
                    ('failed' if stale or expired else 'succeeded', current['revision'],
                     'screen_unavailable' if stale or expired else None, binding_id, session['revision']-1))
            self._cleanup(binding_id)
        except (OSError, TimeoutError):
            raise ScreenError('screen_unavailable', 503) from None

    def recover(self):
        """Повторяем durable IO; не выдаём токен и не восстанавливаем захват на клиенте."""
        with self.lock:
            with self.store.db() as db:
                bindings = [row[0] for row in db.execute('''SELECT binding_id FROM screen_sessions WHERE state='switching'
                    UNION SELECT binding_id FROM screen_retired''')]
            for binding in bindings:
                self._finish(binding)
