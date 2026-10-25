"""Metadata/rollback guards do not require macOS or signing credentials."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('macos_release', Path(__file__).resolve().parents[1] / 'infra/macos_release.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class MacOSReleaseTests(unittest.TestCase):
    def setUp(self):
        self.info = {'CFBundleIdentifier': 'dev.voicechat.client', 'CFBundleVersion': '2',
                     'CFBundleShortVersionString': '1.1.0', 'LSMinimumSystemVersion': '12.0',
                     'SURequireSignedFeed': True, 'SUEnableAutomaticChecks': False,
                     'SUAutomaticallyUpdate': False, 'SUAllowsAutomaticUpdates': False,
                     'SUEnableSystemProfiling': False,
                     'SUFeedURL': 'https://example.com/updates/macos/appcast.xml',
                     'SUPublicEDKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='}

    def test_release_contract_rejects_unconfigured_or_automatic_updates(self):
        m.validate_info(self.info, True)
        for key, value in [('CFBundleIdentifier', 'another.app'), ('CFBundleVersion', '0'),
                           ('LSMinimumSystemVersion', '13.0'), ('SUEnableAutomaticChecks', True),
                           ('SURequireSignedFeed', False), ('SUPublicEDKey', ''),
                           ('SUFeedURL', 'http://example.com/updates/macos/appcast.xml'),
                           ('SUFeedURL', 'https://user@example.com/updates/macos/appcast.xml')]:
            info = {**self.info, key: value}
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                m.validate_info(info, True)

    def test_feed_preserves_old_compatible_release_and_refuses_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'VoiceChat.zip'
            archive.write_bytes(b'fixture archive')
            previous = m.create_feed(self.info, archive, 'signature', 'Old release')
            newer = {**self.info, 'CFBundleVersion': '3', 'LSMinimumSystemVersion': '13.0'}
            feed = m.create_feed(newer, archive, 'signature', '<plain text & notes>', previous)
            items = ET.fromstring(feed).findall('channel/item')
            self.assertEqual([item.findtext(f'{{{m.SPARKLE}}}minimumSystemVersion') for item in items], ['13.0', '12.0'])
            self.assertEqual(items[0].findtext('description'), '<plain text & notes>')
            self.assertEqual(items[0].find('enclosure').get('url'), 'https://example.com/updates/macos/3/VoiceChat.zip')
            for build in ('1', '2', '3'):
                with self.subTest(build=build), self.assertRaises(ValueError):
                    m.create_feed({**self.info, 'CFBundleVersion': build}, archive, 'signature', '', feed)
            with self.assertRaises(ValueError):
                m.create_feed(newer, archive, 'signature', '', b'<!DOCTYPE rss><rss/>')


if __name__ == '__main__':
    unittest.main()
