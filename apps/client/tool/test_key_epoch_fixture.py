import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class KeyEpochServerTest(unittest.TestCase):
    def test_only_requested_loopback_host_and_build_assets_are_served(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = parent / 'web'
            root.mkdir()
            (root / 'main.dart.js').write_text('fixture')
            (root / 'index.html').write_text('synthetic test')
            outside = parent / 'private'
            outside.write_text('must not leave the build root')
            (root / 'link').symlink_to(outside)
            with socket.socket() as port_socket:
                port_socket.bind(('127.0.0.1', 0))
                port = port_socket.getsockname()[1]
            process = subprocess.Popen([
                sys.executable, str(Path(__file__).with_name('serve_key_epoch_fixture.py')),
                '--web-root', str(root), '--port', str(port),
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            origin = f'http://127.0.0.1:{port}'
            try:
                deadline = time.monotonic() + 5
                while True:
                    try:
                        with urlopen(origin + '/index.html?initial_slot=5', timeout=1) as reply:
                            self.assertEqual(reply.read(), b'synthetic test')
                            self.assertEqual(reply.headers['Cache-Control'], 'no-store')
                            self.assertEqual(reply.headers['Cross-Origin-Opener-Policy'], 'same-origin')
                            self.assertEqual(reply.headers['Cross-Origin-Embedder-Policy'], 'require-corp')
                        break
                    except URLError:
                        if process.poll() is not None or time.monotonic() >= deadline:
                            raise
                        time.sleep(.05)
                for path, headers, status in [
                    ('/index.html', {'Host': 'untrusted.invalid'}, 403),
                    ('/%2e%2e/private', {}, 404), ('/link', {}, 404), ('/%00', {}, 404),
                ]:
                    with self.subTest(path=path):
                        with self.assertRaises(HTTPError) as error:
                            urlopen(Request(origin + path, headers=headers), timeout=2)
                        self.assertEqual(error.exception.code, status)
            finally:
                process.terminate()
                process.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
