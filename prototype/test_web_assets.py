import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('version_web_assets', Path(__file__).resolve().parents[1] / 'apps/client/tool/version_web_assets.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class VersionAssetsTest(unittest.TestCase):
    def build(self, root, main='application', engine='engine'):
        (root / 'canvaskit/chromium').mkdir(parents=True, exist_ok=True)
        (root / 'canvaskit/canvaskit.wasm').write_text(engine)
        (root / 'canvaskit/chromium/canvaskit.wasm').write_text('chromium')
        (root / 'main.dart.js').write_text(main)
        (root / 'flutter_bootstrap.js').write_text('load({config: {}, // voicechat-versioned-assets\n});')
        (root / 'index.html').write_text('<link href="main.dart.js">')
        return module.version_assets(root)

    def test_content_changes_get_new_urls_and_previous_bytes_survive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.build(root)
            self.assertEqual(first, self.build(root))
            second = self.build(root, main='new application')
            self.assertNotEqual(first, second)
            third = self.build(root, main='new application', engine='new engine')
            self.assertNotEqual(second, third)
            self.assertEqual((root / first / 'main.dart.js').read_text(), 'application')
            self.assertIn(third + 'main.dart.js', (root / 'index.html').read_text())
            self.assertIn(third + 'canvaskit/', (root / 'flutter_bootstrap.js').read_text())
            self.assertEqual((root / third / 'canvaskit/chromium/canvaskit.wasm').read_text(), 'chromium')
            with self.assertRaises(ValueError):
                module.version_assets(root)


if __name__ == '__main__':
    unittest.main()
