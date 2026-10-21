"""Public client limits; Synapse independently enforces its upload-size limit."""
import json
from pathlib import Path

BOUNDS = {
    'photo_max_count': (int, 1, 64), 'photo_scale': ((int, float), .05, 1),
    'photo_jpeg_quality': (int, 1, 100), 'photo_max_bytes': (int, 1, 10 * 1024 * 1024),
    'photo_max_pixels': (int, 1, 24_000_000), 'text_max_length': (int, 1, 16000),
    'voice_max_seconds': (int, 1, 180), 'video_note_max_seconds': (int, 1, 600),
    'video_max_bytes': (int, 1, 300 * 1024 * 1024), 'file_max_bytes': (int, 1, 300 * 1024 * 1024),
}


def load_policy(path=Path(__file__).with_name('client-policy.json')):
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or type(data.get('version')) is not int or data.get('version') != 1 or set(data) != {'version', *BOUNDS}:
        raise ValueError('Unsupported policy')
    for name, (kind, low, high) in BOUNDS.items():
        value = data[name]
        if isinstance(value, bool) or not isinstance(value, kind) or not low <= value <= high:
            raise ValueError('Invalid limit: ' + name)
    return data
