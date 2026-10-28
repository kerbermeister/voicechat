"""Edge readiness of fixed Matrix/control upstreams, never media readiness."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def upstream_ready(url, service):
    try:
        request = urllib.request.Request(url, headers={'Accept': 'application/json'})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(request, timeout=0.8) as response:
            if response.status != 200:
                return False
            raw = response.read(4097)
            if len(raw) > 4096:
                return False
            data = json.loads(raw)
        if not isinstance(data, dict):
            return False
        if service == 'matrix':
            return isinstance(data.get('versions'), list) and bool(data['versions']) and all(isinstance(v, str) for v in data['versions'])
        return data.get('ok') is True
    except (OSError, ValueError, urllib.error.URLError):
        return False


class Readiness:
    def __init__(self, service_id, edge_id, matrix_url, control_url):
        for url in (matrix_url, control_url):
            parsed = urlsplit(url)
            if (parsed.scheme not in ('http', 'https') or not parsed.hostname or
                parsed.username or parsed.password or parsed.path not in ('', '/') or
                parsed.query or parsed.fragment):
                raise ValueError('Fixed upstream origin required')
        self.service_id, self.edge_id = service_id, edge_id
        self.urls = {'matrix': matrix_url.rstrip('/') + '/_matrix/client/versions',
                     'control': control_url.rstrip('/') + '/health'}
        self.lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=2)
        self.checked = None
        self.services = {}

    def snapshot(self):
        # One refresh at a time, even when many clients probe together.
        with self.lock:
            now = time.monotonic()
            if self.checked is None or now - self.checked >= 2:
                futures = {key: self.pool.submit(upstream_ready, url, key)
                           for key, url in self.urls.items()}
                self.services = {key: future.result() for key, future in futures.items()}
                self.checked = time.monotonic()
            age = int((time.monotonic() - self.checked) * 1000)
            return (200 if all(self.services.values()) else 503), {
                'schema': 1, 'service_id': self.service_id, 'edge_id': self.edge_id,
                'age_ms': age, **self.services,
            }

    def close(self):
        self.pool.shutdown(wait=True, cancel_futures=True)


class HealthServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, readiness):
        self.readiness = readiness
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(address, Handler)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(3)

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path != '/health/route':
            self.send_error(404)
            return
        status, value = self.server.readiness.snapshot()
        body = json.dumps(value, separators=(',', ':')).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--service-id', required=True)
    parser.add_argument('--edge-id', required=True)
    parser.add_argument('--matrix-url', required=True)
    parser.add_argument('--control-url', required=True)
    parser.add_argument('--bind', default='0.0.0.0')
    parser.add_argument('--port', type=int, default=8091)
    args = parser.parse_args()
    readiness = Readiness(args.service_id, args.edge_id, args.matrix_url, args.control_url)
    try:
        with HealthServer((args.bind, args.port), readiness) as server:
            server.serve_forever()
    finally:
        readiness.close()


if __name__ == '__main__':
    main()
