"""Local stream lifecycle core. No media, plaintext chat or account keys on disk.

The caller must supply freshly authenticated user/device identities and a current
friend/block decision. This core does not issue media grants: API/SFU integration
must enforce the same state and lease checks before it can be enabled.
"""
from dataclasses import dataclass, field
from pathlib import Path
import math
import hashlib
import secrets
import sqlite3
import threading
import time


class StreamError(ValueError):
    def __init__(self, code, status=400):
        super().__init__(code)
        self.status = status


@dataclass(frozen=True)
class StreamLimits:
    max_duration: int = 10800
    viewers: int = 10
    reconnect: int = 60
    lease: int = 60
    message_bytes: int = 8192
    message_interval: int = 1
    streams: int = 8

    def __post_init__(self):
        if any(type(value) is not int or value <= 0 for value in vars(self).values()):
            raise ValueError('stream limits must be positive integers')


@dataclass
class Session:
    id: str
    owner: tuple
    title: str
    description: str
    audience: frozenset | None
    comments: bool
    started_at: float
    ends_at: float
    generation: str
    request_id: str = ''
    settings_hash: str = ''
    key_epoch: int = 1
    state: str = 'live'
    revision: int = 1
    disconnected_at: float | None = None
    owner_seen: float | None = None
    viewers: dict = field(default_factory=dict)
    messages: list = field(default_factory=list)
    message_ids: dict = field(default_factory=dict)
    last_sent: dict = field(default_factory=dict)


class StreamSessions:
    def __init__(self, path, allowed, limits=None, clock=time.time):
        self.limits = limits or StreamLimits()
        self.allowed = allowed
        self.clock = clock
        self.lock = threading.RLock()
        self.sessions = {}
        self.ended_attempts = {}
        # Only opaque generations survive restart, so the SFU adapter can retire
        # them before enabling streams. Content and chat never enter this table.
        self.db = sqlite3.connect(path, check_same_thread=False)
        try:
            with self.db:
                self.db.execute('BEGIN IMMEDIATE')
                if self.db.execute("SELECT 1 FROM sqlite_master WHERE name='stream_schema'").fetchone():
                    version = self.db.execute('SELECT version FROM stream_schema WHERE singleton=1').fetchone()
                    if version != (1,):
                        raise ValueError('unsupported_stream_schema')
                self.db.execute('CREATE TABLE IF NOT EXISTS stream_cleanup (generation TEXT PRIMARY KEY)')
                columns = self.db.execute('PRAGMA table_info(stream_cleanup)').fetchall()
                if len(columns) != 1 or columns[0][1:3] != ('generation', 'TEXT') or columns[0][5] != 1:
                    raise ValueError('invalid_stream_cleanup_schema')
                self.db.execute('CREATE TABLE IF NOT EXISTS stream_schema (singleton INTEGER PRIMARY KEY CHECK(singleton=1), version INTEGER NOT NULL)')
                self.db.execute('INSERT OR IGNORE INTO stream_schema VALUES(1,1)')
            if Path(path).is_file():
                Path(path).chmod(0o600)
        except Exception:
            self.db.close()
            raise

    def close(self):
        with self.lock:
            self.sessions.clear()
            self.ended_attempts.clear()
            self.db.close()

    def pending_cleanup(self):
        with self.lock:
            return [row[0] for row in self.db.execute('SELECT generation FROM stream_cleanup')]

    def acknowledge_cleanup(self, generation):
        """Call only after the SFU adapter has confirmed room deletion/revocation."""
        with self.lock, self.db:
            if any(s.generation == generation for s in self.sessions.values()):
                raise StreamError('stream_still_active', 409)
            self.db.execute('DELETE FROM stream_cleanup WHERE generation=?', (generation,))

    @staticmethod
    def _identity(actor):
        if (not isinstance(actor, tuple) or len(actor) != 2
                or any(not isinstance(v, str) or not v or len(v) > 255 or not v.isprintable() for v in actor)):
            raise StreamError('invalid_identity')
        return actor

    def _finish(self, session):
        self.sessions.pop(session.id, None)
        if session.request_id:
            self.ended_attempts[(session.owner, session.request_id)] = session.ends_at + self.limits.reconnect
        session.state = 'ended'
        session.viewers.clear()
        session.messages.clear()
        session.message_ids.clear()
        session.last_sent.clear()
        session.title = session.description = ''
        session.audience = frozenset()
        # The cleanup row is retained until real SFU removal is confirmed.

    def _tick(self):
        now = self.clock()
        self.ended_attempts = {key: expires for key, expires in self.ended_attempts.items() if expires > now}
        for session in list(self.sessions.values()):
            if session.owner_seen is not None and session.state == 'live' and now - session.owner_seen >= 15:
                session.state = 'reconnecting'
                session.disconnected_at = session.owner_seen
                session.revision += 1
            if (now >= session.ends_at or
                    (session.state == 'reconnecting' and
                     now - session.disconnected_at >= self.limits.reconnect)):
                self._finish(session)
                continue
            for user, (device, expires) in list(session.viewers.items()):
                if expires <= now or not self.allowed(session.owner[0], user):
                    del session.viewers[user]

    def tick(self):
        with self.lock:
            self._tick()

    def _get(self, identifier, actor):
        self._identity(actor)
        if not isinstance(identifier, str) or not 1 <= len(identifier) <= 128:
            raise StreamError('stream_unavailable', 404)
        self._tick()
        session = self.sessions.get(identifier)
        if session is None or (actor != session.owner and
                (not self.allowed(session.owner[0], actor[0]) or
                 (session.audience is not None and actor[0] not in session.audience))):
            raise StreamError('stream_unavailable', 404)
        return session

    def start(self, actor, *, title, description='', audience=None, comments=True, duration=None, request_id=None):
        self._identity(actor)
        if request_id is not None and (not isinstance(request_id, str) or not 1 <= len(request_id) <= 128):
            raise StreamError('invalid_request_id')
        if (not isinstance(title, str) or not title.strip() or len(title) > 120
                or not isinstance(description, str) or len(description) > 2000
                or type(comments) is not bool):
            raise StreamError('invalid_settings')
        try:
            title.encode('utf-8')
            description.encode('utf-8')
        except UnicodeError:
            raise StreamError('invalid_settings') from None
        if duration is None:
            duration = self.limits.max_duration
        if type(duration) is not int or not 0 < duration <= self.limits.max_duration:
            raise StreamError('invalid_duration')
        if audience is not None:
            if (not isinstance(audience, (list, tuple)) or not audience or len(audience) > 1000
                    or any(not isinstance(u, str) or not u or len(u) > 255 for u in audience)):
                raise StreamError('invalid_audience')
            audience = frozenset(audience)
            if any(u == actor[0] or not self.allowed(actor[0], u) for u in audience):
                raise StreamError('invalid_audience')
        with self.lock:
            self._tick()
            if (actor, request_id) in self.ended_attempts:
                raise StreamError('stream_unavailable', 404)
            if len(self.ended_attempts) >= self.limits.streams * math.ceil(self.limits.max_duration / self.limits.reconnect):
                raise StreamError('stream_capacity', 503)
            settings_hash = hashlib.sha256(repr((title.strip(), description,
                sorted(audience) if audience is not None else None, comments, duration)).encode()).hexdigest()
            for existing in self.sessions.values():
                if existing.owner[0] == actor[0]:
                    if request_id is not None and existing.owner == actor and existing.request_id == request_id:
                        if existing.settings_hash != settings_hash:
                            raise StreamError('stream_request_conflict', 409)
                        return self.info(existing.id, actor)
                    raise StreamError('stream_already_active', 409)
            if len(self.sessions) >= self.limits.streams:
                raise StreamError('stream_capacity', 503)
            now = self.clock()
            identifier, generation = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
            with self.db:
                self.db.execute('INSERT INTO stream_cleanup VALUES(?)', (generation,))
            self.sessions[identifier] = Session(identifier, actor, title.strip(), description,
                audience, comments, now, now + duration, generation, request_id or '', settings_hash)
            return self.info(identifier, actor)

    def arm_owner(self, identifier, actor):
        with self.lock:
            s = self._get(identifier, actor)
            if actor != s.owner:
                raise StreamError('stream_owner_required', 403)
            if s.owner_seen is None:
                s.owner_seen = self.clock()

    def heartbeat(self, identifier, actor, ready):
        if type(ready) is not bool:
            raise StreamError('invalid_capture_state')
        with self.lock:
            s = self._get(identifier, actor)
            if actor != s.owner:
                return self.join(identifier, actor)
            s.owner_seen = self.clock()
            if s.state == 'live' and not ready:
                return self.transition(identifier, actor, 'disconnect', s.revision)
            if s.state == 'reconnecting' and ready:
                return self.transition(identifier, actor, 'recover', s.revision)
            return self.info(identifier, actor)

    def retire(self, identifier):
        """Trusted device-revocation/startup path, never a client operation."""
        with self.lock:
            s = self.sessions.get(identifier)
            if s is not None:
                self._finish(s)

    def participants(self):
        """Trusted adapter snapshot, not a viewer-facing roster."""
        with self.lock:
            self._tick()
            return [(s.id, s.owner, [(user, device) for user, (device, _) in s.viewers.items()])
                    for s in self.sessions.values()]

    def rotate(self, identifier, *, keys=True):
        with self.lock:
            s = self.sessions.get(identifier)
            if s is None:
                return
            generation = secrets.token_urlsafe(24)
            with self.db:
                self.db.execute('INSERT INTO stream_cleanup VALUES(?)', (generation,))
            s.generation = generation
            s.key_epoch += int(keys)
            s.revision += 1

    def media_state(self, identifier, actor):
        with self.lock:
            s = self._get(identifier, actor)
            self._member(s, actor)
            return dict(generation=s.generation, epoch=s.key_epoch, owner=s.owner,
                        state=s.state, ends_at=s.ends_at)

    def retired_generations(self):
        with self.lock:
            active = {s.generation for s in self.sessions.values()}
            return [g for g in self.pending_cleanup() if g not in active]

    def info(self, identifier, actor):
        with self.lock:
            s = self._get(identifier, actor)
            result = dict(id=s.id, title=s.title, description=s.description, state=s.state,
                revision=s.revision, started_at=s.started_at, ends_at=s.ends_at,
                server_now=self.clock(), comments=s.comments, viewers=len(s.viewers), owner=s.owner[0], owner_device=s.owner[1],
                generation=s.generation, key_epoch=s.key_epoch)
            if actor == s.owner:
                result['viewer_users'] = list(s.viewers)
            return result

    def discover(self, actor):
        self._identity(actor)
        with self.lock:
            self._tick()
            result = []
            for identifier in list(self.sessions):
                try:
                    result.append(self.info(identifier, actor))
                except StreamError as error:
                    if error.status != 404:
                        raise
            return result

    def join(self, identifier, actor):
        with self.lock:
            s = self._get(identifier, actor)
            if actor[0] == s.owner[0]:
                raise StreamError('owner_cannot_watch', 409)
            existing = s.viewers.get(actor[0])
            if existing and existing[0] != actor[1]:
                raise StreamError('stream_on_other_device', 409)
            if not existing and len(s.viewers) >= self.limits.viewers:
                raise StreamError('stream_full', 409)
            s.viewers[actor[0]] = (actor[1], min(s.ends_at, self.clock() + self.limits.lease))
            return self.info(identifier, actor)

    def leave(self, identifier, actor):
        with self.lock:
            s = self._get(identifier, actor)
            if s.viewers.get(actor[0], (None,))[0] == actor[1]:
                del s.viewers[actor[0]]

    def _member(self, s, actor):
        if actor != s.owner and s.viewers.get(actor[0], (None,))[0] != actor[1]:
            raise StreamError('stream_join_required', 403)

    def transition(self, identifier, actor, action, revision):
        with self.lock:
            s = self._get(identifier, actor)
            if actor != s.owner:
                raise StreamError('stream_owner_required', 403)
            if type(revision) is not int or revision != s.revision:
                raise StreamError('stream_revision_conflict', 409)
            if action == 'stop':
                self._finish(s)
                return {'state': 'ended'}
            transitions = {('live', 'pause'): 'paused', ('reconnecting', 'pause'): 'paused',
                ('live', 'disconnect'): 'reconnecting', ('reconnecting', 'recover'): 'live',
                ('paused', 'resume'): 'live'}
            state = transitions.get((s.state, action))
            if state is None:
                raise StreamError('invalid_transition', 409)
            s.state = state
            if state == 'live' and s.owner_seen is not None:
                s.owner_seen = self.clock()
            s.revision += 1
            s.disconnected_at = self.clock() if state == 'reconnecting' else None
            return self.info(identifier, actor)

    def history(self, identifier, actor, *, after=0, head=None, limit=100):
        with self.lock:
            s = self._get(identifier, actor)
            self._member(s, actor)
            if (type(after) is not int or after < 0 or type(limit) is not int or not 1 <= limit <= 100
                    or (head is not None and (type(head) is not int or head < after))):
                raise StreamError('invalid_cursor')
            head = len(s.messages) if head is None else min(head, len(s.messages))
            return {'head': head, 'messages': [dict(m) for m in s.messages[after:head][:limit]]}

    def send(self, identifier, actor, message_id, ciphertext):
        with self.lock:
            s = self._get(identifier, actor)
            self._member(s, actor)
            if not s.comments:
                raise StreamError('comments_disabled', 403)
            if (not isinstance(message_id, str) or not 1 <= len(message_id) <= 128
                    or not isinstance(ciphertext, bytes) or not 1 <= len(ciphertext) <= self.limits.message_bytes):
                raise StreamError('invalid_message')
            key = (actor[0], message_id)
            previous = s.message_ids.get(key)
            if previous:
                if previous['ciphertext'] != ciphertext or previous['device'] != actor[1]:
                    raise StreamError('message_id_conflict', 409)
                return previous['sequence']
            now = self.clock()
            # Global budget survives viewer churn. A fixed stream lifetime and
            # per-stream cadence bound total accepted envelopes without eviction.
            if s.last_sent and now - s.last_sent['stream'] < self.limits.message_interval:
                raise StreamError('comment_rate_limited', 429)
            maximum = math.ceil(self.limits.max_duration / self.limits.message_interval)
            if len(s.messages) >= maximum:
                raise StreamError('comment_capacity', 429)
            message = dict(sequence=len(s.messages) + 1, author=actor[0], device=actor[1],
                           id=message_id, timestamp=now, ciphertext=ciphertext)
            s.messages.append(message)
            s.message_ids[key] = message
            s.last_sent['stream'] = now
            return message['sequence']
