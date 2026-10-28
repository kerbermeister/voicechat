import base64
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
from publish_catalog import publish
from route_catalog import DOMAIN, public_key, read_envelope, sign, verify
from topology import load


class CatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='voicechat-catalog-test-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.key = Path(cls.temporary.name) / 'test-only.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(cls.key)],
                       check=True, capture_output=True)
        cls.public = public_key(cls.key)
        cls.bootstrap = load(ROOT / 'infra/three-vps.example.json')

    def envelope(self, revision=1, *, config=None, issued=None, expires=None):
        now = int(time.time())
        return json.dumps(sign(config or self.bootstrap, self.key, revision,
                               now if issued is None else issued,
                               now + 3600 if expires is None else expires)).encode()

    def signed_payload(self, payload):
        # Exercise hostile but genuinely signed JSON, independently of signer validation.
        with tempfile.TemporaryDirectory() as temporary:
            message = Path(temporary) / 'message'
            message.write_bytes(DOMAIN + payload)
            signature = subprocess.check_output(['openssl', 'pkeyutl', '-sign', '-rawin',
                '-inkey', str(self.key), '-in', str(message)], stderr=subprocess.PIPE)
        return json.dumps({'payload': base64.b64encode(payload).decode(),
                           'signature': base64.b64encode(signature).decode()}).encode()

    def test_signed_expansion_removal_return_and_identity(self):
        expanded = deepcopy(self.bootstrap)
        expanded['edges'].append({'id':'d', 'origin':'https://d.example.com', 'turn_host':'turn-d.example.com'})
        previous = verify(self.envelope(), self.public, self.bootstrap)
        for revision, config in ((2, expanded), (3, self.bootstrap), (4, expanded)):
            current = verify(self.envelope(revision, config=config), self.public, self.bootstrap, previous=previous)
            self.assertEqual(current.topology, config)
            previous = current
        for name, value in (('service_id', 'foreign'), ('matrix_server_name', 'foreign.example.com'),
                            ('canonical_origin', 'https://foreign.example.com')):
            changed = deepcopy(expanded)
            changed[name] = value
            if name == 'canonical_origin': changed['web_origins'].append(value)
            with self.subTest(name=name), self.assertRaises(ValueError):
                verify(self.envelope(5, config=changed), self.public, self.bootstrap)

    def test_signature_schema_bounds_and_time_fail_closed(self):
        envelope = self.envelope()
        tampered = json.loads(envelope)
        tampered['signature'] = base64.b64encode(bytes(64)).decode()
        payload = json.loads(base64.b64decode(json.loads(envelope)['payload']))
        now = int(time.time())
        invalid = [json.dumps(tampered).encode(), b' ' * 65537, envelope.decode().encode('utf-16'),
                   b'{"payload":"x","payload":"y","signature":"z"}',
                   json.dumps({**json.loads(envelope), 'extra':True}).encode(),
                   self.envelope(issued=now-3600, expires=now),
                   self.envelope(issued=now+301, expires=now+3600)]
        for change in ({'schema':True}, {'revision':0}, {'revision':9007199254740992},
                       {'issued_at':True}, {'expires_at':now + 31*86400}, {'extra':1}):
            invalid.append(self.signed_payload(json.dumps({**payload, **change}).encode()))
        invalid.append(self.signed_payload(json.dumps(payload).replace('"schema": 1', '"schema": 1, "schema": 1').encode()))
        invalid.append(self.signed_payload(b' ' * 48001))
        for candidate in invalid:
            with self.subTest(candidate=candidate[:70]), self.assertRaises(ValueError):
                verify(candidate, self.public, self.bootstrap, now=now)
        with self.assertRaises(ValueError):
            verify(envelope, base64.b64encode(bytes(32)).decode(), self.bootstrap)
        # Maximum allowed future skew and expired persisted state have distinct contracts.
        verify(self.envelope(issued=now+300, expires=now+3600), self.public, self.bootstrap, now=now)
        verify(self.envelope(issued=now-3600, expires=now), self.public, self.bootstrap, restoring=True, now=now)

    def test_monotonic_publication_and_corrupt_or_missing_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            first = self.envelope(2)
            with self.assertRaises(ValueError): publish(directory, first, self.public, self.bootstrap)
            publish(directory, first, self.public, self.bootstrap, initialize=True)
            destination = directory / 'routes.json'
            inode = destination.stat().st_ino
            publish(directory, first, self.public, self.bootstrap)
            self.assertEqual(destination.stat().st_ino, inode)
            self.assertEqual(destination.stat().st_mode & 0o777, 0o644)
            conflict = deepcopy(self.bootstrap)
            conflict['edges'][0]['turn_host'] = 'changed.example.com'
            for candidate in (self.envelope(1), self.envelope(2, config=conflict)):
                with self.assertRaises(ValueError): publish(directory, candidate, self.public, self.bootstrap)
                self.assertEqual(destination.read_bytes(), first)
            with self.assertRaises(ValueError): publish(directory, first, self.public, self.bootstrap, initialize=True)
            destination.write_bytes(b'broken state')
            with self.assertRaises(ValueError): publish(directory, self.envelope(3), self.public, self.bootstrap)
            self.assertEqual(destination.read_bytes(), b'broken state')
            now = int(time.time())
            destination.write_bytes(self.envelope(2, issued=now-7200, expires=now-1))
            publish(directory, self.envelope(3), self.public, self.bootstrap)
            self.assertEqual(verify(read_envelope(destination), self.public, self.bootstrap).revision, 3)

    def test_interrupted_write_preserves_signed_state_and_concurrent_writers_cannot_roll_back(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            first = self.envelope()
            publish(directory, first, self.public, self.bootstrap, initialize=True)
            with patch('publish_catalog.os.replace', side_effect=OSError('simulated failure')):
                with self.assertRaises(OSError): publish(directory, self.envelope(2), self.public, self.bootstrap)
            self.assertEqual(read_envelope(directory / 'routes.json'), first)
            self.assertFalse(list(directory.glob('.routes-*')))
            candidates = [self.envelope(n) for n in (4, 2, 5, 3)]
            def writer(candidate):
                try: return publish(directory, candidate, self.public, self.bootstrap).revision
                except ValueError: return None  # A newer concurrent writer may already have committed.
            with ThreadPoolExecutor(max_workers=4) as pool:
                results = list(pool.map(writer, candidates))
            self.assertIn(5, results)
            self.assertEqual(verify(read_envelope(directory / 'routes.json'), self.public, self.bootstrap).revision, 5)

    def test_invalid_catalog_does_not_touch_directory_and_reads_are_bounded(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaises(ValueError): publish(directory, b'{}', self.public, self.bootstrap, initialize=True)
            self.assertEqual(list(directory.iterdir()), [])
            path = directory / 'oversized'
            path.write_bytes(b'x' * 65537)
            with self.assertRaises(ValueError): read_envelope(path)


if __name__ == '__main__':
    unittest.main()
