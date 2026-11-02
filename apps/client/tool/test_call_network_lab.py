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

from call_network_lab import asset_path, require_local_docker


class AssetBoundaryTest(unittest.TestCase):
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
        with urlopen(origin + '/turn.json', timeout=5) as response:
            self.assertEqual(json.load(response)['profile'], config['profile'])


if __name__ == '__main__':
    unittest.main()
