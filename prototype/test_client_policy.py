import json
import tempfile
import unittest
from pathlib import Path
from client_policy import load_policy


class PolicyTests(unittest.TestCase):
    def test_defaults_and_boundaries(self):
        defaults = load_policy()
        self.assertEqual(defaults['photo_max_count'], 24)
        self.assertEqual(defaults['photo_scale'], .5)
        self.assertEqual(defaults['video_max_bytes'], 300 * 1024 * 1024)
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'policy.json'
            for change in [{'photo_max_count': 0}, {'photo_scale': float('nan')}, {'photo_scale': True}, {'photo_jpeg_quality': 101}, {'video_max_bytes': 400 * 1024 * 1024}, {'version': True}, {'unrecognized': 1}]:
                with self.subTest(change=change):
                    path.write_text(json.dumps({**defaults, **change}))
                    with self.assertRaises(ValueError): load_policy(path)
