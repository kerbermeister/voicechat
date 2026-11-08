"""Keep the official Android version patch inside exact-source verification."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
import build_webrtc_sdk as builder


class BuilderSourceTests(unittest.TestCase):
    def test_android_has_exact_version_patch_and_preserves_other_hashes(self):
        for key in ('original_files_sha256', 'patched_files_sha256'):
            with self.subTest(stage=key):
                base = builder.MANIFEST[key]
                android = builder.source_hashes(key, 'android')
                self.assertEqual(set(android), set(base))
                self.assertEqual(builder.source_hashes(key, 'apple'), base)
                self.assertEqual(builder.source_hashes(key, 'ubuntu-24.04_x86_64'), base)
                self.assertEqual({name for name in base if base[name] != android[name]},
                                 {'sdk/android/BUILD.gn'})

    def test_modified_version_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            relative = 'sdk/android/BUILD.gn'
            path = root / relative
            path.parent.mkdir(parents=True)
            for key in ('original_files_sha256', 'patched_files_sha256'):
                with self.subTest(stage=key):
                    expected = builder.source_hashes(key, 'android')[relative]
                    path.write_text('Different Android version source')
                    with self.assertRaisesRegex(RuntimeError, 'Unexpected SDK source'):
                        builder.verify_files(root, {relative: expected})


if __name__ == '__main__':
    unittest.main()
