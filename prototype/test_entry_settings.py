import base64
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import entry_settings
import managed_state
import role_release


class EntrySettingsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name).resolve() / 'settings'
        self.value = {'catalog': json.dumps({'payload': base64.b64encode(b'x' * 48000).decode(),
                                            'signature': base64.b64encode(bytes(64)).decode()}),
                      'tls': {'operator_references': 'x' * 12000}}

    def test_large_catalog_and_settings_are_individually_bounded_and_hash_bound(self):
        self.assertGreater(len(json.dumps(self.value)), 65536)
        checksum = entry_settings.store(self.path, self.value)
        self.assertEqual(checksum, role_release.json_digest(entry_settings.load(self.path)))
        self.assertEqual(entry_settings.store(self.path, self.value), checksum)
        for name in ('catalog.json', 'settings.json'):
            self.assertLess((self.path / name).stat().st_size, 65536)

    def test_changed_catalog_cannot_become_a_resumed_operation(self):
        entry_settings.store(self.path, self.value)
        envelope = managed_state.read(self.path / 'catalog.json'); envelope['signature'] = 'wrong'
        managed_state.persist(self.path / 'catalog.json', envelope)
        with self.assertRaisesRegex(ValueError, 'catalog changed'): entry_settings.load(self.path)

    def test_duplicate_envelope_fields_rejected_before_state_creation(self):
        self.value['catalog'] = '{"payload":"first","payload":"second","signature":"x"}'
        with self.assertRaisesRegex(ValueError, 'Duplicate'): entry_settings.store(self.path, self.value)
        self.assertFalse(self.path.exists())


if __name__ == '__main__': unittest.main()
