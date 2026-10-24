#!/usr/bin/env python3
"""Ordinary SS-16 web regression; keep prior call evidence and remove the test flag."""
import os
from pathlib import Path
import subprocess
import urllib.request

root = Path(__file__).resolve().parents[1]
flag = Path('/tmp/voicechat-screen-test-enabled')
assert not flag.exists(), 'Another local screen test owns the feature flag'
evidence = root/'prototype/verified-screen-calls-run.json'
before = evidence.read_bytes() if evidence.exists() else None
for url in ('http://localhost:7358/', 'http://localhost:8090/health',
            'http://localhost:8008/_matrix/client/versions'):
    with urllib.request.urlopen(url, timeout=5) as response:
        assert response.status == 200
try:
    flag.write_text('1')
    flag.chmod(0o600)
    subprocess.run(['node', 'prototype/check_contacts_ui.cjs'], cwd=root, check=True,
        env={**os.environ, 'VOICECHAT_UI_URL': 'http://localhost:7358/',
             'VOICECHAT_VIDEO_TEST': '1', 'VOICECHAT_SCREEN_TEST': '1',
             'VOICECHAT_SCREEN_REGRESSION': '1', 'VOICECHAT_SCREEN_TEST_FLAG': str(flag)})
finally:
    flag.unlink(missing_ok=True)
    if before is None:
        evidence.unlink(missing_ok=True)
    else:
        evidence.write_bytes(before)
