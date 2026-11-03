"""Serve the renderer fixture with a disposable, loopback-only TURN/netem lab."""
import argparse
import base64
import hashlib
import hmac
import json
import math
import mimetypes
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'prototype'))
from check_route_turn import reserve_range
from check_three_vps import image

PROFILES = {
    'clean': ['delay', '0ms'],
    'delay': ['delay', '40ms'],
    'loss': ['loss', '2%'],
    'offline': ['loss', '100%'],
}


def media_payload_types(value):
    try:
        parts = value.split(',')
        types = [int(part) for part in parts]
        if (not 1 <= len(types) <= 4 or len(set(types)) != len(types) or
                any(str(number) != part or not 96 <= number <= 127
                    for number, part in zip(types, parts))):
            raise ValueError()
        return types
    except ValueError:
        raise argparse.ArgumentTypeError('Use 1–4 distinct dynamic RTP payload types (96–127)')


def directional_filters(direction, payload_types):
    base = ['filter', 'add', 'dev', 'eth0', 'protocol', 'ip', 'parent', '1:',
            'prio', '1', 'u32', 'match', 'ip', 'protocol', '17', '0xff',
            'match', 'ip', 'sport', '3478' if direction == 'incoming' else '3480', '0xffff']
    if not payload_types:
        return [[*base, 'flowid', '1:2']]
    # IPv4 (no options), UDP, TURN ChannelData (RFC 8656 §12.4), RTP v2.
    # The RTP marker bit is independent of payload type. RTCP/STUN stay clean.
    return [[*base, 'match', 'u8', '0x45', '0xff', 'at', '0',
             'match', 'u8', '0x40', '0xc0', 'at', '28',
             'match', 'u8', '0x80', '0xc0', 'at', '32',
             'match', 'u8', hex(payload), '0x7f', 'at', '33', 'flowid', '1:2']
            for payload in payload_types]


def valid_marker_result(data, duration):
    """Only synthetic timing evidence may leave the browser; no media/credentials."""
    fields = {'schema', 'outcome', 'control', 'duration_seconds', 'markers', 'unmatched_markers',
              'invalid_video_frames', 'baseline_p95_abs_ms', 'recovered_p95_abs_ms', 'phase_changes',
              'audio_base_latency_ms', 'audio_output_latency_ms', 'max_video_callback_lateness_ms',
              'physical_lip_sync_measured', 'media_saved', 'microphone_used', 'test_sink_silent'}
    schema = data.get('schema')
    if schema == 2:
        fields |= {'rtp_diagnostics_requested', 'rtp_diagnostics', 'rtp_diagnostics_errors'}
        if 'playout_path' in data:
            fields.add('playout_path')
            if data['playout_path'] not in ('product_gain', 'element_source_baseline'):
                return False
    if (set(data) != fields or type(schema) is not int or schema not in (1, 2) or
            type(data['duration_seconds']) is not int or data['duration_seconds'] != duration or
            data['outcome'] not in ('pass', 'budget_exceeded', 'insufficient_markers', 'setup_failed') or
            data['control'] not in ('none', 'audio200', 'video200') or
            any(data[key] is not False for key in ('physical_lip_sync_measured', 'media_saved', 'microphone_used')) or
            data['test_sink_silent'] is not True):
        return False
    def number(value):
        return type(value) in (int, float) and abs(value) <= 1e12 and math.isfinite(value)
    if schema == 2:
        rows = data['rtp_diagnostics']
        requested = data['rtp_diagnostics_requested']
        errors = data['rtp_diagnostics_errors']
        if (type(requested) is not bool or not isinstance(rows, list) or len(rows) > 150 or
                type(errors) is not int or not 0 <= errors <= 150 or
                (requested and duration > 300) or (not requested and (rows or errors))):
            return False
        seen_rtp = set()
        for row in rows:
            if (not isinstance(row, list) or len(row) not in (8, 9) or type(row[0]) is not int or
                    not 0 <= row[0] < math.ceil(duration / 2) or row[0] in seen_rtp or
                    not number(row[1]) or row[1] < 0 or not number(row[2]) or row[2] < 0 or
                    row[7] not in (None, 'none', 'cpu', 'bandwidth', 'other') or
                    (len(row) == 9 and (not number(row[8]) or abs(row[8]) > 80))):
                return False
            for counters, size in zip(row[3:7], (14, 14, 6, 2)):
                if (not isinstance(counters, list) or len(counters) != size or
                        any(value is not None and not number(value) for value in counters)):
                    return False
            seen_rtp.add(row[0])
    if any(type(data[key]) is not int or not 0 <= data[key] <= 1000000
           for key in ('unmatched_markers', 'invalid_video_frames')):
        return False
    if any(data[key] is not None and (not number(data[key]) or data[key] < 0)
           for key in ('baseline_p95_abs_ms', 'recovered_p95_abs_ms',
                       'audio_base_latency_ms', 'audio_output_latency_ms', 'max_video_callback_lateness_ms')):
        return False
    markers = data['markers']
    if not isinstance(markers, list) or len(markers) > 2000:
        return False
    seen = set()
    for row in markers:
        # id, profile, offset, audio output, video display, source time, gain.
        if (not isinstance(row, list) or len(row) != 7 or type(row[0]) is not int or
                not 0 <= row[0] < math.ceil(duration / 2) or row[0] in seen or
                not isinstance(row[1], str) or row[1] not in PROFILES or
                not all(number(value) for value in row[2:]) or not 0 <= row[6] <= 3):
            return False
        seen.add(row[0])
    if schema == 2 and not seen_rtp <= seen:
        return False
    phases = data['phase_changes']
    if (not isinstance(phases, list) or len(phases) > 10 or any(
            not isinstance(row, list) or len(row) != 2 or not isinstance(row[0], str) or
            row[0] not in PROFILES or not number(row[1]) or row[1] < 0 for row in phases)):
        return False
    if data['outcome'] == 'pass' and (len(markers) < 10 or any(
            data[key] is None or data[key] > 80
            for key in ('baseline_p95_abs_ms', 'recovered_p95_abs_ms'))):
        return False
    return True


def asset_path(root, request_path):
    try:
        path = (root / unquote(urlsplit(request_path).path).lstrip('/')).resolve()
        return path if path.is_relative_to(root) and path.is_file() else None
    except (ValueError, OSError):
        return None


def require_local_docker():
    context = subprocess.check_output(['docker', 'context', 'inspect'], text=True)
    endpoint = json.loads(context)[0]['Endpoints']['docker']['Host']
    if not endpoint.startswith('unix://'):
        raise ValueError('A local Unix-socket Docker context is required')
    if any(os.environ.get(key) for key in ('DOCKER_HOST', 'DOCKER_CONTEXT')):
        raise ValueError('Unset Docker endpoint overrides; select the local context explicitly')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--web-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--netem-image', default='voicechat-network-probe:fixture')
    parser.add_argument('--port', type=int, default=7390)
    parser.add_argument('--transport', choices=('udp', 'tcp'), default='udp')
    parser.add_argument('--direction', choices=('both', 'incoming', 'outgoing'), default='both')
    parser.add_argument('--marker-seconds', type=int, help='Run synthetic A/V playout markers for 60–3600 seconds')
    parser.add_argument('--clean-only', action='store_true', help='A/V control without network impairment')
    media = parser.add_mutually_exclusive_group()
    media.add_argument('--video-payload-types', type=media_payload_types,
                       help='Video-only UDP/TURN marker impairment, e.g. 96,97 (VP8 and RTX)')
    media.add_argument('--audio-payload-types', type=media_payload_types,
                       help='Audio-only UDP/TURN marker impairment, e.g. 111 (Opus)')
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error('Use an unprivileged port')
    if args.direction != 'both' and args.transport != 'udp':
        parser.error('Directional feedback checks currently require UDP')
    marker = args.marker_seconds is not None
    payload_types = args.video_payload_types or args.audio_payload_types
    impaired_media = 'video' if args.video_payload_types else 'audio' if args.audio_payload_types else None
    if payload_types and (not marker or args.direction != 'outgoing' or
                          not 90 <= args.marker_seconds <= 300):
        parser.error('Single-stream impairment requires 90–300 second A/V markers and direction outgoing')
    if args.clean_only and not marker:
        parser.error('--clean-only requires A/V markers')
    if marker and (not 60 <= args.marker_seconds <= 3600 or
                   (args.direction != 'both' and not payload_types)):
        parser.error('A/V markers require 60–3600 seconds and direction both')
    lifetime = args.marker_seconds + 120 if marker else 900
    directional = args.direction != 'both'
    profiles = {**PROFILES, 'loss': ['loss', '15%' if directional else '2%']}
    if payload_types:
        profiles.update(delay=['delay', '150ms'], loss=['loss', '2%'])
    if args.clean_only:
        profiles = {name: ['delay', '0ms'] for name in PROFILES}
    web_root = args.web_root.resolve()
    required = 'call_av_marker_fixture.html' if marker else 'main.dart.js'
    if not (web_root / required).is_file():
        parser.error('Prepare the selected browser fixture first')
    marker_sources = ('call_av_marker_fixture.html', 'call_av_marker_fixture.js',
                      'call_av_marker.js', 'call_av_marker_worklet.js',
                      'call_transport_diagnostics.js', 'call_media_scope.js', 'media_audio.js')
    if marker and any(asset_path(web_root, '/' + name) is None for name in marker_sources):
        parser.error('Prepare all A/V marker assets first')
    fixture_hashes = ({name: hashlib.sha256((web_root / name).read_bytes()).hexdigest()
                       for name in marker_sources} if marker else {})
    fixture_hashes['lab_server'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    # No implicit remote Docker target: namespace capabilities belong only to this lab.
    try:
        require_local_docker()
    except ValueError as error:
        parser.error(str(error))
    project = 'voicechat-call-net-' + uuid.uuid4().hex[:10]
    origin = f'http://127.0.0.1:{args.port}'
    nonce = secrets.token_hex(24)
    secret = secrets.token_hex(32)
    first, sockets = reserve_range()
    other_first = None
    if directional:
        other_first, other_sockets = reserve_range()
        sockets.extend(other_sockets)
    with tempfile.TemporaryDirectory(prefix=project) as temporary:
        folder = Path(temporary)
        folder.chmod(0o700)
        config = '\n'.join([
            'listening-port=3478', 'fingerprint', 'use-auth-secret',
            'static-auth-secret=' + secret, 'realm=call-network-lab',
            f'min-port={first}', f'max-port={first + 7}', 'cli=off',
            'no-tls', 'no-dtls', 'no-multicast-peers', 'allow-loopback-peers',
            'external-ip=127.0.0.1', 'user-quota=8', 'total-quota=16',
            'log-file=stdout',
        ]) + '\n'
        if directional:
            # Both peers' advertised relay addresses are loopback in this shared
            # namespace; bind allocations there instead of inferring the NIC.
            config += 'relay-ip=127.0.0.1\n'
        (folder / 'turn.conf').write_text(config)
        (folder / 'turn.conf').chmod(0o600)
        if directional:
            other_config = config.replace('listening-port=3478', 'listening-port=3480')
            other_config = other_config.replace(f'min-port={first}', f'min-port={other_first}')
            other_config = other_config.replace(f'max-port={first + 7}', f'max-port={other_first + 7}')
            (folder / 'other.conf').write_text(other_config)
            (folder / 'other.conf').chmod(0o600)
        services = {
            'turn': {
                'image': image('turn'), 'command': ['-c', '/turn.conf'],
                'volumes': ['./turn.conf:/turn.conf:ro'],
                'ports': ['127.0.0.1::3478/tcp', '127.0.0.1::3478/udp'] + [
                    f'127.0.0.1:{p}:{p}/udp' for p in range(first, first + 8)
                ],
                'mem_limit': '128m', 'cpus': .5,
            },
            'netem': {
                'image': args.netem_image, 'entrypoint': ['/bin/sh', '-c'],
                'command': ['sleep infinity'], 'network_mode': 'service:turn',
                'cap_add': ['NET_ADMIN'], 'read_only': True, 'mem_limit': '64m',
            },
        }
        if directional:
            services['turn']['ports'].extend([
                '127.0.0.1::3480/tcp', '127.0.0.1::3480/udp',
                *[f'127.0.0.1:{p}:{p}/udp' for p in range(other_first, other_first + 8)],
            ])
            services['other'] = {
                'image': image('turn'), 'command': ['-c', '/other.conf'],
                'volumes': ['./other.conf:/other.conf:ro'],
                'network_mode': 'service:turn', 'mem_limit': '128m', 'cpus': .5,
            }
        compose = folder / 'compose.json'
        compose.write_text(json.dumps({'name': project, 'services': services}))
        command = ['docker', 'compose', '-f', str(compose)]
        current = 'clean'
        qdiscs = []
        lock = threading.Lock()

        def profile(name):
            nonlocal current
            if name not in profiles:
                raise ValueError('Unknown profile')
            with lock:
                for device in (('eth0',) if directional else ('lo', 'eth0')):
                    placement = ['parent', '1:2', 'handle', '30:'] if directional else ['root']
                    subprocess.run([
                        *command, 'exec', '-T', 'netem', 'tc', 'qdisc', 'replace',
                        'dev', device, *placement, 'netem', *profiles[name],
                    ], check=True, capture_output=True, timeout=10)
                current = name

        server = None
        expiry = None
        try:
            for item in sockets:
                item.close()
            subprocess.run([*command, 'up', '-d', '--wait', '--wait-timeout', '45'],
                           check=True, timeout=60)
            address = subprocess.check_output(
                [*command, 'port', '--protocol', args.transport, 'turn', '3478'],
                text=True).strip()
            if not address.startswith('127.0.0.1:'):
                raise ValueError('TURN must bind loopback')
            other_address = None
            if directional:
                other_address = subprocess.check_output([
                    *command, 'port', '--protocol', 'udp', 'turn', '3480',
                ], text=True).strip()
                if not other_address.startswith('127.0.0.1:'):
                    raise ValueError('TURN must bind loopback')
                tc = [*command, 'exec', '-T', 'netem', 'tc']
                subprocess.run([
                    *tc, 'qdisc', 'replace', 'dev', 'eth0', 'root', 'handle', '1:',
                    'prio', 'bands', '2', 'priomap', *(['0'] * 16),
                ], check=True, capture_output=True, timeout=10)
                # Only listener responses to one peer enter netem; relay hairpin stays clean.
                for filter_args in directional_filters(args.direction, payload_types):
                    subprocess.run([*tc, *filter_args], check=True, capture_output=True, timeout=10)
            username = f'{int(time.time()) + lifetime}:call-lab'
            password = base64.b64encode(hmac.digest(
                secret.encode(), username.encode(), hashlib.sha1)).decode()
            profile('clean')

            class Handler(BaseHTTPRequestHandler):
                def reply(self, status, data, mime='application/json'):
                    body = data if isinstance(data, bytes) else json.dumps(data).encode()
                    self.send_response(status)
                    for key, value in {
                        'Content-Type': mime, 'Content-Length': str(len(body)),
                        'Cache-Control': 'no-store',
                        'Cross-Origin-Opener-Policy': 'same-origin',
                        'Cross-Origin-Embedder-Policy': 'require-corp',
                    }.items():
                        self.send_header(key, value)
                    self.end_headers()
                    self.wfile.write(body)

                def valid_host(self):
                    return self.headers.get('Host') == f'127.0.0.1:{args.port}'

                def do_GET(self):
                    if not self.valid_host():
                        return self.reply(403, {'error': 'forbidden'})
                    if self.path == '/turn.json':
                        return self.reply(200, {
                            'iceTransportPolicy': 'relay',
                            'iceServers': [{'urls': f'turn:{address}?transport={args.transport}',
                                            'username': username, 'credential': password}],
                            'direction': args.direction,
                            **({'peer_ice_servers': [{
                                'urls': f'turn:{other_address}?transport=udp',
                                'username': username, 'credential': password,
                            }]} if directional else {}),
                            'lab_key': nonce, 'profile': current,
                            **({'marker_seconds': args.marker_seconds,
                                'network_clean_only': args.clean_only,
                                'media_payload_types': payload_types,
                                'impaired_media': impaired_media} if marker else {}),
                        })
                    path = asset_path(web_root, self.path)
                    if path is None:
                        return self.reply(404, {'error': 'not_found'})
                    return self.reply(200, path.read_bytes(),
                                      mimetypes.guess_type(path)[0] or 'application/octet-stream')

                def do_POST(self):
                    if (not self.valid_host() or self.headers.get('Origin') != origin or
                            self.headers.get('X-Lab-Key') != nonce):
                        return self.reply(403, {'error': 'forbidden'})
                    try:
                        size = int(self.headers.get('Content-Length', '0'))
                        if not 0 < size <= 500000:
                            return self.reply(400, {'error': 'invalid_size'})
                        data = json.loads(self.rfile.read(size))
                        if not isinstance(data, dict):
                            return self.reply(400, {'error': 'invalid_request'})
                        if self.path == '/profile':
                            if (not isinstance(data.get('profile'), str) or
                                    data['profile'] not in profiles):
                                return self.reply(400, {'error': 'unknown_profile'})
                            qdiscs.append({'profile': current, **{
                                device: subprocess.check_output([
                                    *command, 'exec', '-T', 'netem', 'tc', '-s',
                                    'qdisc', 'show', 'dev', device,
                                ], text=True, timeout=10)
                                for device in ('lo', 'eth0')
                            }})
                            if payload_types:
                                qdiscs[-1]['filters'] = subprocess.check_output([
                                    *command, 'exec', '-T', 'netem', 'tc', '-s',
                                    'filter', 'show', 'dev', 'eth0', 'parent', '1:',
                                ], text=True, timeout=10)
                            profile(data['profile'])
                            return self.reply(200, {'profile': current})
                        if self.path == '/result':
                            samples = data.get('samples')
                            if (data.get('rtp_recovered') is not True or not isinstance(samples, list)
                                    or len(samples) != (42 if directional else 51)):
                                return self.reply(400, {'error': 'invalid_result'})
                            args.output.parent.mkdir(parents=True, exist_ok=True)
                            args.output.write_text(json.dumps({
                                'synthetic_media': True, 'physical_lip_sync_measured': False,
                                'transport': 'TURN ' + args.transport.upper(),
                                'namespace_only': True,
                                'direction': args.direction,
                                'profiles': profiles, 'qdiscs': qdiscs, 'result': data,
                            }, indent=2) + '\n')
                            return self.reply(200, {'saved': True})
                        if self.path == '/marker-result':
                            if not marker or not valid_marker_result(data, args.marker_seconds):
                                return self.reply(400, {'error': 'invalid_result'})
                            args.output.parent.mkdir(parents=True, exist_ok=True)
                            args.output.write_text(json.dumps({
                                'synthetic_media': True, 'physical_lip_sync_measured': False,
                                'transport': 'TURN ' + args.transport.upper(), 'namespace_only': True,
                                'fixture_sha256': fixture_hashes,
                                'direction': args.direction,
                                'media_payload_types': payload_types,
                                'impaired_media': impaired_media,
                                'profiles': profiles, 'qdiscs': qdiscs, 'result': data,
                            }, indent=2) + '\n')
                            return self.reply(200, {'saved': True})
                        return self.reply(404, {'error': 'not_found'})
                    except (ValueError, KeyError):
                        return self.reply(400, {'error': 'invalid_request'})
                    except (subprocess.SubprocessError, OSError):
                        return self.reply(500, {'error': 'fixture_operation_failed'})

            server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
            expiry = threading.Timer(lifetime, server.shutdown)
            expiry.daemon = True
            expiry.start()
            print(json.dumps({'ready': True, 'project': project,
                              'compose': str(compose),
                              'url': origin + ('/call_av_marker_fixture.html' if marker else '/index.html?network_lab=1')}), flush=True)
            server.serve_forever()
        finally:
            if expiry:
                expiry.cancel()
            if server:
                server.server_close()
            for item in sockets:
                item.close()
            subprocess.run([*command, 'down', '--volumes', '--remove-orphans'],
                           check=True, timeout=60)


if __name__ == '__main__':
    main()
