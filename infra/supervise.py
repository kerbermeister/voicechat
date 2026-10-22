"""SFU and control share one lifecycle: a dead/unhealthy controller must cut media."""
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.request


def stop(children):
    for child in children:
        if child.poll() is None: child.terminate()
    for child in children:
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def run(commands, healthy, deadline=5):
    stopping = threading.Event()
    def terminate(*_): stopping.set()
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    children = []
    failed_since = time.monotonic()
    try:
        for command in commands: children.append(subprocess.Popen(command))
        while not stopping.wait(.5):
            if any(child.poll() is not None for child in children): return 1
            try: ready = healthy()
            except (OSError, ValueError): ready = False
            if ready: failed_since = None
            elif failed_since is None: failed_since = time.monotonic()
            elif time.monotonic() - failed_since >= deadline: return 1
        return 0
    finally: stop(children)


def healthy():
    for url in ('http://127.0.0.1:7880/', 'http://127.0.0.1:8090/health'):
        with urllib.request.urlopen(url, timeout=1) as response:
            if response.status != 200: return False
    return True


if __name__ == '__main__':
    raise SystemExit(run([
        ['/usr/local/bin/livekit-server','--config','/config/livekit.json'],
        [sys.executable,'-u','prototype/token_server.py'],
    ], healthy))
