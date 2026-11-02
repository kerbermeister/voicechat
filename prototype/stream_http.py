"""Authenticated stream metadata transport. Media remains disabled until verified."""
import base64
import hashlib
import json
import time
import threading
from urllib.parse import quote
from stream_protocol import dispatch, parse_command
from stream_sessions import StreamError, StreamLimits, StreamSessions


def stream_limits(environment):
    value = environment.get('STREAM_MAX_DURATION_SECONDS', '10800')
    if not isinstance(value, str) or not value.isascii() or not value.isdigit() or int(value) <= 0:
        raise ValueError('STREAM_MAX_DURATION_SECONDS must be a positive integer')
    return StreamLimits(max_duration=int(value))


class StreamService:
    def __init__(self, path, contacts, pair_allowed, device_valid, media, *, enabled=False,
                 limits=None, clock=None, signer=None, media_enabled=False):
        self.enabled = enabled
        self.signer = signer
        self.media_enabled = media_enabled
        self.rosters = {}
        self.rooms = set()
        self.envelopes = {}
        self._pairs = {}
        self._devices = {}
        self.cache_clock = clock or time.monotonic
        self.contacts = contacts
        self.pair_allowed = pair_allowed
        self.device_valid = device_valid
        self.media = media
        self.lock = threading.RLock()
        self.core = StreamSessions(path, self.allowed, limits=limits,
                                   **({'clock': clock} if clock else {}))
        # Old generations must be retired before any request can create a session.
        self.tick()

    def cached(self, cache, key, load):
        now = self.cache_clock()
        current = cache.get(key)
        if current is not None and now < current[0]:
            return current[1]
        result = load()  # No stale-positive fallback on upstream failure.
        if len(cache) >= 4096:
            cache.clear()
        cache[key] = (now + 2, result)
        return result

    def allowed(self, owner, user):
        return self.contacts.accepted(owner, user) and self.cached(
            self._pairs, (owner, user), lambda: self.pair_allowed(owner, user))

    def valid_device(self, user, device):
        return self.cached(self._devices, (user, device), lambda: self.device_valid(user, device))

    def tick(self):
        with self.lock:
            participants = self.core.participants()
            for identifier, owner, viewers in participants:
                if not self.valid_device(*owner):
                    self.core.retire(identifier)
                    continue
                for user, device in viewers:
                    if not self.valid_device(user, device):
                        self.core.leave(identifier, (user, device))
            participants = self.core.participants()
            alive = {identifier for identifier, _, _ in participants}
            for identifier, owner, viewers in participants:
                current = frozenset(viewers)
                previous = self.rosters.get(identifier, frozenset())
                if current != previous:
                    self.core.rotate(identifier)
                    self.envelopes.pop(identifier, None)
                self.rosters[identifier] = current
            for identifier in set(self.rosters) - alive:
                self.rosters.pop(identifier, None)
                self.envelopes.pop(identifier, None)
            for generation in self.core.retired_generations():
                self.media('DeleteRoom', {'room': generation})
                self.rooms.discard(generation)
                self.core.acknowledge_cleanup(generation)
            if self.media_enabled:
                for identifier, owner, _ in self.core.participants():
                    state = self.core.media_state(identifier, owner)
                    if state['state'] != 'paused' and state['generation'] not in self.rooms:
                        self.media('CreateRoom', {'name': state['generation'], 'maxParticipants': 11})
                        self.rooms.add(state['generation'])

    @staticmethod
    def media_identity(identifier, actor):
        return hashlib.sha256(json.dumps([identifier, *actor], separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()

    def media_command(self, actor, command, matrix):
        identifier, operation = command['stream_id'], command['operation']
        state = self.core.media_state(identifier, actor)
        if operation == 'key_roster':
            if actor != state['owner']:
                raise StreamError('stream_owner_required', 403)
            viewers = next(viewers for sid, _, viewers in self.core.participants() if sid == identifier)
            wanted = {}
            for user, device in viewers:
                wanted.setdefault(user, []).append(device)
            return {'epoch': state['epoch'], 'devices': matrix('keys/query', {'device_keys': wanted}).get('device_keys', {})} if wanted else {'epoch': state['epoch'], 'devices': {}}
        if operation == 'key_get':
            envelope = self.envelopes.get(identifier, {}).get(actor)
            if envelope is None:
                raise StreamError('stream_key_pending', 409)
            if any(item is None for item in envelope):
                raise StreamError('stream_key_pending', 409)
            return {'epoch': state['epoch'], 'owner': state['owner'][0],
                    'owner_device': state['owner'][1], 'envelopes': envelope}
        epoch = command['epoch']
        if type(epoch) is not int or epoch != state['epoch']:
            raise StreamError('stream_revision_conflict', 409)
        if operation == 'key_put':
            if actor != state['owner']:
                raise StreamError('stream_owner_required', 403)
            target = (command['user'], command['device'])
            self.core._identity(target)
            self.core.media_state(identifier, target)
            part, parts = command['part'], command['parts']
            if type(part) is not int or type(parts) is not int or not 0 <= part < parts <= 128:
                raise StreamError('invalid_key_parts')
            envelope = command['envelope']
            if (not isinstance(envelope, dict) or len(json.dumps(envelope).encode()) > 24576
                    or envelope.get('algorithm') != 'm.olm.v1.curve25519-aes-sha2'
                    or not isinstance(envelope.get('sender_key'), str)
                    or not isinstance(envelope.get('ciphertext'), dict)):
                raise StreamError('invalid_key_envelope')
            # Keep parts in order so the recipient advances its Olm ratchet once.
            existing = self.envelopes.setdefault(identifier, {}).setdefault(target, [None] * parts)
            if len(existing) != parts or (existing[part] is not None and existing[part] != envelope):
                raise StreamError('stream_key_conflict', 409)
            existing[part] = envelope
            return {'stored': True}
        if not self.media_enabled or self.signer is None:
            raise StreamError('stream_media_unavailable', 503)
        owner = actor == state['owner']
        if owner and state['state'] == 'paused':
            raise StreamError('stream_paused', 409)
        if not owner and (actor not in self.envelopes.get(identifier, {}) or
                          any(v is None for v in self.envelopes[identifier][actor])):
            raise StreamError('stream_key_pending', 409)
        if state['generation'] not in self.rooms:
            raise StreamError('stream_media_unavailable', 503)
        now = int(self.core.clock())
        grant = {'roomJoin': True, 'room': state['generation'], 'canSubscribe': not owner,
                 'canPublish': owner, 'canPublishData': False}
        if owner:
            grant['canPublishSources'] = ['camera', 'microphone']
        token = self.signer({'iss': 'prototype', 'sub': self.media_identity(identifier, actor),
                             'nbf': now - 5, 'exp': min(now + 60, int(state['ends_at'])), 'video': grant})
        return {'token': token, 'generation': state['generation'], 'epoch': state['epoch'],
                'identity': self.media_identity(identifier, actor),
                'owner_identity': self.media_identity(identifier, state['owner'])}

    def authenticate(self, matrix):
        who = matrix('account/whoami')
        actor = (who.get('user_id'), who.get('device_id'))
        self.core._identity(actor)
        if not self.device_valid(*actor):
            raise StreamError('stream_device_required', 403)
        matrix('devices/' + quote(actor[1], safe=''))
        keys = matrix('keys/query', {'device_keys': {actor[0]: [actor[1]]}})
        candidate = keys.get('device_keys', {}).get(actor[0], {}).get(actor[1], {})
        if candidate.get('user_id') != actor[0] or candidate.get('device_id') != actor[1]:
            raise StreamError('stream_device_keys_required', 403)
        try:
            for kind in ('curve25519', 'ed25519'):
                value = candidate['keys'][kind + ':' + actor[1]]
                if not isinstance(value, str) or len(value) != 43 or len(base64.b64decode(value + '=', validate=True)) != 32:
                    raise ValueError()
        except (ValueError, KeyError, TypeError):
            raise StreamError('stream_device_keys_required', 403) from None
        return actor

    def handle(self, method, raw, matrix):
        with self.lock:
            actor = self.authenticate(matrix)
            if method == 'GET':
                return {'protocol_version': 1, 'enabled': self.enabled,
                        'media_enabled': self.media_enabled, 'max_duration': self.core.limits.max_duration,
                        'max_viewers': self.core.limits.viewers}
            if not self.enabled:
                raise StreamError('streams_disabled', 503)
            if method != 'POST':
                raise StreamError('method_not_allowed', 405)
            try:
                command = parse_command(raw, self.core.limits)
                self.tick()
                if command['operation'] in ('grant', 'key_get', 'key_put', 'key_roster'):
                    return self.media_command(actor, command, matrix)
                if self.media_enabled and command['operation'] == 'comment':
                    try:
                        header = json.loads(command['ciphertext'])
                        state = self.core.media_state(command['stream_id'], actor)
                        if not isinstance(header, dict) or type(header.get('epoch')) is not int or header['epoch'] != state['epoch']:
                            raise StreamError('stream_revision_conflict', 409)
                    except StreamError:
                        raise
                    except (ValueError, TypeError):
                        raise StreamError('invalid_message') from None
                rejoin = command['operation'] == 'join' and actor in self.rosters.get(command['stream_id'], frozenset())
                result = dispatch(self.core, actor, raw)
                if rejoin:
                    # A reloaded viewer may have consumed its previous Olm envelope
                    # but lost the stream-only RAM keys. Issue a fresh epoch.
                    self.core.rotate(command['stream_id'])
                    self.envelopes.pop(command['stream_id'], None)
                if command['operation'] == 'pause':
                    self.core.rotate(command['stream_id'], keys=False)
                if command['operation'] == 'start':
                    self.core.arm_owner(result['id'], actor)
                self.tick()
                if command['operation'] in ('start', 'join', 'pause', 'resume', 'heartbeat', 'info'):
                    result = self.core.info(result['id'], actor)
                return result
            finally:
                self.tick()
