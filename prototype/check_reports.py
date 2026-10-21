#!/usr/bin/env python3
"""Assert completion of the real Android/Web scenario; never infer pass from build."""
import json
import time
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]
run = json.loads((root / '.prototype/web.json').read_text())['RUN_ID']
required = {'direct_turn_passed', 'android_recording_playback_passed', 'web_recording_playback_passed', 'foreground_invites_passed', 'presence_receipts_passed', 'core_messages_passed', 'android_attachments_passed', 'rich_history_recovered', 'web_storage_roundtrip_passed', 'device_verification_passed', 'web_trust_persisted', 'cross_platform_text_passed', 'history_recovered_without_old_devices',
            'revocation_verified', 'android_revocation_closed', 'carol_revocation_closed', 'android_media_decrypted', 'carol_media_decrypted', 'carol_done', 'three_participant_media_passed', 'android_done', 'web_done'}
end = time.monotonic() + 1200
while time.monotonic() < end:
    with urllib.request.urlopen('http://127.0.0.1:8090/reports', timeout=5) as response:
        reports = [r for r in json.load(response) if r.get('run') == run]
    stages = {r['stage'] for r in reports}
    if 'failed' in stages: raise SystemExit('FAIL: inspect .prototype/reports.json and platform logs')
    if required <= stages:
        print('PASS: core messaging/media/outbox, recording/playback, history recovery, direct TURN/DTLS, group E2EE and revocation')
        break
    time.sleep(2)
else:
    raise SystemExit('TIMEOUT: missing ' + ', '.join(sorted(required - stages)))
