"""Serve the synthetic E2EE fixture on loopback with isolated worker headers."""
import argparse
import mimetypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from call_network_lab import asset_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--web-root', type=Path, required=True)
    parser.add_argument('--port', type=int, default=7394)
    args = parser.parse_args()
    root = args.web_root.resolve()
    if not 1024 <= args.port <= 65535 or not (root / 'main.dart.js').is_file():
        parser.error('Use an unprivileged port and a built fixture directory')

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = asset_path(root, self.path)
            status = 200 if path else 404
            if self.headers.get('Host') != f'127.0.0.1:{args.port}':
                status = 403
            data = path.read_bytes() if status == 200 else b'Not available'
            self.send_response(status)
            for key, value in {
                'Content-Type': (mimetypes.guess_type(path)[0] if path else None)
                                or 'application/octet-stream',
                'Content-Length': str(len(data)), 'Cache-Control': 'no-store',
                'Cross-Origin-Opener-Policy': 'same-origin',
                'Cross-Origin-Embedder-Policy': 'require-corp',
            }.items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(data)

    with ThreadingHTTPServer(('127.0.0.1', args.port), Handler) as server:
        print(f'http://127.0.0.1:{args.port}/index.html', flush=True)
        server.serve_forever()


if __name__ == '__main__':
    main()
