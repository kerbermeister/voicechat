#!/usr/bin/env python3
"""Keep the local website and its required control API in one lifecycle."""
import argparse
from pathlib import Path
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from infra.supervise import run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=7357)
    parser.add_argument('--directory', type=Path, default=ROOT / 'apps/client/build/web')
    options = parser.parse_args()
    if not 1 <= options.port <= 65535 or options.port == 8090:
        parser.error('Choose a valid web port other than the control API port 8090')
    if not (options.directory / 'index.html').is_file():
        parser.error('Build the ordinary web client first')

    def healthy():
        for url in ('http://127.0.0.1:8090/health', f'http://127.0.0.1:{options.port}/'):
            with urllib.request.urlopen(url, timeout=1) as response:
                if response.status != 200:
                    return False
        return True

    return run([
        [sys.executable, '-u', str(ROOT / 'prototype/token_server.py')],
        [sys.executable, '-u', str(ROOT / 'prototype/serve_web.py'),
         '--port', str(options.port), '--directory', str(options.directory.resolve())],
    ], healthy, deadline=15)


if __name__ == '__main__':
    raise SystemExit(main())
