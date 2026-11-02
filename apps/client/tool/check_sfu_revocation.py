"""Observe pinned OSS SFU token removal in a disposable, loopback-only container.

A successful run confirms the OLD token is accepted after RemoveParticipant.
It is a negative security observation, not a test that revocation is implemented.
"""
import argparse
import asyncio
import base64
import hashlib
import hmac
import json
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
import time
from urllib.request import urlopen
from urllib.error import URLError
import uuid

import aiohttp
from call_network_lab import ROOT, require_local_docker


async def check(origin, api_key, secret, room):
    def token(identity, grant):
        def encode(value):
            return base64.urlsafe_b64encode(json.dumps(
                value, separators=(',', ':')).encode()).rstrip(b'=')
        now = int(time.time())
        body = encode({'alg': 'HS256', 'typ': 'JWT'}) + b'.' + encode({
            'iss': api_key, 'sub': identity, 'nbf': now - 1, 'exp': now + 60,
            'video': grant,
        })
        signature = base64.urlsafe_b64encode(hmac.digest(
            secret.encode(), body, hashlib.sha256)).rstrip(b'=')
        return (body + b'.' + signature).decode()

    admin = token('operator', {
        'roomCreate': True, 'roomList': True, 'roomAdmin': True, 'room': room,
    })
    join = token('excluded', {
        'roomJoin': True, 'room': room, 'canPublish': False,
        'canSubscribe': True, 'canPublishData': False,
    })
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=5)) as session:
        async def rpc(method, body):
            async with session.post(
                origin + '/twirp/livekit.RoomService/' + method, json=body,
                headers={'Authorization': 'Bearer ' + admin},
            ) as response:
                assert response.status == 200, (method, response.status)
                return await response.json()

        async def connect():
            socket = await session.ws_connect(origin.replace('http:', 'ws:') + '/rtc', params={
                'access_token': join, 'auto_subscribe': '0', 'protocol': '15',
                'sdk': 'js', 'version': '2.15.6',
            })
            message = await socket.receive(timeout=5)
            assert message.type == aiohttp.WSMsgType.BINARY
            participant = await rpc('GetParticipant', {'room': room, 'identity': 'excluded'})
            return socket, participant['sid']

        await rpc('CreateRoom', {'name': room, 'emptyTimeout': 60})
        first, old_sid = await connect()
        await rpc('RemoveParticipant', {'room': room, 'identity': 'excluded'})
        await first.close()
        second, new_sid = await connect()
        assert old_sid != new_sid
        await second.close()
        await rpc('DeleteRoom', {'room': room})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    require_local_docker()
    image = re.search(r'^FROM (livekit/livekit-server@sha256:\w+)',
                      (ROOT / 'infra/control.Dockerfile').read_text())[1]
    name = 'voicechat-revoke-' + uuid.uuid4().hex[:10]
    api_key = 'API' + secrets.token_hex(8)
    secret = secrets.token_hex(32)
    room = 'qa-' + secrets.token_hex(12)
    with tempfile.TemporaryDirectory(prefix=name) as temporary:
        folder = Path(temporary)
        folder.chmod(0o700)
        config = folder / 'sfu.json'
        config.write_text(json.dumps({
            'port': 7880, 'keys': {api_key: secret},
            'rtc': {'tcp_port': 7881, 'port_range_start': 50000,
                    'port_range_end': 50007, 'use_external_ip': False},
        }))
        config.chmod(0o600)
        try:
            subprocess.run([
                'docker', 'run', '--detach', '--name', name,
                '--publish', '127.0.0.1::7880/tcp',
                '--volume', str(config) + ':/etc/sfu.json:ro',
                '--memory', '256m', '--cpus', '1', '--env', 'GOMAXPROCS=2',
                image, '--config', '/etc/sfu.json',
            ], check=True, capture_output=True, timeout=20)
            port = subprocess.check_output(['docker', 'port', name, '7880/tcp'], text=True).strip()
            assert port.startswith('127.0.0.1:')
            for attempt in range(30):
                try:
                    with urlopen('http://' + port, timeout=1) as response:
                        assert response.status == 200
                    break
                except (OSError, URLError):
                    time.sleep(.1)
            else:
                raise RuntimeError('SFU not healthy')
            awaitable = check('http://' + port, api_key, secret, room)
            asyncio.run(awaitable)
            proof = {
                'pinned_sfu': image, 'loopback_only': True,
                'same_original_jwt_reaccepted_after_remove': True,
                'new_participant_sid': True, 'room_name_changed': False,
                'media_decryption_tested': False, 'production_modified': False,
            }
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(proof, indent=2) + '\n')
            print(json.dumps(proof))
        finally:
            subprocess.run(['docker', 'rm', '--force', name],
                           check=True, capture_output=True, timeout=15)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # aiohttp errors can contain the temporary JWT URL; never print them.
        raise SystemExit('SFU probe failed: ' + type(error).__name__) from None
