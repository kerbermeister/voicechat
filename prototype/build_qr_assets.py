#!/usr/bin/env python3
"""Serve the scanner's pinned JS/WASM locally; never execute CDN code beside keys."""
import base64
import hashlib
import io
import tarfile
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]
version = '3.1.3'  # mobile_scanner 7.4.2 web decoder
expected = '3lC9BJk4fR5ZJxcGjb0hVnDFOW7KpLXHIebiBmVd4FDRQZVeObztoTKxRUPxlWwSgxrMRONK0u50hBD1aTYEKg=='
cache = root / f'.prototype/zxing-{version}.tgz'
if cache.exists():
    data = cache.read_bytes()
else:
    with urllib.request.urlopen(f'https://registry.npmjs.org/zxing-wasm/-/zxing-wasm-{version}.tgz', timeout=30) as response:
        data = response.read(8 * 1024 * 1024 + 1)
if len(data) > 8 * 1024 * 1024 or base64.b64encode(hashlib.sha512(data).digest()).decode() != expected:
    raise SystemExit('Unexpected QR decoder archive; refusing build')
cache.parent.mkdir(parents=True, exist_ok=True)
cache.write_bytes(data)
web = root / 'apps/client/web'
destination = web / 'zxing'
destination.mkdir(exist_ok=True)
with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
    def read(name):
        member = archive.getmember('package/' + name)
        if not member.isfile() or member.size > 5 * 1024 * 1024:
            raise ValueError('Invalid QR asset')
        return archive.extractfile(member).read()
    script = read('dist/iife/reader/index.js')
    wasm = read('dist/reader/zxing_reader.wasm')
    if not wasm.startswith(b'\0asm'): raise ValueError('Invalid decoder WASM')
    (web / 'zxing.js').write_bytes(script + b'\nZXingWASM.prepareZXingModule({overrides:{locateFile:()=>new URL("zxing/zxing_reader.wasm",document.baseURI).href}});\n')
    (destination / 'zxing_reader.wasm').write_bytes(wasm)
    (destination / 'LICENSE').write_bytes(read('LICENSE'))
print('Pinned QR decoder JS/WASM ready; all scanning stays local')
