"""Synapse invitation policy; the control API owns the consent database."""
import logging
import hmac
from collections.abc import Mapping
from synapse.module_api import NOT_SPAM
from synapse.api.errors import Codes
from synapse.api.errors import SynapseError
from synapse.http.server import DirectServeJsonResource
from synapse.http.servlet import parse_string
from synapse.handlers.presence import format_user_presence_state
from synapse.types import UserID
from client_policy import expiry_content

KIND = 'dev.voicechat.kind'

class ContactPolicy:
    def __init__(self, config, api):
        self.api = api
        self.url = config['url']
        self.secret = config['secret']
        api.register_web_resource('/_synapse/client/voicechat/presence', ContactPresence(self))
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
