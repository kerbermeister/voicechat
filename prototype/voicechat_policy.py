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
from client_policy import expiry_content
from scheduled_messages import ScheduleError, audience_digest, scheduled_audience, validate_envelope

KIND = 'dev.voicechat.kind'

class ContactPolicy:
    def __init__(self, config, api):
        self.api = api
        self.url = config['url']
        self.secret = config['secret']
        self.publish_locks = Linearizer(clock=api._hs.get_clock(), name='voicechat-scheduled')
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
        return await self.api.get_room_state(room, [(KIND,''),('m.room.member',None)])
    async def check_event_allowed(self, event, state):
        content = event.content
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
