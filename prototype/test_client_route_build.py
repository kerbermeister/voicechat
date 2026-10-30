import base64
from copy import deepcopy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
from client_config import build_config, client_config, verify_candidate_config


class ClientBuildTests(unittest.TestCase):
    def setUp(self):
        self.public = json.loads((ROOT/'infra/single-vps.example.json').read_text())
        self.key = base64.b64encode(bytes(range(32))).decode()
        self.origin = self.public['canonical_origin']

    def test_optional_build_config_preserves_identity_and_legacy_mode(self):
        self.assertEqual(build_config(self.origin), client_config(self.origin))
        result = build_config(self.origin, json.dumps(self.public), self.key)
        self.assertEqual(result['MATRIX_URL'], self.origin)
        self.assertEqual(result['LIVEKIT_URL'], 'wss' + self.origin[5:])
        self.assertEqual(json.loads(result['ROUTE_CONFIG']), self.public)
        self.assertEqual(result['ROUTE_CATALOG_KEY'], self.key)

    def test_invalid_pairs_keys_identity_and_duplicate_fields_fail(self):
        source = json.dumps(self.public)
        for text, key in ((source, ''), ('', self.key), (source, base64.b64encode(bytes(32)).decode()),
                          (source, self.key + '\n'), (source, 'bad'), (source[:-1]+',"schema":1}', self.key)):
            with self.assertRaises(ValueError): build_config(self.origin, text, key)
        with self.assertRaises(ValueError): build_config('https://other.example.com', source, self.key)
        with self.assertRaises(ValueError): build_config(self.origin, ' '*48001, self.key)

    def test_candidate_configuration_cannot_be_relabelled(self):
        routed = build_config(self.origin, json.dumps(self.public), self.key)
        legacy = client_config(self.origin)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)/'client-config.json'
            verify_candidate_config(legacy, path)
            with self.assertRaises(ValueError): verify_candidate_config(routed, path)
            path.write_text(json.dumps(routed))
            verify_candidate_config(routed, path)
            with self.assertRaises(ValueError): verify_candidate_config(legacy, path)
            changed = deepcopy(routed); changed['ROUTE_CATALOG_KEY'] = base64.b64encode(b'x'*32).decode()
            with self.assertRaises(ValueError): verify_candidate_config(changed, path)
            path.write_text(json.dumps(routed)[:-1]+',"MATRIX_URL":"https://other.test"}')
            with self.assertRaises(ValueError): verify_candidate_config(routed, path)

    def test_cli_environment_is_opt_in_and_invalid_input_preserves_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)/'client.json'
            env = {**os.environ, 'CLIENT_ROUTE_CONFIG': json.dumps(self.public), 'CLIENT_ROUTE_CATALOG_KEY': self.key}
            command = [sys.executable, str(ROOT/'infra/client_config.py')]
            subprocess.run([*command, self.origin, str(path)], env=env, check=True)
            self.assertNotIn('ROUTE_CONFIG', json.loads(path.read_text()))
            subprocess.run([*command, '--environment', self.origin, str(path)], env=env, check=True)
            original = path.read_bytes()
            self.assertIn('ROUTE_CONFIG', json.loads(original))
            env['CLIENT_ROUTE_CATALOG_KEY'] = ''
            result = subprocess.run([*command, '--environment', self.origin, str(path)], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_bytes(), original)


if __name__ == '__main__': unittest.main()
