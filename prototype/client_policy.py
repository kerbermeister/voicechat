"""Public client limits; Synapse independently enforces its upload-size limit."""
import json
import os
from pathlib import Path

BOUNDS = {
    'p2p_file_max_bytes': (int, 1, 100_000_000_000),
    'p2p_file_max_count': (int, 1, 100),
    'p2p_max_recipients': (int, 1, 16),
    'photo_max_count': (int, 1, 64), 'photo_scale': ((int, float), .05, 1),
    'photo_jpeg_quality': (int, 1, 100), 'photo_max_bytes': (int, 1, 10 * 1024 * 1024),
    'photo_max_pixels': (int, 1, 24_000_000), 'text_max_length': (int, 1, 16000),
    'voice_max_seconds': (int, 1, 180), 'video_note_max_seconds': (int, 1, 600),
    'video_max_bytes': (int, 1, 300 * 1024 * 1024), 'file_max_bytes': (int, 1, 300 * 1024 * 1024),
    'file_max_count': (int, 1, 20),
    'temporary_min_seconds': (int, 1, 86400),
    'temporary_max_seconds': (int, 1, 86400),
    'temporary_step_seconds': (int, 1, 86400),
    'schedule_max_seconds': (int, 1, 31536000),
}


def load_policy(path=None):
    path = Path(path or os.environ.get('VOICECHAT_CLIENT_POLICY', Path(__file__).with_name('client-policy.json')))
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or type(data.get('version')) is not int or data.get('version') != 1 or set(data) != {'version', *BOUNDS}:
        raise ValueError('Unsupported policy')
    for name, (kind, low, high) in BOUNDS.items():
        value = data[name]
        if isinstance(value, bool) or not isinstance(value, kind) or not low <= value <= high:
            raise ValueError('Invalid limit: ' + name)
    low, high, step = (data['temporary_' + key + '_seconds'] for key in ('min', 'max', 'step'))
    if low > high or (high - low) % step:
        raise ValueError('Invalid temporary message interval')
    return data


def expiry_content(content, policy, now_ms, original_deadline=None):
    """Only the server clock decides when a newly accepted event expires."""
    if 'dev.voicechat.ttl_seconds' not in content:
        if 'org.matrix.self_destruct_after' in content:
            raise ValueError('A temporary duration is required')
        return None
    ttl = content['dev.voicechat.ttl_seconds']
    low, high, step = (policy['temporary_' + key + '_seconds'] for key in ('min', 'max', 'step'))
    if type(ttl) is not int or not low <= ttl <= high or (ttl - low) % step:
        raise ValueError('Invalid temporary message duration')
    deadline = now_ms + ttl * 1000
    if original_deadline is not None:
        if type(original_deadline) is not int or original_deadline <= now_ms:
            raise ValueError('Original message expired')
        deadline = min(deadline, original_deadline)
    return {**content, 'org.matrix.self_destruct_after': deadline}


def read_after_duration(content):
    """Retention starts on an authenticated recipient read, never on delivery."""
    delay = content.get('dev.voicechat.read_after_seconds')
    if type(delay) is not int or not 1 <= delay <= 86400:
        raise ValueError('Invalid read-after duration')
    if any(key in content for key in ('dev.voicechat.ttl_seconds', 'org.matrix.self_destruct_after')):
        raise ValueError('Read-after and send-time expiry are mutually exclusive')
    return delay
