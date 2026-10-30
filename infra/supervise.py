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


def run(commands, healthy, deadline=5, startup_deadline=None, startup_ready=None):
    stopping = threading.Event()
    def terminate(*_): stopping.set()
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    children = []
    failed_since = time.monotonic()
    started = False
    startup_deadline = deadline if startup_deadline is None else startup_deadline
    try:
        for command in commands:
            # Control recovery deletes retired SFU rooms. It must not run before
            # the first child (SFU) accepts requests, including on a cold restart.
            if children and startup_ready is not None:
                while True:
                    if stopping.is_set(): return 0
                    if any(child.poll() is not None for child in children): return 1
                    try: ready = startup_ready()
                    except (OSError, ValueError): ready = False
                    if ready: break
                    if time.monotonic() - failed_since >= startup_deadline: return 1
                    if stopping.wait(.1): return 0
            children.append(subprocess.Popen(command))
        while not stopping.wait(.5):
            if any(child.poll() is not None for child in children): return 1
            try: ready = healthy()
            except (OSError, ValueError): ready = False
            if ready:
                started = True
                failed_since = None
            elif failed_since is None: failed_since = time.monotonic()
            elif time.monotonic() - failed_since >= (deadline if started else startup_deadline): return 1
        return 0
    finally: stop(children)


def sfu_ready():
    with urllib.request.urlopen('http://127.0.0.1:7880/', timeout=1) as response:
        return response.status == 200


def healthy():
    if not sfu_ready(): return False
    with urllib.request.urlopen('http://127.0.0.1:8090/health', timeout=1) as response:
        return response.status == 200


if __name__ == '__main__':
    # Cold imports/SFU startup can exceed the runtime outage cutoff. Once ready,
    # keep the five-second cutoff so an unhealthy controller still cuts media.
    raise SystemExit(run([
        ['/usr/local/bin/livekit-server','--config','/config/livekit.json'],
        [sys.executable,'-u','prototype/token_server.py'],
    ], healthy, startup_deadline=30, startup_ready=sfu_ready))
