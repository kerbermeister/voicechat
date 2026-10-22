import json
import tempfile
import unittest
from pathlib import Path
from client_policy import load_policy, expiry_content


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

    def test_temporary_duration_is_validated_and_expiry_uses_server_clock(self):
        policy = load_policy()
        self.assertIsNone(expiry_content({'ciphertext':'opaque'}, policy, 100000))
        for ttl in (10, 30, 600):
            content = {'ciphertext':'opaque', 'dev.voicechat.ttl_seconds':ttl,
                       'org.matrix.self_destruct_after':9999999999999}
            result = expiry_content(content, policy, 100000)
            self.assertEqual(result['org.matrix.self_destruct_after'], 100000 + ttl * 1000)
            self.assertEqual(result['ciphertext'], 'opaque')
            self.assertEqual(content['org.matrix.self_destruct_after'], 9999999999999)
        for ttl in (None, True, '10', 0, 9, 11, 601, 610):
            with self.subTest(ttl=ttl), self.assertRaises(ValueError):
                expiry_content({'dev.voicechat.ttl_seconds':ttl}, policy, 100000)
        with self.assertRaises(ValueError):
            expiry_content({'org.matrix.self_destruct_after':9999999}, policy, 100000)
        changed = {**policy, 'temporary_max_seconds':30}
        with self.assertRaises(ValueError):
            expiry_content({'dev.voicechat.ttl_seconds':40}, changed, 100000)
        edited = expiry_content({'dev.voicechat.ttl_seconds':600}, policy, 100000, 105000)
        self.assertEqual(edited['org.matrix.self_destruct_after'], 105000)
        with self.assertRaises(ValueError):
            expiry_content({'dev.voicechat.ttl_seconds':10}, policy, 100000, 100000)
