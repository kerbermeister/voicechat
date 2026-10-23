#!/usr/bin/env python3
"""Private control DB/API and Matrix fault proxy; never stops shared services."""
import json
import os
from pathlib import Path
import selectors
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from screen_status import status

ROOT = Path(__file__).resolve().parents[1]


def main():
    unavailable = threading.Event()

    class Proxy(BaseHTTPRequestHandler):
        def forward(self):
            if unavailable.is_set():
                self.send_response(503)
                body = b'{"errcode":"M_UNKNOWN","error":"Matrix fixture unavailable"}'
            else:
                size = int(self.headers.get('Content-Length', '0'))
                request = urllib.request.Request('http://127.0.0.1:8008'+self.path,
                    self.rfile.read(size) if size else None,
                    {k: self.headers[k] for k in ('Authorization', 'Content-Type') if k in self.headers},
                    method=self.command)
                try:
                    response = urllib.request.urlopen(request, timeout=5)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    self.send_response(response.code)
                    body = response.read()
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        do_GET = forward
        do_POST = forward

        def log_message(self, *_):
            pass

    proxy = ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
    threading.Thread(target=proxy.serve_forever, daemon=True).start()
    child = None
    with tempfile.TemporaryDirectory(prefix='voicechat-screen-fault-') as directory:
        root = Path(directory)
        for line in (ROOT/'infra/control.Dockerfile').read_text().splitlines():
            if line.startswith('COPY ') and '--from=' not in line:
                for name in shlex.split(line)[1:-1]:
                    target = root/name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(ROOT/name, target)
        (root/'.prototype').mkdir()
        flag = root/'.prototype/screen-enabled'
        flag.write_text('1')
        flag.chmod(0o600)
        env = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1',
               'VOICECHAT_SCREEN_FLAG': str(flag),
               'VOICECHAT_MATRIX_INTERNAL': f'http://127.0.0.1:{proxy.server_port}'}
        code = """
import json,sys
sys.path.insert(0,'prototype')
from token_server import Handler,screen_service
from http.server import ThreadingHTTPServer
screen_service()
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(json.dumps({'api_port':server.server_port}),flush=True)
server.serve_forever()
"""

        def stop():
            if child is not None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
                child.stdout.close()

        def start():
            nonlocal child
            child = subprocess.Popen([sys.executable, '-u', '-c', code], cwd=root,
                env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ)
                if not selector.select(timeout=12):
                    raise TimeoutError('Private control did not start')
            return json.loads(child.stdout.readline())

        try:
            ready = start()
            print(json.dumps(ready), flush=True)
            for line in sys.stdin:
                action = line.strip()
                if action == 'matrix_off':
                    unavailable.set()
                elif action == 'matrix_on':
                    unavailable.clear()
                elif action == 'restart':
                    stop()
                    ready = start()
                elif action == 'close':
                    break
                elif action != 'status':
                    raise ValueError('Unknown fixture action')
                print(json.dumps({**ready, **status(root/'.prototype/calls/calls.sqlite')}), flush=True)
        finally:
            stop()
            # Recover only this fixture's metadata, including after a failed browser test.
            subprocess.run([sys.executable, '-c',
                "import sys;sys.path.insert(0,'prototype');from token_server import screen_service;screen_service()"],
                cwd=root, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=True)
            proxy.shutdown()
            proxy.server_close()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit('Screen fault fixture failed: '+type(error).__name__) from None
