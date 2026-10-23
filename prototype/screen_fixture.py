#!/usr/bin/env python3
"""Одноразовые loopback fixtures SS-01; не использует аккаунты и ключи пользователей."""
import base64
import json
import secrets
import sys
import time
import urllib.request
from pathlib import Path
from token_server import jwt, media_api

root = Path(__file__).resolve().parents[1]
directory = root / '.prototype/screen-probe-web'


def main():
    if sys.argv[1:] not in ([], ['cleanup'], ['retire-screen'], ['refresh-sender']):
        raise SystemExit('Usage: screen_fixture.py [cleanup|retire-screen|refresh-sender]')
    fixture = directory / 'fixture.json'
    if sys.argv[1:] == ['refresh-sender']:
        data = json.loads(fixture.read_text())
        room = data['rooms'][0]
        token = jwt({'iss': 'prototype', 'nbf': int(time.time()) - 5,
                     'exp': int(time.time()) + 30, 'video': {'roomAdmin': True, 'room': room}})
        body = {'room': room, 'identity': 'sender',
            'permission': {'canSubscribe': False, 'canPublish': True,
                           'canPublishData': False, 'canPublishSources': ['SCREEN_SHARE']}}
        request = urllib.request.Request('http://127.0.0.1:7880/twirp/livekit.RoomService/UpdateParticipant',
            json.dumps(body).encode(), {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=5) as response:
            response.read()
        return
    if sys.argv[1:] == ['retire-screen']:
        data = json.loads(fixture.read_text())
        media_api('DeleteRoom', {'room': data['rooms'][0]})
        return
    if sys.argv[1:] == ['cleanup']:
        if fixture.exists():
            data = json.loads(fixture.read_text())
            for name in data['rooms']:
                media_api('DeleteRoom', {'room': name})
            fixture.unlink()
        return
    directory.mkdir(parents=True, exist_ok=True)
    if fixture.exists():
        for name in json.loads(fixture.read_text())['rooms']:
            media_api('DeleteRoom', {'room': name})
    now = int(time.time())
    data = {'key': base64.b64encode(secrets.token_bytes(32)).decode(), 'rooms': []}
    for channel in ('screen', 'camera'):
        name = 'ss01-' + secrets.token_hex(16)
        data['rooms'].append(name)
        media_api('CreateRoom', {'name': name, 'max_participants': 3})
        for role in ('sender', 'viewer', 'wrong'):
            grant = {'roomJoin': True, 'room': name, 'canSubscribe': True,
                     'canPublish': role == 'sender', 'canPublishData': False}
            if role == 'sender':
                grant['canPublishSources'] = (['screen_share'] if channel == 'screen'
                                              else ['camera', 'microphone'])
            data[channel + '_' + role] = jwt({'iss': 'prototype', 'sub': role,
                'nbf': now - 5, 'exp': now + 300, 'video': grant})
    fixture.write_text(json.dumps(data))
    fixture.chmod(0o600)
    (directory / 'source.html').write_text('''<!doctype html><title>VoiceChat Screen Source</title>
<body style="background:#5149c9;color:white;font:48px sans-serif">SS-01: экран вкладки
<p id="tick"></p><script>setInterval(()=>tick.textContent=Date.now(),100)</script></body>''')
    print('Disposable SS-01 rooms and fixture ready; no credentials printed')


if __name__ == '__main__':
    main()
