"""Compile and exercise the native URL mapper, without Sparkle installing anything."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin', 'Requires native Foundation URL parsing')
class MacUpdateRouteTests(unittest.TestCase):
    def test_trusted_origin_rewrite_keeps_signed_paths_and_rejects_escapes(self):
        with tempfile.TemporaryDirectory(prefix='voicechat-update-route-') as temporary:
            directory = Path(temporary)
            main = directory / 'main.swift'
            main.write_text('''import Foundation
let feed = URL(string: "https://canonical.test/updates/macos/appcast.xml")!
let route = MacUpdateRoute(feed: feed, canonicalOrigin: "https://canonical.test", selectedOrigin: "https://c.test:8443")!
assert(route.feedURL.absoluteString == "https://c.test:8443/updates/macos/appcast.xml")
assert(route.rewrite(URL(string: "https://canonical.test/updates/macos/3/VoiceChat.zip")!)?.absoluteString == "https://c.test:8443/updates/macos/3/VoiceChat.zip")
assert(route.rewrite(URL(string: "https://canonical.test:443/updates/macos/3/VoiceChat.zip")!) != nil)
for origin in ["http://c.test", "https://user@c.test", "https://c.test/path", "https://c.test?x", "https://c.test#x", "https://c.test:0", "https://c.test:65536", "https://c.test\\n"] {
    assert(MacUpdateRoute(feed: feed, canonicalOrigin: "https://canonical.test", selectedOrigin: origin) == nil, origin)
}
assert(MacUpdateRoute(feed: feed, canonicalOrigin: "https://another.test", selectedOrigin: "https://c.test") == nil)
assert(MacUpdateRoute(feed: URL(string: "https://canonical.test/not-a-feed")!, canonicalOrigin: "https://canonical.test", selectedOrigin: "https://c.test") == nil)
for value in ["https://foreign.test/updates/macos/3/VoiceChat.zip", "http://canonical.test/updates/macos/3/VoiceChat.zip", "https://user@canonical.test/updates/macos/3/VoiceChat.zip", "https://canonical.test/updates/macos/3/VoiceChat.zip?token=x", "https://canonical.test/updates/macos/3/VoiceChat.zip#x", "https://canonical.test/updates/macos/../VoiceChat.zip", "https://canonical.test/updates/macos/%2e%2e/VoiceChat.zip", "https://canonical.test/updates/macos/3/Other.zip", "https://canonical.test:8443/updates/macos/3/VoiceChat.zip"] {
    assert(route.rewrite(URL(string: value)!) == nil, value)
}
print("PASS: native update route preserves canonical paths and rejects origin/path escapes")
''')
            binary = directory / 'route-check'
            subprocess.run(['swiftc', str(ROOT / 'apps/client/macos/Runner/MacUpdateRoute.swift'),
                            str(main), '-o', str(binary)], check=True, capture_output=True)
            output = subprocess.check_output([str(binary)], text=True)
            self.assertIn('PASS:', output)


if __name__ == '__main__':
    unittest.main()
