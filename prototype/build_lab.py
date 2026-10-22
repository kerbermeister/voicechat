#!/usr/bin/env python3
"""Flutter prints -D values on errors; redact disposable credentials before logging."""
import json
import subprocess
import sys
from pathlib import Path


def credentials(data):
    result = set()
    for key, value in data.items():
        if isinstance(value, str) and not key.upper().endswith('_URL') and any(part in key.lower() for part in ('password', 'token', 'secret')):
            if len(value) >= 8: result.add(value)
        if key == 'LOAD_ACCOUNTS':
            for account in json.loads(value): result.update(credentials(account))
    return result


def main():
    if len(sys.argv) != 4: raise SystemExit('Usage: build_lab.py lab_target fixture_json output_directory')
    target, fixture, output = sys.argv[1:]
    root = Path(__file__).resolve().parents[1]
    app = root / 'apps/client'
    if not target.startswith('lib/lab_') or not target.endswith('.dart'): raise SystemExit('Only laboratory targets allowed')
    fixture = Path(fixture).resolve()
    if not fixture.is_relative_to(root / '.prototype'): raise SystemExit('Use an ignored fixture under .prototype')
    values = credentials(json.loads(fixture.read_text()))
    process = subprocess.Popen(['flutter','build','web','--release','--target='+target,
        '--dart-define-from-file='+str(fixture),'--output='+str(Path(output).resolve())],
        cwd=app, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in process.stdout:
        for value in sorted(values, key=len, reverse=True): line = line.replace(value, '[redacted]')
        print(line, end='', flush=True)
    raise SystemExit(process.wait())


if __name__ == '__main__': main()
