#!/usr/bin/env python3
"""Local pinned-SFU lifecycle probe. Does not publish media or use user accounts."""
import json
import tempfile
import time
import urllib.request
from pathlib import Path
from stream_sessions import StreamSessions
from token_server import jwt, media_api


def rooms():
    now = int(time.time())
    token = jwt({'iss': 'prototype', 'nbf': now - 5, 'exp': now + 30,
                 'video': {'roomList': True}})
    req = urllib.request.Request('http://127.0.0.1:7880/twirp/livekit.RoomService/ListRooms',
        b'{}', {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=5) as response:
        return {item['name'] for item in json.load(response).get('rooms', [])}


def main():
    created = set()
    checks = []
    try:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'streams.sqlite'
            core = StreamSessions(path, lambda owner, user: True)
            try:
                actor = ('local-owner', 'local-device')
                identifier = core.start(actor, title='ephemeral', request_id='attempt')['id']
                generation = core.pending_cleanup()[0]
                created.add(generation)
                media_api('CreateRoom', {'name': generation})
                assert generation in rooms()
                checks.append('real room creation')
                core.transition(identifier, actor, 'stop', 1)
                assert generation in core.pending_cleanup()
                media_api('DeleteRoom', {'room': generation})
                assert generation not in rooms()
                core.acknowledge_cleanup(generation)
                assert core.pending_cleanup() == []
                checks.append('stop requires confirmed room deletion')
                core.start(actor, title='restart test', request_id='next')
                generation = core.pending_cleanup()[0]
                created.add(generation)
                media_api('CreateRoom', {'name': generation})
            finally:
                core.close()
            recovered = StreamSessions(path, lambda owner, user: True)
            try:
                assert recovered.discover(actor) == []
                for generation in recovered.pending_cleanup():
                    media_api('DeleteRoom', {'room': generation})
                    assert generation not in rooms()
                    recovered.acknowledge_cleanup(generation)
                assert recovered.pending_cleanup() == []
                checks.append('restart retires rooms without restoring session or chat')
            finally:
                recovered.close()
        print(json.dumps({'result': 'PASS', 'checks': checks,
                          'media_decryption_checked': False}, indent=2))
    finally:
        for generation in created:
            media_api('DeleteRoom', {'room': generation})


if __name__ == '__main__':
    main()
