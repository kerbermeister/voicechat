"""Структурная граница screen protocol v1; права проверяются отдельным сценарием."""
import json
import re
from uuid import UUID


class ScreenRequestError(ValueError):
    def __init__(self):
        super().__init__('invalid_request')


def identifier(value, kind):
    if not isinstance(value, str):
        return False
    if kind == 'lease':
        return re.fullmatch(r'[a-f0-9]{64}', value) is not None
    if kind == 'generation':
        return re.fullmatch(r'screen-[a-f0-9]{48}', value) is not None
    if kind == 'uuid':
        try:
            return str(UUID(value)) == value
        except ValueError:
            return False
    return False


def validate_request(operation, body):
    """Возвращает проверенный JSON без доверия к присланной идентичности/правам."""
    fields = {
        'bind': {'protocol_version', 'room_id', 'call_session', 'transport'},
        'unbind': {'protocol_version', 'binding_id', 'lease_id', 'request_id'},
        'claim': {'protocol_version', 'lease_id', 'request_id', 'expected_revision'},
        'stop': {'protocol_version', 'lease_id', 'request_id', 'expected_revision'},
        'heartbeat': {'protocol_version', 'lease_id', 'observed_revision', 'capture_state'},
        'token': {'protocol_version', 'lease_id', 'expected_revision', 'generation'},
    }
    if operation not in fields or not isinstance(body, dict):
        raise ScreenRequestError()
    expected = fields[operation]
    if operation == 'bind':
        expected = expected | ({'call_lease_id'} if body.get('transport') == 'group' else {'peer'})
    if set(body) != expected or type(body['protocol_version']) is not int or body['protocol_version'] != 1:
        raise ScreenRequestError()
    for key, value in body.items():
        kind = {'lease_id': 'lease', 'call_lease_id': 'lease', 'binding_id': 'uuid',
                'request_id': 'uuid', 'generation': 'generation'}.get(key)
        if kind and not identifier(value, kind):
            raise ScreenRequestError()
        if key in ('expected_revision', 'observed_revision') and (
                type(value) is not int or not 0 <= value <= 9007199254740991):
            raise ScreenRequestError()
    if operation == 'bind':
        room, session = body['room_id'], body['call_session']
        if (not isinstance(room, str) or not room.startswith('!') or not 2 <= len(room) <= 255
                or not isinstance(session, str) or not re.fullmatch(r'[!-~]{1,128}', session)
                or body['transport'] not in ('direct', 'group')):
            raise ScreenRequestError()
        if body['transport'] == 'direct':
            peer = body['peer']
            if (not isinstance(peer, dict) or set(peer) != {'user_id', 'device_id'}
                    or not all(isinstance(v, str) and 1 <= len(v) <= 255 for v in peer.values())
                    or not peer['user_id'].startswith('@')):
                raise ScreenRequestError()
    if operation == 'heartbeat' and body['capture_state'] not in ('idle', 'preparing', 'sharing'):
        raise ScreenRequestError()
    return body


def parse_request(operation, raw):
    """Ограничивает UTF-8 JSON и отвергает повторные поля до предметной обработки."""
    if not isinstance(raw, bytes) or not 0 < len(raw) <= 8192:
        raise ScreenRequestError()

    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ScreenRequestError()
            result[key] = value
        return result

    try:
        body = json.loads(raw.decode('utf-8'), object_pairs_hook=unique)
        return validate_request(operation, body)
    except (ValueError, TypeError, RecursionError):
        raise ScreenRequestError() from None
