#!/usr/bin/env python3
"""Serve the built probe with SharedArrayBuffer headers required by vodozemac."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=7357)
parser.add_argument('--directory', type=Path, default=Path(__file__).resolve().parents[1] / 'apps/client/build/web')
options = parser.parse_args()
root = options.directory.resolve()
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs): super().__init__(*args, directory=str(root), **kwargs)
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()
    def log_message(self, *_): pass

print(f'Probe web: http://localhost:{options.port}', flush=True)
ThreadingHTTPServer(('127.0.0.1', options.port), Handler).serve_forever()
