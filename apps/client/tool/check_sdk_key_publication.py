"""Probe SDK camera/key publication against an isolated loopback SFU on macOS."""
import argparse
import base64
import hashlib
from contextlib import ExitStack, nullcontext
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import ipaddress
import socket
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile
import threading
import time
from urllib.request import urlopen
from urllib.parse import unquote, urlparse
import uuid
import wave

from call_network_lab import ROOT, require_local_docker
from check_route_livekit import token
from check_route_turn import reserve_range
from native_av_fixture import native_av_fixture
from call_sfu_marker_lab import create_marker_room


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device', default='macos')
    parser.add_argument('--android-emulator', action='store_true')
    parser.add_argument('--adb', type=Path)
    parser.add_argument('--case', choices=('both', 'baseline', 'pinned'), default='both')
    parser.add_argument('--require-frame-encryption', action='store_true')
    parser.add_argument('--repeat-receiver-key', action='store_true', help='Repeat the same receiver key every 9s, 20 times; baseline native case only')
    parser.add_argument('--web-root', type=Path, help='Serve a built synthetic browser probe instead of running native tests')
    parser.add_argument('--web-port', type=int, default=7395)
    parser.add_argument('--failures', action='store_true', help='Exercise native capture/cryptor rollback')
    parser.add_argument('--av-marker-output', type=Path, help='Run the injected native synthetic A/V fixture')
    parser.add_argument('--shared-sync', action='store_true', help='Enable native A/V synchronization in the disposable room')
    parser.add_argument('--native-call-sync', action='store_true', help='Use the native call subscriber stream policy without changing SFU/browser grouping')
    parser.add_argument('--video-playout-ms', type=int, choices=(0, 130), default=0)
    parser.add_argument('--native-video-playout-ms', type=int, choices=(0, 70, 90, 100, 130), default=0)
    parser.add_argument('--coherent-source', action='store_true', help='Queue video marker boundaries with the synthetic audio source')
    parser.add_argument('--min-native-video-playout-ms', type=int, choices=(0, 20, 70, 90, 100, 130))
    parser.add_argument('--max-video-playout-ms', type=int, choices=(130, 10000), default=10000)
    parser.add_argument('--av-marker-network', action='store_true', help='Apply video-only delay and outage in the disposable SFU')
    parser.add_argument('--timestamp-full-reset', action='store_true', help='Diagnostic macOS fixture: reset full timestamp-model covariance on alarms')
    parser.add_argument('--ordinary-voice-reference', action='store_true', help='Run a simultaneous E2EE audio-only call in a separate disposable room (Mac fixture)')
    parser.add_argument('--adaptive-video-playout', action='store_true', help='Diagnostic only: native adaptive video delay with full clock recovery and shared A/V streams')
    parser.add_argument('--keyless-mute-cycle', action='store_true', help='Diagnostic only: mute/unmute before receiver keys, retain native SIF logs')
    parser.add_argument('--drop-keyless-sif', action='store_true', help='Negative diagnostic only: disable SFU blank-frame bypass before keys')
    parser.add_argument('--av-speech', type=Path, help='Synthetic mono48kHz PCM16 WAV; never use a personal recording')
    parser.add_argument('--av-sender-root', type=Path, help='Separate account-free macOS sender checkout (A/V fixture only)')
    parser.add_argument('--av-media-ip', help='Local private interface for encrypted RTP between Mac and the owned Android emulator')
    args = parser.parse_args()
    if args.drop_keyless_sif and not args.keyless_mute_cycle:
        parser.error('Dropping SFU blank frames is only a negative keyless diagnostic')
    if args.native_call_sync and (not args.av_marker_output or args.web_root):
        parser.error('Native call synchronization requires the native A/V marker fixture')
    if args.timestamp_full_reset and (args.device != 'macos' or not args.av_marker_output or args.native_video_playout_ms != 0):
        parser.error('Timestamp diagnostic requires the Mac A/V fixture with native SDK default playout')
    if args.ordinary_voice_reference and (not args.av_marker_output or args.web_root or (args.device != 'macos' and not args.av_sender_root)):
        parser.error('Ordinary voice comparison requires the Mac fixture or a separate Mac sender and owned Android receiver')
    if args.adaptive_video_playout and not (args.ordinary_voice_reference and args.timestamp_full_reset and args.shared_sync and args.video_playout_ms == 130 and args.max_video_playout_ms == 130):
        parser.error('Adaptive video diagnostic requires full clock recovery, ordinary voice reference, shared streams and the existing SFU130ms hint')
    if args.keyless_mute_cycle and not args.ordinary_voice_reference:
        parser.error('Keyless mute diagnostic requires the paired ordinary voice fixture')
    if args.min_native_video_playout_ms is not None and (args.native_video_playout_ms == 0 or args.min_native_video_playout_ms > args.native_video_playout_ms):
        parser.error('Native minimum requires a nonzero maximum and must not exceed it')
    if bool(args.av_sender_root) != bool(args.av_media_ip):
        parser.error('Separate sender requires its checkout and a local private media interface')
    if args.av_sender_root:
        if not args.av_marker_output or not args.android_emulator:
            parser.error('Separate sender requires the synthetic Android receiver fixture')
        address = ipaddress.ip_address(args.av_media_ip)
        if not address.is_private or address.is_loopback or address.is_unspecified or address.version != 4:
            parser.error('Use a local private IPv4 interface for synthetic encrypted RTP')
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as binding:
            binding.bind((args.av_media_ip, 0))
        sender_root = args.av_sender_root.resolve()
        for relative in ('apps/client/integration_test/native_av_marker_test.dart',
                         'apps/client/integration_test/native_av_marker.swift'):
            if (sender_root / relative).read_bytes() != (ROOT / relative).read_bytes():
                parser.error('Separate native sender fixture must match the receiver source')
    if args.av_marker_network and not args.av_marker_output:
        parser.error('Network impairment requires the synthetic marker fixture')
    if args.av_marker_output and shutil.disk_usage(ROOT).free < 2_000_000_000:
        parser.error('Keep at least 2 GB free before starting a native marker probe; cold builds need additional space')
    speech = ''
    if args.av_speech:
        if not args.av_marker_output:
            parser.error('Speech requires the synthetic A/V fixture')
        with wave.open(str(args.av_speech), 'rb') as wav:
            if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) != (1, 2, 48000) or wav.getnframes() > 48000:
                parser.error('Use at most one second of synthetic mono48kHz PCM16 speech')
            speech = base64.b64encode(wav.readframes(wav.getnframes())).decode()
    if args.repeat_receiver_key and (args.case != 'baseline' or args.failures or args.web_root):
        parser.error('Receiver-key repetition requires --case baseline and the native publication probe')
    if args.device != 'macos':
        if not args.android_emulator or args.adb is None or args.web_root:
            parser.error('Non-Mac native probes require the disposable Android emulator and --adb')
        def adb(*command):
            return subprocess.check_output([str(args.adb.resolve()), '-s', args.device, *command], text=True).strip()
        if adb('shell', 'getprop', 'ro.kernel.qemu') != '1' or adb('emu', 'avd', 'name').splitlines()[0] != 'VoiceChat_KeyEpoch35':
            parser.error('Only the account-free VoiceChat_KeyEpoch35 emulator is supported')
    elif args.android_emulator:
        parser.error('Select the Android emulator with --device')
    require_local_docker()
    image = re.search(r'^FROM (livekit/livekit-server@sha256:\w+)',
                      (ROOT / 'infra/control.Dockerfile').read_text())[1]
    name = 'voicechat-sdk-key-' + uuid.uuid4().hex[:12]
    first, held = reserve_range()
    api_key, secret = 'local-probe', secrets.token_hex(32)
    target = ROOT / 'apps/client/integration_test' / (
        'native_av_marker_test.dart' if args.av_marker_output else
        'native_key_startup_failure_test.dart' if args.failures
        else 'native_group_key_publication_test.dart')
    package_config = ROOT / 'apps/client/.dart_tool/package_config.json'
    package = next(p for p in json.loads(package_config.read_text())['packages']
                   if p['name'] == 'livekit_client')
    sdk = (package_config.parent / unquote(urlparse(package['rootUri']).path)).resolve()
    log = ROOT / '.prototype' / (name + '.private.log')
    log.parent.mkdir(parents=True, exist_ok=True)
    with ExitStack() as stack, tempfile.TemporaryDirectory(prefix=name) as temporary:
        folder = Path(temporary)
        folder.chmod(0o700)
        config = folder / 'livekit.json'
        config.write_text(json.dumps({
            'port': 7880, 'keys': {api_key: secret},
            'room': {'auto_create': False, 'sync_streams': args.shared_sync},
            'rtc': {'port_range_start': first, 'port_range_end': first + 7,
                    'use_external_ip': False,
                    'node_ip': args.av_media_ip or ('10.0.2.2' if args.android_emulator else '127.0.0.1')},
        }))
        config.chmod(0o600)
        marker_url = ''
        network_profiles = []
        receiver_ready = False
        receiver_done = False
        keyless_mute_requested = False
        sender_muted_unmuted = False
        source_markers = None
        marker_key = base64.b64encode(secrets.token_bytes(32)).decode() if args.av_sender_root else ''
        helper = name + '-netem'
        payload_types = None
        def tc(*command):
            return subprocess.check_output(['docker', 'exec', helper, 'tc', *command], text=True, timeout=15)
        if args.av_marker_output:
            if args.av_marker_output.exists():
                parser.error('Choose a new synthetic marker output path')
            marker_path = '/' + secrets.token_hex(24)
            class MarkerHandler(BaseHTTPRequestHandler):
                def log_message(self, *_):
                    pass

                def do_GET(self):
                    if self.path != marker_path + '/state' or not args.av_sender_root:
                        self.send_error(403)
                        return
                    data = json.dumps({'receiver_ready': receiver_ready,
                                       'receiver_done': receiver_done,
                                       'keyless_mute_requested': keyless_mute_requested,
                                       'sender_muted_unmuted': sender_muted_unmuted}).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)

                def do_POST(self):
                    nonlocal payload_types, receiver_ready, receiver_done, source_markers
                    nonlocal keyless_mute_requested, sender_muted_unmuted
                    paths = (marker_path, marker_path + '/profile')
                    if args.av_sender_root:
                        paths += (marker_path + '/ready', marker_path + '/source')
                        if args.keyless_mute_cycle:
                            paths += (marker_path + '/mute',)
                    if self.path not in paths or self.headers.get('Transfer-Encoding'):
                        self.send_error(403)
                        return
                    length = int(self.headers.get('Content-Length', '0'))
                    # Paired capture exports two bounded synthetic PCM streams.
                    limit = 128_000_000 if args.ordinary_voice_reference else 64_000_000
                    if not 0 < length <= limit:
                        self.send_error(413)
                        return
                    data = self.rfile.read(length)
                    try:
                        value = json.loads(data)
                        if self.path.endswith('/mute'):
                            if value == {'keyless_mute_requested': True}:
                                keyless_mute_requested = True
                            else:
                                assert keyless_mute_requested and value == {'sender_muted_unmuted': True}
                                sender_muted_unmuted = True
                            self.send_response(200)
                            self.end_headers()
                            return
                        if self.path.endswith('/ready'):
                            assert value == {'receiver_ready': True}
                            receiver_ready = True
                            self.send_response(200)
                            self.end_headers()
                            return
                        if self.path.endswith('/source'):
                            assert value['synthetic_media_only'] is True and value['encrypted_publications'] is True
                            minimum = 1 if args.keyless_mute_cycle else 20
                            assert len(value['source_audio']) >= minimum and len(value['source_video']) >= minimum
                            source_markers = value
                            media = json.loads(args.av_marker_output.read_text())
                            assert media['separate_native_sender'] is True
                            for field in ('source_audio', 'source_video'):
                                media['markers'][field] = value[field]
                            args.av_marker_output.write_text(json.dumps(media))
                            self.send_response(200)
                            self.end_headers()
                            return
                        if self.path.endswith('/profile'):
                            assert args.av_marker_network
                            types = value['payload_types']
                            assert (isinstance(types, list) and 1 <= len(types) <= 4 and
                                    all(type(pt) is int and 96 <= pt <= 127 for pt in types) and
                                    len(types) == len(set(types)))
                            if payload_types is None:
                                for pt in types:
                                    tc('filter', 'add', 'dev', 'eth0', 'protocol', 'ip', 'parent', '1:',
                                       'prio', '1', 'u32', 'match', 'ip', 'protocol', '17', '0xff',
                                       'match', 'u8', '0x45', '0xff', 'at', '0',
                                       'match', 'u8', '0x80', '0xc0', 'at', '28',
                                       'match', 'u8', hex(pt), '0x7f', 'at', '29', 'flowid', '1:2')
                                payload_types = types
                            assert payload_types == types
                            settings = {'clean': ['delay', '0ms'], 'delay': ['delay', '150ms'],
                                        'offline': ['loss', '100%']}[value['profile']]
                            network_profiles.append({'next': value['profile'], 'previous_counters':
                                                     tc('-s', 'qdisc', 'show', 'dev', 'eth0')})
                            tc('qdisc', 'replace', 'dev', 'eth0', 'parent', '1:2', 'handle', '20:', 'netem', *settings)
                            self.send_response(200)
                            self.end_headers()
                            return
                        assert value['synthetic_media_only'] is True
                        value['network_profiles'] = network_profiles
                        with args.av_marker_output.open('xb') as output:
                            output.write(json.dumps(value).encode())
                        receiver_done = True
                    except (ValueError, KeyError, AssertionError, FileExistsError, subprocess.SubprocessError):
                        self.send_error(400)
                        return
                    self.send_response(200)
                    self.end_headers()
            server = ThreadingHTTPServer(('127.0.0.1', 0), MarkerHandler)
            server.daemon_threads = True
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            stack.callback(server.server_close)
            stack.callback(server.shutdown)
            marker_host = '10.0.2.2' if args.android_emulator else '127.0.0.1'
            marker_url = f'http://{marker_host}:{server.server_port}{marker_path}'
        created = False
        try:
            for item in held:
                item.close()
            subprocess.run([
                'docker', 'run', '--detach', '--name', name,
                '--publish', '127.0.0.1::7880/tcp',
                *[argument for port in range(first, first + 8)
                  for argument in ('--publish', f'{args.av_media_ip or "127.0.0.1"}:{port}:{port}/udp')],
                '--volume', str(config) + ':/etc/sfu.json:ro',
                '--memory', '384m', '--cpus', '1', '--env', 'GOMAXPROCS=2',
                image, '--config', '/etc/sfu.json',
            ], check=True, capture_output=True, timeout=30)
            created = True
            if args.av_marker_network:
                subprocess.run(['docker', 'run', '-d', '--name', helper, '--network', 'container:' + name,
                                '--cap-add', 'NET_ADMIN', '--read-only', '--entrypoint', 'sleep',
                                'voicechat-network-probe:fixture', 'infinity'], check=True, capture_output=True, timeout=30)
                tc('qdisc', 'replace', 'dev', 'eth0', 'root', 'handle', '1:', 'prio', 'bands', '2',
                   'priomap', *['0'] * 16)
            address = subprocess.check_output(
                ['docker', 'port', name, '7880/tcp'], text=True).strip()
            if not address.startswith('127.0.0.1:'):
                raise ValueError('Loopback SFU required')
            for attempt in range(50):
                try:
                    with urlopen('http://' + address, timeout=1) as response:
                        assert response.status == 200
                    break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError('Local SFU not ready')
            create_marker_room(address, api_key, secret, args.shared_sync, args.video_playout_ms, args.max_video_playout_ms)
            if args.ordinary_voice_reference:
                create_marker_room(address, api_key, secret, room_name='route-probe-voice')
            client_address = address.replace('127.0.0.1:', '10.0.2.2:') if args.android_emulator else address
            defines = folder / 'client.json'
            defines.write_text(json.dumps({
                'HARDWARE_CALL_TEST': True, 'GROUP_TEST_URL': 'ws://' + client_address,
                'GROUP_TEST_CASE': args.case,
                'GROUP_TEST_LOCAL_SDK_PATCH': (sdk / 'VOICECHAT_PATCH.md').is_file(),
                'GROUP_TEST_REQUIRE_FRAME_ENCRYPTION': args.require_frame_encryption,
                'GROUP_TEST_REPEAT_RECEIVER_KEY': args.repeat_receiver_key,
                'AV_MARKER_OUTPUT': marker_url,
                'AV_VIDEO_PLAYOUT_MS': args.video_playout_ms,
                'AV_NATIVE_VIDEO_PLAYOUT_MS': args.native_video_playout_ms,
                'AV_TIMESTAMP_FULL_RESET': args.timestamp_full_reset,
                'AV_ORDINARY_VOICE_REFERENCE': args.ordinary_voice_reference,
                'AV_ADAPTIVE_VIDEO_PLAYOUT': args.adaptive_video_playout,
                'AV_KEYLESS_MUTE_CYCLE': args.keyless_mute_cycle,
                'AV_NATIVE_CALL_SYNC': args.native_call_sync,
                'AV_DROP_KEYLESS_SIF': args.drop_keyless_sif,
                'AV_NATIVE_VIDEO_MIN_PLAYOUT_MS': args.min_native_video_playout_ms if args.min_native_video_playout_ms is not None else args.native_video_playout_ms,
                'AV_COHERENT_MARKERS': args.coherent_source,
                'AV_MARKER_NETWORK': args.av_marker_network,
                'AV_MARKER_ROLE': 'receiver' if args.av_sender_root else 'both',
                'AV_MARKER_KEY': marker_key,
                'AV_SPEECH_BASE64': speech,
                'GROUP_TEST_ALICE': token('alice', api_key, secret),
                'GROUP_TEST_BOB': token('bob', api_key, secret),
                'GROUP_TEST_OBSERVER': token('observer', api_key, secret),
                **({'AV_VOICE_ALICE': token('voice-alice', api_key, secret, room_name='route-probe-voice'),
                    'AV_VOICE_BOB': token('voice-bob', api_key, secret, room_name='route-probe-voice')}
                   if args.ordinary_voice_reference else {}),
            }))
            defines.chmod(0o600)
            if args.web_root:
                from serve_key_epoch_fixture import fixture_server
                if not 1024 <= args.web_port <= 65535 or not (args.web_root / 'main.dart.js').is_file():
                    raise ValueError('A built fixture and unprivileged port are required')
                with fixture_server(args.web_root, args.web_port, {
                    'url': 'ws://' + address,
                    **{identity: token(identity, api_key, secret)
                       for identity in ('alice', 'bob', 'observer')},
                }) as server:
                    print(f'http://127.0.0.1:{args.web_port}/index.html (synthetic SDK/SFU probe)', flush=True)
                    server.serve_forever()
                return

            env = {**os.environ, 'LANG': 'en_US.UTF-8',
                   'LC_ALL': 'en_US.UTF-8', 'LC_CTYPE': 'en_US.UTF-8'}
            print('Local SDK/SFU private log: ' + str(log), flush=True)
            timeout = (900 if args.android_emulator else 600) if args.repeat_receiver_key else (600 if args.android_emulator else 360)
            if args.av_sender_root:
                sender_defines = folder / 'sender.json'
                settings = json.loads(defines.read_text())
                settings.update(AV_MARKER_ROLE='sender', GROUP_TEST_URL='ws://' + address,
                                AV_MARKER_OUTPUT=f'http://127.0.0.1:{server.server_port}{marker_path}')
                sender_defines.write_text(json.dumps(settings))
                sender_defines.chmod(0o600)
                sender_log = log.with_suffix('.sender.private.log')
                sender_output = stack.enter_context(sender_log.open('w'))
                sender_log.chmod(0o600)
                stack.enter_context(native_av_fixture(sender_root, 'macos'))
                sender = subprocess.Popen([
                    str(args.flutter.resolve()), 'test', '-d', 'macos',
                    '--dart-define-from-file=' + str(sender_defines),
                    'integration_test/' + target.name,
                ], cwd=sender_root / 'apps/client', env=env, stdout=sender_output, stderr=subprocess.STDOUT)
                def stop_sender():
                    if sender.poll() is None:
                        sender.terminate()
                        try:
                            sender.wait(timeout=30)
                        except subprocess.TimeoutExpired:
                            sender.kill()
                            sender.wait(timeout=10)
                stack.callback(stop_sender)
            android_abi = adb('shell', 'getprop', 'ro.product.cpu.abi') if args.android_emulator else None
            with native_av_fixture(ROOT, args.device, android_abi) if args.av_marker_output else nullcontext(), log.open('w') as output:
                log.chmod(0o600)
                result = subprocess.run([
                    str(args.flutter.resolve()), 'test', '-d', args.device,
                    '--dart-define-from-file=' + str(defines),
                    'integration_test/' + target.name,
                ], cwd=ROOT / 'apps/client', env=env, stdout=output,
                    stderr=subprocess.STDOUT, timeout=timeout)
            if args.av_sender_root:
                if sender.wait(timeout=120) or 'All tests passed!' not in sender_log.read_text() or source_markers is None:
                    raise RuntimeError('Separate native sender failed; inspect private sender log')
                media = json.loads(args.av_marker_output.read_text())
                assert media['separate_native_sender'] is True
                for field in ('source_audio', 'source_video'):
                    media['markers'][field] = source_markers[field]
                args.av_marker_output.write_text(json.dumps(media))
            text = log.read_text()
            if result.returncode or 'All tests passed!' not in text:
                raise RuntimeError('SDK assertions failed; inspect private log ' + str(log))
            marker = 'SDK_AV_KEY_GATE_PROOF' if args.keyless_mute_cycle else 'SDK_AV_MARKER_PROOF' if args.av_marker_output else 'SDK_KEY_FAILURE_PROOF' if args.failures else 'SDK_KEY_PUBLICATION_PROOF'
            proofs = [json.loads(value) for value in re.findall(
                marker + r' (\{[^\n]+\})', text)]
            expected = {'both': [False, True], 'baseline': [False], 'pinned': [True]}
            if args.keyless_mute_cycle:
                assert len(proofs) == 1 and proofs[0]['missing_key_blocked'] and proofs[0]['ordinary_missing_key_blocked']
                assert proofs[0]['keys_installed'] is False and proofs[0]['positive_media_qualified'] is False
            elif args.av_marker_output:
                assert len(proofs) == 1 and proofs[0]['missing_key_blocked']
                assert proofs[0]['shared_group'] == (args.shared_sync or args.native_call_sync)
                assert proofs[0]['audio_chunks'] > 1000 and proofs[0]['video_markers'] > 5
            elif args.failures:
                assert len(proofs) == 12
            else:
                assert [proof['pinned_provider'] for proof in proofs] == expected[args.case]
                if args.repeat_receiver_key:
                    assert len(proofs) == 1 and proofs[0]['repeated_receiver_key_installs'] == 20
                    assert all(after > before + 5 for before, after in proofs[0]['frames_before_after_repeated_install'])
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps({
                'pinned_sfu': image, 'loopback_only': not bool(args.av_sender_root),
                'signaling_loopback_only': True,
                'separate_native_sender': bool(args.av_sender_root),
                'private_interface_encrypted_rtp': bool(args.av_sender_root),
                'platform': 'Android emulator API35' if args.android_emulator else 'native macOS',
                'local_camera': not args.android_emulator and not args.av_marker_output,
                'emulated_camera': args.android_emulator and not args.av_marker_output,
                'synthetic_media': bool(args.av_marker_output),
                'rtp_video_playout_min_ms': args.video_playout_ms,
                'rtp_video_playout_max_ms': args.max_video_playout_ms if args.video_playout_ms else None,
                'case': 'failure rollback' if args.failures else args.case,
                'local_sdk_patch': (sdk / 'VOICECHAT_PATCH.md').is_file(),
                'sdk_e2ee_manager_sha256': hashlib.sha256(
                    (sdk / 'lib/src/e2ee/e2ee_manager.dart').read_bytes()).hexdigest(),
                'require_frame_encryption': args.require_frame_encryption,
                'repeat_receiver_key': args.repeat_receiver_key,
                'production_modified': False,
                'fixture_sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                'native_fixture_sha256': {
                    name: hashlib.sha256((target.parent / name).read_bytes()).hexdigest()
                    for name in ('native_av_marker.swift', 'NativeAVMarker.kt')
                } if args.av_marker_output else None,
                'private_log_sha256': hashlib.sha256(log.read_bytes()).hexdigest(),
                'runs': proofs,
            }, indent=2) + '\n')
        finally:
            if args.av_marker_network:
                subprocess.run(['docker', 'rm', '--force', helper], capture_output=True, timeout=15)
            for item in held:
                item.close()
            removed = subprocess.run(['docker', 'rm', '--force', name],
                                     capture_output=True, timeout=15)
            if created and removed.returncode:
                raise RuntimeError('Owned SFU container cleanup failed')
    print('PASS: real SDK/SFU publication probe; inspect safety/negative-control fields')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        if isinstance(error, subprocess.CalledProcessError) and error.cmd[0] == 'docker':
            print('Local Docker failure: ' + str(error.stderr or '')[-1200:])
        # SDK/network exceptions can carry the synthetic JWT URL.
        raise SystemExit('Local SDK publication probe failed: ' + type(error).__name__) from None
