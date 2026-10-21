#!/usr/bin/env python3
"""Assert completion of the real Android/Web scenario; never infer pass from build."""
import json
import time
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]
run = json.loads((root / '.prototype/web.json').read_text())['RUN_ID']
required = {'cross_platform_text_passed', 'history_recovered_without_old_devices',
            'android_media_decrypted', 'carol_media_decrypted', 'carol_done', 'three_participant_media_passed', 'android_done', 'web_done'}
end = time.monotonic() + 600
while time.monotonic() < end:
    with urllib.request.urlopen('http://127.0.0.1:8090/reports', timeout=5) as response:
        reports = [r for r in json.load(response) if r.get('run') == run]
    stages = {r['stage'] for r in reports}
    if 'failed' in stages: raise SystemExit('FAIL: inspect .prototype/reports.json and platform logs')
    if required <= stages:
        print('PASS: Android/Web encrypted text, fresh-device recovery, three-participant E2EE audio')
        break
    time.sleep(2)
else:
    raise SystemExit('TIMEOUT: missing ' + ', '.join(sorted(required - stages)))
