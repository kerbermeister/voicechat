#!/usr/bin/env python3
"""Require decoded frames on Android and both web peers; retain only public stages."""
import json
import time
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]
run = json.loads((root / '.prototype/web.json').read_text())['RUN_ID']
required = {f'video_{stage}_{peer}' for stage in ('group_frames', 'camera_frames', 'passed', 'done') for peer in range(3)}
required |= {'video_direct_frames_0', 'video_direct_frames_1', 'video_low_decoded_android', 'video_android_camera_switched', 'video_auto_restored'}
deadline = time.monotonic() + 360
while time.monotonic() < deadline:
    with urllib.request.urlopen('http://127.0.0.1:8090/reports', timeout=5) as response:
        reports = [r for r in json.load(response) if r.get('run') == run]
    stages = {r['stage'] for r in reports}
    if 'video_background_ready' in stages:
        required |= {'video_background_returned', *(f'video_background_audio_{i}' for i in range(3))}
    if 'failed' in stages:
        raise SystemExit('FAIL: video acceptance reported a failed assertion')
    if required <= stages:
        public = [{key: r[key] for key in ('run', 'role', 'stage', 'timestamp')} for r in reports]
        (root / 'prototype/verified-video-run.json').write_text(json.dumps({'run': run, 'result': 'PASS', 'reports': public}, indent=2) + '\n')
        print('PASS: Android/web direct TURN video, three E2EE video/audio decoders, camera switch and 180p/Auto recovery')
        break
    time.sleep(2)
else:
    raise SystemExit('TIMEOUT: missing ' + ', '.join(sorted(required - stages)))
