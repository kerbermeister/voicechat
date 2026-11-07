import argparse
import tempfile
import subprocess
import sys
import unittest
import os
import json
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
from unittest.mock import patch

from call_network_lab import (asset_path, require_local_docker, valid_marker_result,
                              media_payload_types, directional_filters)


class AssetBoundaryTest(unittest.TestCase):
    def test_startup_grace_rejected_before_starting_docker(self):
        for grace in ('-1', '1801'):
            result = subprocess.run([
                sys.executable, str(Path(__file__).with_name('call_network_lab.py')),
                '--web-root', '/unused', '--output', '/unused',
                '--setup-grace-seconds', grace,
            ], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertIn('Setup grace must', result.stderr)

    def test_delay_pause_control_requires_single_stream_scope(self):
        result = subprocess.run([
            sys.executable, str(Path(__file__).with_name('call_network_lab.py')),
            '--web-root', '/unused', '--output', '/unused', '--delay-then-pause',
        ], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn('--delay-then-pause requires', result.stderr)

    def test_video_classifier_requires_canonical_distinct_dynamic_types(self):
        self.assertEqual(media_payload_types('96,97'), [96, 97])
        for value in ('', '95', '128', '96,96', '096', '96, 97', '96,',
                      '96,97,98,99,100', 'private'):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                media_payload_types(value)

    def test_video_classifier_excludes_marker_bit_and_other_turn_packets(self):
        filters = directional_filters('outgoing', [96, 97])
        self.assertEqual(len(filters), 2)
        for payload, command in zip([96, 97], filters):
            text = ' '.join(command)
            self.assertIn('sport 3480 0xffff', text)
            self.assertIn('u8 0x45 0xff at 0', text)
            self.assertIn('u8 0x40 0xc0 at 28', text)
            self.assertIn('u8 0x80 0xc0 at 32', text)
            self.assertIn(f'u8 {hex(payload)} 0x7f at 33', text)
        self.assertNotIn('at 33', ' '.join(directional_filters('incoming', None)[0]))

    def test_single_stream_scope_is_bounded_and_requires_directional_markers(self):
        for option, payload in (('--video-payload-types', '96,97'), ('--audio-payload-types', '111')):
            for extra in ([], ['--marker-seconds', '60', '--direction', 'outgoing'],
                          ['--marker-seconds', '120'],
                          ['--marker-seconds', '301', '--direction', 'outgoing']):
                with self.subTest(option=option, extra=extra):
                    result = subprocess.run([
                        sys.executable, str(Path(__file__).with_name('call_network_lab.py')),
                        '--web-root', '/unused', '--output', '/unused', option, payload, *extra,
                    ], capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn('Single-stream impairment requires', result.stderr)

    def test_clean_network_control_requires_markers_before_docker(self):
        result = subprocess.run([
            sys.executable, str(Path(__file__).with_name('call_network_lab.py')),
            '--web-root', '/unused', '--output', '/unused', '--clean-only',
        ], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn('--clean-only requires A/V markers', result.stderr)

    def test_missing_marker_modules_rejected_before_docker(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'call_av_marker_fixture.html').write_text('fixture')
            result = subprocess.run([
                sys.executable, str(Path(__file__).with_name('call_network_lab.py')),
                '--web-root', str(root), '--output', str(root / 'result.json'),
                '--marker-seconds', '60',
            ], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertIn('Prepare all A/V marker assets first', result.stderr)

    def test_marker_duration_and_direction_rejected_before_docker(self):
        for extra in (['--marker-seconds', '59'], ['--marker-seconds', '3601'],
                      ['--marker-seconds', '60', '--direction', 'outgoing']):
            with self.subTest(extra=extra):
                result = subprocess.run([
                    sys.executable, str(Path(__file__).with_name('call_network_lab.py')),
                    '--web-root', '/unused', '--output', '/unused', *extra,
                ], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 2)
                self.assertIn('A/V markers require', result.stderr)

    def test_remote_docker_and_endpoint_overrides_are_rejected(self):
        def context(host):
            return json.dumps([{'Endpoints': {'docker': {'Host': host}}}])
        with patch.dict(os.environ, {}, clear=True):
            with patch('call_network_lab.subprocess.check_output',
                       return_value=context('unix:///local/docker.sock')):
                require_local_docker()
                with patch.dict(os.environ, {'DOCKER_HOST': 'tcp://remote:2375'}):
                    with self.assertRaises(ValueError):
                        require_local_docker()
            with patch('call_network_lab.subprocess.check_output',
                       return_value=context('ssh://remote')):
                with self.assertRaises(ValueError):
                    require_local_docker()

    def test_audio_and_video_scope_cannot_be_combined(self):
        result = subprocess.run([
            sys.executable, str(Path(__file__).with_name('call_network_lab.py')),
            '--web-root', '/unused', '--output', '/unused',
            '--video-payload-types', '96,97', '--audio-payload-types', '111',
        ], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn('not allowed with argument', result.stderr)

    def test_directional_tcp_is_rejected_before_creating_a_lab(self):
        result = subprocess.run([
            sys.executable, str(Path(__file__).with_name('call_network_lab.py')),
            '--web-root', '/unused', '--output', '/unused',
            '--direction', 'outgoing', '--transport', 'tcp',
        ], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn('Directional feedback checks currently require UDP', result.stderr)

    def test_queries_work_but_traversal_and_symlinks_cannot_escape(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            root = parent / 'web'
            root.mkdir()
            page = root / 'index.html'
            page.write_text('fixture')
            outside = parent / 'secret'
            outside.write_text('must not be served')
            (root / 'link').symlink_to(outside)
            self.assertEqual(asset_path(root, '/index.html?network_lab=1'), page)
            for path in ('/../secret', '/%2e%2e/secret', '/link', '/%00', '/missing'):
                with self.subTest(path=path):
                    self.assertIsNone(asset_path(root, path))


class MarkerResultTest(unittest.TestCase):
    def result(self):
        return {'schema': 1, 'outcome': 'pass', 'control': 'none', 'duration_seconds': 60,
                'markers': [[i, 'clean', -20, 1000 + i * 2000, 1020 + i * 2000, i * 2000, 1]
                            for i in range(10)],
                'unmatched_markers': 0, 'invalid_video_frames': 0,
                'baseline_p95_abs_ms': 20, 'recovered_p95_abs_ms': 20, 'phase_changes': [['clean', 0]],
                'audio_base_latency_ms': 10, 'audio_output_latency_ms': None, 'max_video_callback_lateness_ms': 0,
                'physical_lip_sync_measured': False, 'media_saved': False,
                'microphone_used': False, 'test_sink_silent': True}

    def test_only_bounded_synthetic_measurements_are_accepted(self):
        self.assertTrue(valid_marker_result(self.result(), 60))
        for field, value in [('token', 'private'), ('media_saved', True),
                             ('duration_seconds', 3600), ('unmatched_markers', True),
                             ('control', 'untrusted'), ('phase_changes', [['clean', True]]),
                             ('audio_base_latency_ms', -1), ('audio_output_latency_ms', float('inf')),
                             ('audio_base_latency_ms', 10 ** 1000),
                             ('baseline_p95_abs_ms', float('nan')),
                             ('recovered_p95_abs_ms', 81), ('test_sink_silent', False)]:
            with self.subTest(field=field):
                data = self.result(); data[field] = value
                self.assertFalse(valid_marker_result(data, 60))

    def test_invalid_or_duplicate_marker_rows_are_rejected(self):
        for row in [[0, 'clean', 0], [True, 'clean', 0, 1, 2, 3, 1],
                    [30, 'clean', 0, 1, 2, 3, 1], [1, 'private', 0, 1, 2, 3, 1],
                    [1, 'clean', float('inf'), 1, 2, 3, 1], [1, 'clean', 0, 1, 2, 3, 4]]:
            with self.subTest(row=row):
                data = self.result(); data['markers'][0] = row
                self.assertFalse(valid_marker_result(data, 60))
        data = self.result(); data['markers'][1] = data['markers'][0]
        self.assertFalse(valid_marker_result(data, 60))

    def diagnostics(self):
        data = self.result()
        data.update(schema=2, rtp_diagnostics_requested=True, rtp_diagnostics_errors=0,
                    rtp_diagnostics=[[0, 1000, 2, [0] * 14, [0] * 14, [0] * 6, [None, 1000000], 'none']])
        return data

    def test_rtp_diagnostics_accept_only_bounded_counter_arrays(self):
        self.assertTrue(valid_marker_result(self.diagnostics(), 60))
        for field, value in [('rtp_diagnostics_requested', 1), ('rtp_diagnostics_requested', False),
                             ('rtp_diagnostics_errors', True), ('rtp_diagnostics_errors', 151),
                             ('rtp_diagnostics', self.diagnostics()['rtp_diagnostics'] * 151)]:
            with self.subTest(field=field):
                data = self.diagnostics(); data[field] = value
                self.assertFalse(valid_marker_result(data, 60))
        data = self.diagnostics(); data['duration_seconds'] = 3600
        self.assertFalse(valid_marker_result(data, 3600))
        data = self.diagnostics(); data['rtp_diagnostics'].append(data['rtp_diagnostics'][0])
        self.assertFalse(valid_marker_result(data, 60))

    def test_rtp_diagnostics_reject_identity_media_and_nonfinite_fields(self):
        for index, value in [(0, True), (0, 30), (0, 29), (1, -1), (2, float('inf')),
                             (3, ['private'] * 14), (4, [float('nan')] * 14),
                             (5, [0] * 7), (6, [True, 0]), (7, 'private')]:
            with self.subTest(index=index):
                data = self.diagnostics(); data['rtp_diagnostics'][0][index] = value
                self.assertFalse(valid_marker_result(data, 60))
        data = self.diagnostics(); data['device_id'] = 'private'
        self.assertFalse(valid_marker_result(data, 60))

    def test_playout_comparison_is_explicit_and_has_no_arbitrary_metadata(self):
        for path in ('product_gain', 'element_source_baseline'):
            data = self.diagnostics(); data['playout_path'] = path
            self.assertTrue(valid_marker_result(data, 60))
        for path in ('private', None, True, {}):
            data = self.diagnostics(); data['playout_path'] = path
            self.assertFalse(valid_marker_result(data, 60))
        data = self.result(); data['playout_path'] = 'product_gain'
        self.assertFalse(valid_marker_result(data, 60))

    def test_optional_video_stamp_distance_stays_inside_the_matching_budget(self):
        for value in (-80, 12.5, 80):
            data = self.diagnostics(); data['rtp_diagnostics'][0].append(value)
            self.assertTrue(valid_marker_result(data, 60))
        for value in (81, -81, True, float('nan'), 'private'):
            data = self.diagnostics(); data['rtp_diagnostics'][0].append(value)
            self.assertFalse(valid_marker_result(data, 60))

    def test_schema2_without_diagnostics_keeps_the_standard_marker_path(self):
        data = self.diagnostics()
        data.update(rtp_diagnostics_requested=False, rtp_diagnostics=[], rtp_diagnostics_errors=0)
        self.assertTrue(valid_marker_result(data, 60))
        data['schema'] = 3
        self.assertFalse(valid_marker_result(data, 60))

    def test_failed_measurement_can_be_saved_without_claiming_pass(self):
        data = self.result(); data['outcome'] = 'insufficient_markers'; data['markers'] = []
        data['baseline_p95_abs_ms'] = None; data['recovered_p95_abs_ms'] = None
        self.assertTrue(valid_marker_result(data, 60))
        data['outcome'] = 'pass'
        self.assertFalse(valid_marker_result(data, 60))


@unittest.skipUnless(os.environ.get('CALL_NETWORK_LAB_ORIGIN'), 'Local lab not running')
class LiveApiBoundaryTest(unittest.TestCase):
    def test_invalid_requests_do_not_change_network_profile(self):
        origin = os.environ['CALL_NETWORK_LAB_ORIGIN']
        parsed = urlsplit(origin)
        self.assertEqual(parsed.scheme, 'http')
        self.assertEqual(parsed.hostname, '127.0.0.1')
        self.assertIsNone(parsed.username)
        self.assertIsNone(parsed.password)
        self.assertEqual(parsed.path, '')
        self.assertFalse(parsed.query or parsed.fragment)
        with urlopen(origin + '/turn.json', timeout=5) as response:
            config = json.load(response)

        self.assertIn(config['direction'], ('both', 'incoming', 'outgoing'))
        if config['direction'] != 'both':
            primary = config['iceServers'][0]['urls']
            secondary = config['peer_ice_servers'][0]['urls']
            self.assertNotEqual(primary, secondary)
            for url in (primary, secondary):
                self.assertTrue(url.startswith('turn:127.0.0.1:'))
                self.assertTrue(url.endswith('?transport=udp'))

        def status(path, headers=None, body=None):
            try:
                with urlopen(Request(origin + path, headers=headers or {}, data=body),
                             timeout=5) as response:
                    return response.status
            except HTTPError as error:
                return error.code

        self.assertEqual(status('/turn.json', {'Host': 'untrusted.invalid'}), 403)
        self.assertEqual(status('/%2e%2e/AGENTS.md'), 404)
        headers = {'Origin': origin, 'Content-Type': 'application/json'}
        self.assertEqual(status('/profile', headers, b'{"profile":"offline"}'), 403)
        headers['X-Lab-Key'] = config['lab_key']
        self.assertEqual(status('/profile', {**headers, 'Origin': 'https://untrusted.invalid'},
                                b'{"profile":"offline"}'), 403)
        for body in (b'[]', b'{"profile":[]}', b'{"profile":"unsupported"}', b'bad-json'):
            with self.subTest(body=body):
                self.assertEqual(status('/profile', headers, body), 400)
        self.assertEqual(status('/profile', headers, b'x' * 500001), 400)
        for body in (b'{}', b'{"rtp_recovered":true,"samples":[]}'):
            self.assertEqual(status('/result', headers, body), 400)
        for body in (b'{}', b'{"token":"must-not-be-stored"}'):
            with self.subTest(marker_body=body):
                self.assertEqual(status('/marker-result', headers, body), 400)
        if config.get('marker_seconds', 301) <= 300:
            invalid = MarkerResultTest().diagnostics()
            invalid['duration_seconds'] = config['marker_seconds']
            invalid['rtp_diagnostics'][0].append(81)
            self.assertEqual(status('/marker-result', headers, json.dumps(invalid).encode()), 400)
        with urlopen(origin + '/turn.json', timeout=5) as response:
            self.assertEqual(json.load(response)['profile'], config['profile'])


if __name__ == '__main__':
    unittest.main()
