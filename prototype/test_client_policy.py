import json
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path
from client_policy import load_policy, expiry_content, read_after_duration


class PolicyTests(unittest.TestCase):
    def test_read_after_duration_requires_exact_integer_and_one_retention_mode(self):
        for delay in (1, 5, 86400):
            self.assertEqual(read_after_duration({'dev.voicechat.read_after_seconds': delay}), delay)
        for delay in (None, True, False, 0, -1, 86401, '5', 5.0, [], {}):
            with self.assertRaises(ValueError):
                read_after_duration({'dev.voicechat.read_after_seconds': delay})
        for key in ('dev.voicechat.ttl_seconds', 'org.matrix.self_destruct_after'):
            with self.assertRaises(ValueError):
                read_after_duration({'dev.voicechat.read_after_seconds': 5, key: 10})

    def test_defaults_and_boundaries(self):
        defaults = load_policy()
        self.assertEqual(defaults['photo_max_count'], 24)
        self.assertEqual(defaults['photo_scale'], .5)
        self.assertEqual(defaults['video_max_bytes'], 300 * 1024 * 1024)
        self.assertEqual(defaults['schedule_max_seconds'], 48 * 3600)
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'policy.json'
            for change in [{'photo_max_count': 0}, {'photo_scale': float('nan')}, {'photo_scale': True}, {'photo_jpeg_quality': 101}, {'video_max_bytes': 400 * 1024 * 1024}, {'version': True}, {'unrecognized': 1}]:
                with self.subTest(change=change):
                    path.write_text(json.dumps({**defaults, **change}))
                    with self.assertRaises(ValueError): load_policy(path)

    def test_p2p_policy_is_separate_and_rejects_invalid_values(self):
        defaults = load_policy()
        self.assertEqual([defaults[k] for k in ('p2p_file_max_bytes', 'p2p_file_max_count', 'p2p_max_recipients')], [5000000000, 10, 4])
        self.assertEqual(defaults['file_max_bytes'], 314572800)
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'policy.json'
            for key, high in [('p2p_file_max_bytes', 100000000000), ('p2p_file_max_count', 100), ('p2p_max_recipients', 16)]:
                for value in [0, -1, True, 1.5, '4', high + 1]:
                    with self.subTest(key=key, value=value):
                        path.write_text(json.dumps({**defaults, key:value}))
                        with self.assertRaises(ValueError): load_policy(path)
                path.write_text(json.dumps({**defaults, key:high}))
                self.assertEqual(load_policy(path)[key], high)

    def test_runtime_policy_is_reloaded_and_invalid_changes_fail_closed(self):
        defaults = load_policy()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'client-policy.json'
            with patch.dict('os.environ', {'VOICECHAT_CLIENT_POLICY': str(path)}):
                path.write_text(json.dumps({**defaults, 'schedule_max_seconds':3600}))
                self.assertEqual(load_policy()['schedule_max_seconds'], 3600)
                path.write_text(json.dumps({**defaults, 'schedule_max_seconds':7200}))
                self.assertEqual(load_policy()['schedule_max_seconds'], 7200)
                path.write_text(json.dumps({**defaults, 'schedule_max_seconds':True}))
                with self.assertRaises(ValueError): load_policy()

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
