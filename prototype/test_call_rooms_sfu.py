"""Opt-in pinned SFU room reconciliation; no media or user accounts."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import urllib.request
import urllib.error
import uuid

from call_control import CallStore, CallError
import token_server


@unittest.skipUnless(os.environ.get('VOICECHAT_DOCKER_TESTS') == '1', 'Requires local Docker')
class CallRoomsSfuTest(unittest.TestCase):
    def test_real_list_permission_heartbeat_and_missing_room_repair(self):
        root = Path(__file__).resolve().parents[1]
        image = (root / 'infra/control.Dockerfile').read_text().splitlines()[0].split()[1]
        self.assertIn('@sha256:', image)
        context = json.loads(subprocess.check_output(['docker', 'context', 'inspect'], text=True))
        self.assertTrue(context[0]['Endpoints']['docker']['Host'].startswith('unix://'))
        self.assertFalse(os.environ.get('DOCKER_HOST') or os.environ.get('DOCKER_CONTEXT'))
        name = 'voicechat-call-room-' + uuid.uuid4().hex[:10]
        secret = secrets.token_hex(32)
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            folder.chmod(0o700)
            config = folder / 'sfu.json'
            config.write_text(json.dumps({
                'port': 7880, 'keys': {'prototype': secret},
                'rtc': {'tcp_port': 7881, 'port_range_start': 50000,
                        'port_range_end': 50007, 'use_external_ip': False},
                'room': {'auto_create': False},
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
                address = subprocess.check_output(['docker', 'port', name, '7880/tcp'], text=True).strip()
                self.assertTrue(address.startswith('127.0.0.1:'))
                origin = 'http://' + address
                real_open = urllib.request.urlopen
                for _ in range(30):
                    try:
                        with real_open(origin, timeout=1) as response:
                            self.assertEqual(response.status, 200)
                        break
                    except (OSError, urllib.error.URLError):
                        time.sleep(.1)
                else:
                    self.fail('Pinned SFU did not start')

                def redirect(request, **kwargs):
                    prefix = 'http://127.0.0.1:7880/'
                    self.assertTrue(request.full_url.startswith(prefix))
                    local = urllib.request.Request(
                        origin + '/' + request.full_url.removeprefix(prefix),
                        request.data, dict(request.header_items()), method=request.get_method(),
                    )
                    return real_open(local, **kwargs)

                now, operations = [1000.], []
                def media(method, body):
                    operations.append(method)
                    return token_server.media_api(method, body)

                who = {'user_id': '@synthetic:local', 'device_id': 'D'}
                with patch.object(token_server, 'secret', secret), patch('urllib.request.urlopen', redirect):
                    store = CallStore(folder / 'calls.sqlite', media, lambda: now[0])
                    def admit(lease=None):
                        return store.admission('!synthetic:local', 'call', False, who,
                                               'synthetic-curve', 'synthetic-ed', lease=lease)
                    with self.assertRaisesRegex(CallError, 'generation_settling'):
                        admit()
                    now[0] += 1
                    first = admit()
                    operations.clear()
                    for _ in range(10):
                        now[0] += 3
                        self.assertEqual(admit(first['lease_id'])['generation'], first['generation'])
                    self.assertEqual(operations, [])
                    store.reconcile()
                    self.assertEqual(operations, ['ListRooms'])
                    media('DeleteRoom', {'room': first['generation']})
                    now[0] += 3
                    store.reconcile()
                    self.assertEqual(operations[-2:], ['ListRooms', 'CreateRoom'])
                    rooms = media('ListRooms', {'names': [first['generation']]}).get('rooms', [])
                    self.assertEqual([room['name'] for room in rooms], [first['generation']])
                    store.leave(who, first['lease_id'])
                    self.assertEqual(media('ListRooms', {'names': [first['generation']]}).get('rooms', []), [])
            finally:
                subprocess.run(['docker', 'rm', '--force', name],
                               check=True, capture_output=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
