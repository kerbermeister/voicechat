#!/usr/bin/env python3
"""Build upstream crypto assets using the dependencies locked by Flutter."""
import json
import shutil
import subprocess
from pathlib import Path
from urllib.parse import urlparse, unquote

root = Path(__file__).resolve().parents[1]
app = root / 'apps/client'
packages = json.loads((app / '.dart_tool/package_config.json').read_text())['packages']
livekit = next(p for p in packages if p['name'] == 'livekit_client')
source = Path(unquote(urlparse(livekit['rootUri']).path)) / 'web/e2ee.worker.dart'
subprocess.run(['dart', 'compile', 'js', '--packages=.dart_tool/package_config.json',
                str(source), '-o', 'web/e2ee.worker.dart.js', '-m'], cwd=app, check=True)
checkout = root / '.prototype/vodozemac'
commit = '774956e945a39451441e72f03195a1ad2e78c3a8'  # upstream 0.9.0
if not checkout.exists():
    subprocess.run(['git', 'clone', '--depth', '1', '--branch', '0.9.0',
                    'https://github.com/famedly/dart-vodozemac.git', str(checkout)], check=True)
actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=checkout, text=True).strip()
if actual != commit: raise SystemExit('Unexpected vodozemac checkout; refusing build')
subprocess.run(['flutter_rust_bridge_codegen', 'build-web', '--dart-root', 'dart',
                '--rust-root', str(checkout / 'rust'), '--release'], cwd=checkout, check=True)
shutil.copytree(checkout / 'dart/web/pkg', app / 'web/pkg', dirs_exist_ok=True)
print('Web crypto assets built. They are generated, not committed.')
