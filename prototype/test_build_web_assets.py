import json
from pathlib import Path
import tempfile
import unittest

from build_web_assets import livekit_worker_source


class WorkerSourceTest(unittest.TestCase):
    def test_hosted_and_path_sdk_roots_resolve_relative_to_package_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = root / 'client'
            config = app / '.dart_tool/package_config.json'
            config.parent.mkdir(parents=True)
            sdk = root / 'sdk with spaces'
            worker = sdk / 'web/e2ee.worker.dart'
            worker.parent.mkdir(parents=True)
            worker.write_text('// worker')
            for uri in ('../../sdk%20with%20spaces/', str(sdk) + '/', sdk.as_uri() + '/'):
                with self.subTest(rootUri=uri):
                    config.write_text(json.dumps({'packages': [
                        {'name': 'livekit_client', 'rootUri': uri},
                    ]}))
                    self.assertEqual(livekit_worker_source(config), worker)


if __name__ == '__main__':
    unittest.main()
