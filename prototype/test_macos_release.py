"""Metadata/rollback guards do not require macOS or signing credentials."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys
import plistlib
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

    def test_debug_app_is_rejected_before_signing_or_notarization(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'VoiceChat.app'
            kernel = app / 'Contents/Frameworks/App.framework/Resources/flutter_assets/kernel_blob.bin'
            kernel.parent.mkdir(parents=True)
            kernel.write_bytes(b'debug fixture')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
            with self.assertRaisesRegex(ValueError, 'debug/JIT'):
                m.verify_app(app, release=True, team='ABCDEFGHIJ')

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

    @unittest.skipUnless(sys.platform == 'darwin', 'Requires native CryptoKit')
    def test_archive_signature_is_bound_to_embedded_public_key_and_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'fixture.zip'
            archive.write_bytes(b'disposable archive fixture')
            signer = root / 'fixture.swift'
            signer.write_text('''import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
print(key.publicKey.rawRepresentation.base64EncodedString())
print(try key.signature(for: bytes).base64EncodedString())
print(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
''')
            public, signature, other = subprocess.check_output(['swift', str(signer), str(archive)], text=True).splitlines()
            helper = str(Path(__file__).resolve().parents[1] / 'infra/verify_macos_signature.swift')
            def verify(key):
                return subprocess.run(['swift', helper, key, signature, str(archive)], capture_output=True).returncode
            self.assertEqual(verify(public), 0)
            self.assertNotEqual(verify(other), 0)
            archive.write_bytes(b'changed archive')
            self.assertNotEqual(verify(public), 0)


if __name__ == '__main__':
    unittest.main()
