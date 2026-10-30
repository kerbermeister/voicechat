"""Synapse invitation policy; the control API owns the consent database."""
import logging
import hmac
import json
from collections.abc import Mapping
from synapse.module_api import NOT_SPAM
from synapse.api.errors import Codes
from synapse.api.errors import SynapseError
from synapse.api.errors import StoreError
from synapse.http.server import DirectServeJsonResource
from synapse.http.servlet import parse_string
from synapse.handlers.presence import format_user_presence_state
from synapse.types import UserID, create_requester
from synapse.util.async_helpers import Linearizer
from client_policy import expiry_content, read_after_duration
from scheduled_messages import ScheduleError, audience_digest, scheduled_audience, validate_envelope

KIND = 'dev.voicechat.kind'
PERSONAL = 'dev.voicechat.personal'

def personal_owner(state):
    creation = state.get(('m.room.create', ''))
    return creation.sender if creation and creation.content.get('type') == PERSONAL else None

class ContactPolicy:
    def __init__(self, config, api):
        self.api = api
        self.url = config['url']
        self.secret = config['secret']
        self.publish_locks = Linearizer(clock=api._hs.get_clock(), name='voicechat-scheduled')
        api.register_web_resource('/_synapse/client/voicechat-read-after', ReadAfter(self))
        api.register_web_resource('/_synapse/client/voicechat/presence', ContactPresence(self))
        api.register_web_resource('/_synapse/client/voicechat/scheduled-publish', ScheduledPublish(self))
        api.register_spam_checker_callbacks(user_may_invite=self.user_may_invite,
                                           user_may_send_state_event=self.user_may_send_state_event)
        api.register_third_party_rules_callbacks(check_event_allowed=self.check_event_allowed)
    @staticmethod
    def parse_config(config):
        if not isinstance(config.get('url'), str) or not isinstance(config.get('secret'), str) or len(config['secret']) < 32: raise ValueError('Contact policy endpoint and secret required')
        return config
    async def state(self, room):
        return await self.api.get_room_state(room, [(KIND,''),('m.room.create',''),('m.room.member',None)])
    async def check_event_allowed(self, event, state):
        content = event.content
        owner = personal_owner(state)
        if owner:
            creation = state[('m.room.create', '')]
            if event.type == 'm.room.redaction' and (getattr(event, 'redacts', None) or content.get('redacts')) == creation.event_id:
                return False, None
            if event.type == 'm.room.member' and (event.state_key != owner or event.sender != owner):
                return False, None
            if event.type.startswith('m.call.') or event.type.startswith('org.matrix.msc3401.call'):
                return False, None
        if 'dev.voicechat.read_after_seconds' in content:
            marker = state.get((KIND, ''))
            if not marker or not self.direct(marker.content) or event.is_state() or event.type != 'm.room.encrypted':
                return False, None
            pair = {marker.content['owner'], marker.content['peer']}
            members = {key for (kind, key), item in state.items() if kind == 'm.room.member' and item.content.get('membership') in ('join', 'invite')}
            if event.sender not in pair or not members <= pair:
                return False, None
            try:
                read_after_duration(content)
            except ValueError:
                return False, None
            relation = content.get('m.relates_to', {})
            if isinstance(relation, Mapping) and relation.get('rel_type') == 'm.replace':
                return False, None
            return True, None
        relation = content.get('m.relates_to', {})
        editing = isinstance(relation, Mapping) and relation.get('rel_type') == 'm.replace'
        temporary = 'dev.voicechat.ttl_seconds' in content or 'org.matrix.self_destruct_after' in content
        if not temporary and not editing:
            return True, None
        if event.is_state() or event.type != 'm.room.encrypted': return False, None
        try:
            original_deadline = None
            if editing:
                original = await self.api._hs.get_datastores().main.get_event(relation.get('event_id'), allow_none=True)
                if original is None or original.room_id != event.room_id or original.sender != event.sender:
                    return False, None
                if 'dev.voicechat.read_after_seconds' in original.content:
                    return False, None
                original_deadline = original.content.get('org.matrix.self_destruct_after')
                if not original.content: return False, None
                if original_deadline is None and not temporary: return True, None
                if not temporary:
                    content = {**content, 'dev.voicechat.ttl_seconds': original.content['dev.voicechat.ttl_seconds']}
            policy = await self.api.http_client.get_json(self.url.rsplit('/internal/', 1)[0] + '/config')
            updated = expiry_content(content, policy, self.api._hs.get_clock().time_msec(), original_deadline)
            replacement = event.get_dict()
            replacement['content'] = updated
            return True, replacement
        except Exception as error:
            logging.getLogger(__name__).warning('Temporary message validation failed: %s', type(error).__name__)
            return False, None
    @staticmethod
    def direct(content):
        return isinstance(content, Mapping) and content.get('kind') == 'direct' and isinstance(content.get('owner'),str) and isinstance(content.get('peer'),str) and content['owner'] != content['peer']
    async def user_may_invite(self, inviter, invitee, room_id):
        state = await self.state(room_id)
        if personal_owner(state): return Codes.FORBIDDEN
        marker = state.get((KIND,''))
        if marker and self.direct(marker.content):
            pair = {marker.content['owner'], marker.content['peer']}
            members = {key for (kind,key), event in state.items() if kind == 'm.room.member' and event.content.get('membership') in ('join','invite')}
            return NOT_SPAM if {inviter,invitee} == pair and members <= pair else Codes.FORBIDDEN
        try:
            response = await self.api.http_client.get_json(self.url,
                args={'inviter': inviter, 'invitee': invitee},
                headers={'Authorization': ['Bearer ' + self.secret]})
            return NOT_SPAM if response.get('accepted') is True else Codes.FORBIDDEN
        except Exception as error:
            logging.getLogger(__name__).warning('Contact authorization unavailable: %s', type(error).__name__)
            return Codes.FORBIDDEN
    async def user_may_send_state_event(self, user, room, event_type, state_key, content):
        if event_type not in (KIND, 'm.room.avatar', 'm.room.name'): return NOT_SPAM
        state = await self.state(room)
        marker = state.get((KIND,''))
        if marker and self.direct(marker.content): return Codes.FORBIDDEN
        if event_type == KIND:
            if state_key != '' or not self.direct(content) or content['owner'] != user: return Codes.FORBIDDEN
            pair = {content['owner'],content['peer']}
            members = {key for (kind,key), event in state.items() if kind == 'm.room.member' and event.content.get('membership') in ('join','invite')}
            if not members <= pair: return Codes.FORBIDDEN
        return NOT_SPAM

class ContactPresence(DirectServeJsonResource):
    isLeaf = True
    def __init__(self, policy):
        super().__init__()
        self.policy = policy
    async def _async_render_GET(self, request):
        if not hmac.compare_digest((request.getHeader('Authorization') or '').encode(), ('Bearer ' + self.policy.secret).encode()):
            raise SynapseError(403, 'Forbidden')
        target = UserID.from_string(parse_string(request, 'user_id', required=True, encoding='utf-8'))
        # Synapse's public presence API requires a shared joined room; accepted contacts can precede it.
        hs = self.policy.api._hs
        if not hs.is_mine(target): raise SynapseError(403, 'Local contacts only')
        state = await hs.get_presence_handler().get_state(target)
        return 200, format_user_presence_state(state, hs.get_clock().time_msec())


class ScheduledPublish(DirectServeJsonResource):
    isLeaf = True
    def __init__(self, policy):
        super().__init__()
        self.policy = policy

    async def _async_render_POST(self, request):
        if not hmac.compare_digest((request.getHeader('Authorization') or '').encode(), ('Bearer ' + self.policy.secret).encode()):
            raise SynapseError(403, 'Forbidden')
        try:
            raw = request.content.read(131073)
            if not 0 < len(raw) <= 131072: raise ScheduleError('invalid_size')
            job = json.loads(raw)
            if not isinstance(job, dict) or set(job) != {'id', 'user_id', 'device_id', 'room_id', 'payload', 'audience'}:
                raise ScheduleError('invalid_request')
            identifier, user, device, room = (job[key] for key in ('id', 'user_id', 'device_id', 'room_id'))
            if not all(isinstance(value, str) for value in (identifier, user, device, room)) or len(identifier) != 64:
                raise ScheduleError('invalid_request')
            hs = self.policy.api._hs
            if not hs.is_mine(UserID.from_string(user)): raise ScheduleError('local_sender_required', 403)
            store = hs.get_datastores().main
            # A retry after a lost HTTP/SQLite acknowledgement must not create a second event.
            async with self.policy.publish_locks.queue(identifier):
                transaction = 'scheduled-' + identifier
                existing = await store.get_event_id_from_transaction_id_and_device_id(room, user, device, transaction)
                if existing is not None: return 200, {'event_id': existing}
                account = await store.get_user_by_id(user)
                if account is None or account.is_deactivated: raise ScheduleError('account_unavailable', 403)
                try: await store.get_device(user, device)
                except StoreError as error:
                    if error.code == 404: raise ScheduleError('device_revoked', 403) from None
                    raise
                state = await self.policy.api.get_room_state(room, [(KIND, ''), ('m.room.member', None), ('m.room.encryption', '')])
                own = state.get(('m.room.member', user))
                if own is None or own.content.get('membership') != 'join': raise ScheduleError('not_joined', 403)
                encryption = state.get(('m.room.encryption', ''))
                if encryption is None or encryption.content.get('algorithm') != 'm.megolm.v1.aes-sha2':
                    raise ScheduleError('unencrypted_room', 403)
                members = scheduled_audience([event.get_dict() for event in state.values()])
                if state.get((KIND, '')) is not None:
                    peer = next(member for member in members if member != user)
                    consent = await self.policy.api.http_client.get_json(self.policy.url,
                        args={'inviter': user, 'invitee': peer}, headers={'Authorization': ['Bearer ' + self.policy.secret]})
                    if consent.get('accepted') is not True: raise ScheduleError('contact_not_accepted', 403)
                keys = await hs.get_e2e_keys_handler().query_devices({'device_keys': {member: [] for member in members}}, 10000, user, device)
                if keys.get('failures'): raise ScheduleError('keys_unavailable', 503)
                if device not in keys['device_keys'].get(user, {}): raise ScheduleError('device_revoked', 403)
                expected = audience_digest(members, keys['device_keys'])
                if job['audience'] != expected: raise ScheduleError('audience_changed', 409)
                curve = keys['device_keys'][user][device]['keys']['curve25519:' + device]
                policy = await self.policy.api.http_client.get_json(self.policy.url.rsplit('/internal/', 1)[0] + '/config')
                validate_envelope(job['payload'], device, curve, policy)
                event, _ = await hs.get_event_creation_handler().create_and_send_nonmember_event(
                    create_requester(user, device_id=device),
                    {'room_id': room, 'sender': user, 'type': 'm.room.encrypted', 'content': job['payload']},
                    txn_id=transaction)
                return 200, {'event_id': event.event_id}
        except ScheduleError as error: return error.status, {'error': str(error)}
        except (KeyError, ValueError, TypeError): return 400, {'error': 'invalid_request'}
        except SynapseError as error:
            return (503 if error.code == 429 or error.code >= 500 else error.code), {'error': 'matrix_unavailable' if error.code == 429 or error.code >= 500 else 'publication_denied'}
        except Exception as error:
            logging.getLogger(__name__).warning('Scheduled publication unavailable: %s', type(error).__name__)
            return 503, {'error': 'matrix_unavailable'}


class ReadAfter(DirectServeJsonResource):
    """Use the pinned Synapse event_expiry transaction and restart-safe scheduler.

    The API returns no plaintext and only operates inside an authenticated DM.
    Its public path deliberately stays outside the private /voicechat/* endpoints.
    """
    isLeaf = True
    def __init__(self, policy):
        super().__init__()
        self.policy = policy

    async def authorize(self, user, room):
        if not isinstance(room, str) or not room.startswith('!') or len(room) > 512:
            raise SynapseError(400, 'Invalid room')
        state = await self.policy.state(room)
        marker = state.get((KIND, ''))
        if not marker or not self.policy.direct(marker.content):
            raise SynapseError(403, 'Read-after is only available in direct chats')
        pair = {marker.content['owner'], marker.content['peer']}
        membership = state.get(('m.room.member', user))
        members = {key for (kind, key), item in state.items() if kind == 'm.room.member' and item.content.get('membership') in ('join', 'invite')}
        if user not in pair or not membership or membership.content.get('membership') != 'join' or not members <= pair:
            raise SynapseError(403, 'Not a direct-chat participant')

    async def event(self, room, event_id):
        if not isinstance(event_id, str) or not event_id.startswith('$') or len(event_id) > 255:
            raise SynapseError(400, 'Invalid event')
        item = await self.policy.api._hs.get_datastores().main.get_event(event_id, allow_none=True)
        if item is not None and item.room_id != room:
            raise SynapseError(403, 'Event is not in this room')
        return item

    async def start(self, user, room, event_id, read_at=None):
        await self.authorize(user, room)
        original = await self.event(room, event_id)
        if original is None or not original.content:
            raise SynapseError(410, 'Message unavailable')
        if original.sender == user:
            raise SynapseError(403, 'Only the recipient starts the countdown')
        try:
            delay = read_after_duration(original.content)
        except ValueError:
            raise SynapseError(400, 'Not a read-after message')
        handler = self.policy.api._hs.get_message_handler()
        if not handler._ephemeral_events_enabled:
            raise SynapseError(503, 'Message expiry is unavailable')
        now = self.policy.api._hs.get_clock().time_msec()
        if read_at is not None and type(read_at) is not int:
            raise SynapseError(400, 'Invalid read time')
        # Offline acknowledgement may shorten retention, but can never extend it.
        read_at = min(now, max(original.origin_server_ts, now if read_at is None else read_at))
        candidate = read_at + delay * 1000
        store = self.policy.api._hs.get_datastores().main
        def first_read(txn):
            # Re-check persisted content atomically: a concurrent expiry must not restart it.
            txn.execute('SELECT json FROM event_json WHERE event_id = ?', (event_id,))
            row = txn.fetchone()
            if row is None or 'dev.voicechat.read_after_seconds' not in json.loads(row[0]).get('content', {}):
                return None
            txn.execute('INSERT INTO event_expiry(event_id, expiry_ts) VALUES (?, ?) ON CONFLICT(event_id) DO NOTHING', (event_id, candidate))
            txn.execute('SELECT expiry_ts FROM event_expiry WHERE event_id = ?', (event_id,))
            return txn.fetchone()[0]
        deadline = await store.db_pool.runInteraction('voicechat_read_after', first_read)
        if deadline is None:
            raise SynapseError(410, 'Message unavailable')
        handler._schedule_expiry_for_event(event_id, deadline)
        return {'expires_at': deadline, 'server_time_ms': now}

    async def status(self, user, room, event_ids):
        await self.authorize(user, room)
        if not isinstance(event_ids, list) or len(event_ids) > 100:
            raise SynapseError(400, 'Invalid event list')
        store = self.policy.api._hs.get_datastores().main
        deadlines, unavailable = {}, []
        for event_id in dict.fromkeys(event_ids):
            original = await self.event(room, event_id)
            if original is None or not original.content:
                unavailable.append(event_id)
                continue
            if 'dev.voicechat.read_after_seconds' not in original.content:
                raise SynapseError(400, 'Not a read-after message')
            row = await store.db_pool.simple_select_one('event_expiry', {'event_id': event_id}, ['expiry_ts'], allow_none=True)
            if row is not None:
                deadlines[event_id] = row[0]
        return {'deadlines': deadlines, 'unavailable': unavailable, 'server_time_ms': self.policy.api._hs.get_clock().time_msec()}

    async def _async_render_POST(self, request):
        requester = await self.policy.api._hs.get_auth().get_user_by_req(request)
        user = requester.user.to_string()
        raw = request.content.read(32769)
        if not 0 < len(raw) <= 32768:
            raise SynapseError(400, 'Invalid request size')
        try:
            data = json.loads(raw)
            if not isinstance(data, dict):
                raise ValueError('Invalid object')
            if set(data) == {'room_id', 'event_ids'}:
                result = await self.status(user, data['room_id'], data['event_ids'])
            elif {'room_id', 'event_id'} <= data.keys() and not data.keys() - {'room_id', 'event_id', 'read_at'}:
                result = await self.start(user, data['room_id'], data['event_id'], data.get('read_at'))
            else:
                raise ValueError('Invalid fields')
        except (ValueError, TypeError):
            raise SynapseError(400, 'Invalid read-after request')
        return 200, result
