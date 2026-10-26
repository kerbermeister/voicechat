#!/usr/bin/env python3
"""Give large public startup assets content-addressed URLs after flutter build web."""
import hashlib
import json
from pathlib import Path
import shutil
import sys


def version_assets(root: Path):
    bootstrap = root / 'flutter_bootstrap.js'
    html = root / 'index.html'
    marker = 'config: {}, // voicechat-versioned-assets'
    source = bootstrap.read_text()
    if source.count(marker) != 1:
        raise ValueError('Expected unversioned VoiceChat bootstrap')
    files = [root / 'main.dart.js', *sorted((root / 'canvaskit').rglob('*'))]
    files = [file for file in files if file.is_file()]
    if not (root / 'canvaskit/canvaskit.wasm').is_file():
        raise ValueError('Local CanvasKit is required')
    digest = hashlib.sha256()
    for file in files:
        digest.update(file.relative_to(root).as_posix().encode() + b'\0')
        digest.update(hashlib.sha256(file.read_bytes()).digest())
    prefix = f'static/{digest.hexdigest()}/'
    for file in files:
        target = root / prefix / file.relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(file, target)
    config = {'entrypointBaseUrl': prefix, 'canvasKitBaseUrl': prefix + 'canvaskit/'}
    bootstrap.write_text(source.replace(marker, f'config: {json.dumps(config)},'))
    html.write_text(html.read_text().replace('href="main.dart.js"', f'href="{prefix}main.dart.js"'))
    return prefix


if __name__ == '__main__':
    version_assets(Path(sys.argv[1]))
