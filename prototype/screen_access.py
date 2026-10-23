"""Свежая проверка Matrix membership/device keys перед короткой SQL-фазой."""
import base64
from urllib.parse import quote
from screen_control import ScreenError


def verified_devices(matrix, who, room_id, wanted):
    """matrix — серверный клиент с токеном текущего actor, не данные браузера."""
    if not all(isinstance(who.get(k), str) and who[k] for k in ('user_id', 'device_id')):
        raise ScreenError('screen_access_denied')
    prefix = 'rooms/' + quote(room_id, safe='')
    members = matrix(prefix + '/joined_members')['joined']
    if who['user_id'] not in members:
        raise ScreenError('screen_access_denied')
    if matrix(prefix + '/state/m.room.encryption/').get('algorithm') != 'm.megolm.v1.aes-sha2':
        raise ScreenError('screen_access_denied')
    valid = {user + '/' + device: None for user, devices in wanted.items() for device in devices}
    wanted = {user: list(set(devices)) for user, devices in wanted.items() if user in members}
    wanted.setdefault(who['user_id'], []).append(who['device_id'])
    queried = matrix('keys/query', {'device_keys': wanted}).get('device_keys', {})
    valid.setdefault(who['user_id'] + '/' + who['device_id'], None)
    for user, devices in wanted.items():
        for device in devices:
            candidate = queried.get(user, {}).get(device, {})
            if candidate.get('user_id') != user or candidate.get('device_id') != device:
                continue
            values = candidate.get('keys', {})
            keys = tuple(values.get(kind + ':' + device) for kind in ('curve25519', 'ed25519'))
            try:
                if not all(isinstance(key, str) and len(key) == 43 and
                           len(base64.b64decode(key + '=', validate=True)) == 32 for key in keys):
                    continue
            except ValueError:
                continue
            valid[user + '/' + device] = keys
    return valid
