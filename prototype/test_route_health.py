import json
from pathlib import Path
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch
import urllib.request
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
from route_health import Readiness, HealthServer, upstream_ready


class RouteHealthTests(unittest.TestCase):
    def test_partial_readiness_cache_and_expiry(self):
        ready = Readiness('test', 'b', 'http://localhost:1', 'http://localhost:2')
        self.addCleanup(ready.close)
        with patch('route_health.upstream_ready', side_effect=lambda url, service: service == 'matrix') as check:
            with patch('route_health.time.monotonic', return_value=10):
                status, first = ready.snapshot()
                self.assertEqual(status, 503)
                self.assertEqual(first, {'schema': 1, 'service_id': 'test', 'edge_id': 'b', 'age_ms': 0, 'matrix': True, 'control': False})
            with patch('route_health.time.monotonic', return_value=11.5):
                self.assertEqual(ready.snapshot()[1]['age_ms'], 1500)
                self.assertEqual(check.call_count, 2)
            with patch('route_health.time.monotonic', return_value=12):
                ready.snapshot()
                self.assertEqual(check.call_count, 4)

    def test_real_http_rejects_redirect_bad_json_and_oversized_body(self):
        class Upstream(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                self.send_response(302 if self.path == '/redirect' else 200)
                self.send_header('Location', '/matrix')
                self.end_headers()
                self.wfile.write({'/matrix': b'{"versions":["v1.1"]}', '/control': b'{"ok":true}',
                                  '/large': b' ' * 5000, '/wrong': b'{"ok":1}'}.get(self.path, b'<html>login</html>'))
        with ThreadingHTTPServer(('127.0.0.1', 0), Upstream) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            try:
                base = 'http://127.0.0.1:' + str(server.server_port)
                self.assertTrue(upstream_ready(base + '/matrix', 'matrix'))
                self.assertTrue(upstream_ready(base + '/control', 'control'))
                for path in ('/redirect', '/large', '/wrong', '/portal'):
                    self.assertFalse(upstream_ready(base + path, 'control'))
            finally:
                server.shutdown(); thread.join()

    def test_public_response_is_small_uncached_and_does_not_expose_upstreams(self):
        ready = Readiness('test', 'c', 'http://localhost:1', 'http://localhost:2')
        self.addCleanup(ready.close)
        with patch('route_health.upstream_ready', return_value=True), HealthServer(('127.0.0.1', 0), ready) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            try:
                base = 'http://127.0.0.1:' + str(server.server_port)
                with urllib.request.urlopen(base + '/health/route') as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.headers['Cache-Control'], 'no-store')
                    body = response.read()
                    self.assertLess(len(body), 512)
                    self.assertNotIn(b'localhost', body)
                    self.assertTrue(json.loads(body)['control'])
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(base + '/health/route?upstream=other')
                self.assertEqual(error.exception.code, 404)
            finally:
                server.shutdown(); thread.join()
