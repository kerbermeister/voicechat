"""Run the synthetic marker page against a disposable LiveKit SFU."""
import argparse
import base64
import hashlib
import hmac
import json
import time
import urllib.request
import re
import secrets
import subprocess
import tempfile
import uuid
from pathlib import Path

from call_network_lab import ROOT, require_local_docker, valid_marker_result
from check_route_livekit import token
from check_route_turn import reserve_range
from serve_key_epoch_fixture import fixture_server


def create_marker_room(address, key, secret, shared_group=False, video_playout_ms=0, max_video_playout_ms=10000, room_name='route-probe'):
    if not re.fullmatch(r'127\.0\.0\.1:\d{4,5}', address) or int(address.rsplit(':', 1)[1]) > 65535:
        raise ValueError('Loopback SFU required')
    if room_name not in ('route-probe', 'route-probe-voice'):
        raise ValueError('Use an isolated probe room')
    if (type(shared_group) is not bool or type(video_playout_ms) is not int or
            type(max_video_playout_ms) is not int or
            not 0 <= video_playout_ms <= max_video_playout_ms <= 10000 or
            video_playout_ms % 10 or max_video_playout_ms % 10):
        raise ValueError('Invalid RTP playout-delay bounds')
    def b64(data):
        return base64.urlsafe_b64encode(data).decode().rstrip('=')
    header = b64(b'{"alg":"HS256","typ":"JWT"}')
    claims = b64(json.dumps({
        'iss': key, 'nbf': int(time.time()) - 5, 'exp': int(time.time()) + 30,
        'video': {'roomCreate': True},
    }).encode())
    jwt_body = f'{header}.{claims}'
    signature = b64(hmac.digest(secret.encode(), jwt_body.encode(), hashlib.sha256))
    settings = {'name': room_name, 'max_participants': 10, 'sync_streams': shared_group}
    if video_playout_ms:
        settings.update(min_playout_delay=video_playout_ms, max_playout_delay=max_video_playout_ms)
    create = urllib.request.Request(
        f'http://{address}/twirp/livekit.RoomService/CreateRoom', json.dumps(settings).encode(),
        {'Content-Type': 'application/json', 'Authorization': f'Bearer {jwt_body}.{signature}'},
    )
    for attempt in range(15):
        try:
            with urllib.request.urlopen(create, timeout=2) as reply:
                assert json.load(reply)['name'] == room_name
            return
        except OSError:
            if attempt == 14:
                raise
            time.sleep(.2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--web-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--shared-sync', action='store_true')
    parser.add_argument('--video-playout-ms', type=int, choices=(0, 130), default=0)
    parser.add_argument('--max-video-playout-ms', type=int, choices=(130, 10000), default=10000)
    args = parser.parse_args()
    assets = args.web_root.resolve()
    if args.output.exists() or not all((assets / file).is_file() for file in (
            'call_av_marker_fixture.html', 'main.dart.js', 'e2ee.worker.dart.js')):
        parser.error('Build the marker fixture and choose a new output file')
    require_local_docker()
    image = re.search(r'^FROM (livekit/livekit-server@sha256:\w+)',
                      (ROOT / 'infra/control.Dockerfile').read_text(), re.M)[1]
    port = 7394
    name = 'voicechat-av-sfu-' + uuid.uuid4().hex[:8]
    helper = name + '-netem'
    first, held = reserve_range()
    key, secret, nonce = 'marker-local', secrets.token_hex(32), secrets.token_hex(24)
    duration = 120
    shared_group = args.shared_sync

    def run(*args):
        return subprocess.run(args, check=True, capture_output=True, text=True, timeout=45).stdout.strip()

    def tc(*args):
        return run('docker', 'exec', helper, 'tc', *args)

    with tempfile.TemporaryDirectory(prefix=name) as temporary:
        config = Path(temporary) / 'sfu.json'
        config.write_text(json.dumps({'port': 7880, 'keys': {key: secret},
            'room': {'auto_create': False, 'max_participants': 10, 'sync_streams': shared_group}, 'rtc': {
            'port_range_start': first, 'port_range_end': first + 7,
            'node_ip': '127.0.0.1', 'use_external_ip': False}}))
        config.chmod(0o600)
        try:
            for socket in held:
                socket.close()
            run('docker', 'run', '-d', '--name', name, '-p', '127.0.0.1::7880/tcp',
                *[arg for p in range(first, first + 8) for arg in ('-p', f'127.0.0.1:{p}:{p}/udp')],
                '-v', f'{config}:/etc/sfu.json:ro', '--memory', '384m', '--cpus', '1',
                '-e', 'GOMAXPROCS=2', image, '--config', '/etc/sfu.json')
            run('docker', 'run', '-d', '--name', helper, '--network', 'container:' + name,
                '--cap-add', 'NET_ADMIN', '--read-only', '--entrypoint', 'sleep',
                'voicechat-network-probe:fixture', 'infinity')
            tc('qdisc', 'replace', 'dev', 'eth0', 'root', 'handle', '1:', 'prio',
               'bands', '2', 'priomap', *['0'] * 16)
            address = run('docker', 'port', name, '7880/tcp')
            assert address.startswith('127.0.0.1:')
            create_marker_room(address, key, secret, shared_group, args.video_playout_ms, args.max_video_playout_ms)

            fixture_config = json.dumps({
                'marker_seconds': duration, 'media_payload_types': [96, 97], 'impaired_media': 'video',
                'delay_then_pause': True, 'lab_key': nonce,
            }).encode()
            with fixture_server(assets, port, {
                'url': 'ws://' + address, **{who: token(who, key, secret) for who in ('alice', 'bob')},
            }) as server:
                output = args.output
                current_types = None
                filters = {}
                class Handler(server.RequestHandlerClass):
                    def do_GET(self):
                        if self.path != '/turn.json':
                            return super().do_GET()
                        if self.headers.get('Host') != f'127.0.0.1:{port}':
                            self.send_error(403)
                            return
                        self.send_response(200)
                        self.send_header('Content-Type', 'application/json')
                        self.send_header('Content-Length', str(len(fixture_config)))
                        self.send_header('Cache-Control', 'no-store')
                        self.end_headers()
                        self.wfile.write(fixture_config)

                    def do_POST(self):
                        nonlocal current_types
                        try:
                            if (self.headers.get('Host') != f'127.0.0.1:{port}' or
                                    self.headers.get('Origin') != f'http://127.0.0.1:{port}' or
                                    not secrets.compare_digest(self.headers.get('X-Lab-Key', ''), nonce)):
                                self.send_error(403)
                                return
                            length = int(self.headers.get('Content-Length', '0'))
                            if not 0 < length <= 150_000:
                                raise ValueError('Invalid request length')
                            data = json.loads(self.rfile.read(length))
                            if self.path == '/profile':
                                payloads = data['payload_types']
                                if not (isinstance(payloads, list) and 1 <= len(payloads) <= 4 and
                                        all(type(pt) is int and 96 <= pt <= 127 for pt in payloads) and
                                        len(payloads) == len(set(payloads))):
                                    raise ValueError('Invalid dynamic payload types')
                                if current_types is None:
                                    for pt in payloads:
                                        tc('filter', 'add', 'dev', 'eth0', 'protocol', 'ip',
                                           'parent', '1:', 'prio', '1', 'u32',
                                           'match', 'ip', 'protocol', '17', '0xff',
                                           'match', 'u8', '0x45', '0xff', 'at', '0',
                                           'match', 'u8', '0x80', '0xc0', 'at', '28',
                                           'match', 'u8', hex(pt), '0x7f', 'at', '29', 'flowid', '1:2')
                                    current_types = payloads
                                if payloads != current_types:
                                    raise ValueError('Payload types changed')
                                profile = data['profile']
                                settings = {'clean': ['delay', '0ms'], 'delay': ['delay', '150ms'],
                                            'offline': ['loss', '100%']}[profile]
                                filters[profile] = tc('-s', 'qdisc', 'show', 'dev', 'eth0')
                                tc('qdisc', 'replace', 'dev', 'eth0', 'parent', '1:2',
                                   'handle', '20:', 'netem', *settings)
                            elif self.path == '/marker-result':
                                if not valid_marker_result(data, duration):
                                    raise ValueError('Invalid marker results')
                                with output.open('x') as stream:
                                    json.dump({'result': data, 'sfu_image': image,
                                               'filters': filters, 'isolated_sfu': True, 'shared_group_requested': shared_group}, stream, indent=2)
                            else:
                                raise ValueError('Unknown path')
                            self.send_response(200)
                        except (KeyError, ValueError, TypeError, OSError, subprocess.SubprocessError):
                            self.send_response(400)
                        self.end_headers()
                server.RequestHandlerClass = Handler
                print(f'http://127.0.0.1:{port}/call_av_marker_fixture.html?sfu=1&rtp=1', flush=True)
                server.serve_forever()
        finally:
            subprocess.run(['docker', 'rm', '-f', helper, name], capture_output=True, timeout=30)


if __name__ == '__main__':
    main()
