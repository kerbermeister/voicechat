"""Synapse invitation policy; the control API owns the consent database."""
import logging
from collections.abc import Mapping
from synapse.module_api import NOT_SPAM
from synapse.api.errors import Codes

KIND = 'dev.voicechat.kind'

class ContactPolicy:
    def __init__(self, config, api):
        self.api = api
        self.url = config['url']
        self.secret = config['secret']
        api.register_spam_checker_callbacks(user_may_invite=self.user_may_invite,
                                           user_may_send_state_event=self.user_may_send_state_event)
    @staticmethod
    def parse_config(config):
        if not isinstance(config.get('url'), str) or not isinstance(config.get('secret'), str) or len(config['secret']) < 32: raise ValueError('Contact policy endpoint and secret required')
        return config
    async def state(self, room):
        return await self.api.get_room_state(room, [(KIND,''),('m.room.member',None)])
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
