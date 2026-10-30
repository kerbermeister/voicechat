from copy import deepcopy
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import tls_material
from topology import load


def command(*args):
    return subprocess.run(['openssl', *map(str, args)], check=True, capture_output=True).stdout


class TLSMaterialTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='voicechat-test-tls-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.public = load(ROOT / 'infra/three-vps.example.json')
        key = cls.root / 'ca.key'
        key.touch(mode=0o600)
        command('req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
                '-nodes', '-keyout', key, '-out', cls.root / 'ca.crt', '-days', '30',
                '-subj', '/CN=Disposable Test CA', '-addext', 'basicConstraints=critical,CA:TRUE',
                '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
        cls.certificate('intermediate', [], ca=True, days=20)
        cls.web_names = tls_material.names(cls.public, 'b', 'web')
        cls.turn_names = tls_material.names(cls.public, 'b', 'turn')
        cls.certificate('web', cls.web_names)
        cls.certificate('renewed', cls.web_names)
        cls.certificate('turn', cls.turn_names)
        cls.certificate('short', cls.web_names, days=2)
        cls.certificate('expired', cls.web_names, days=0)
        cls.certificate('client', cls.web_names, purpose='clientAuth')
        cls.certificate('cn-only', [], common_name=cls.web_names[0])
        cls.certificate('leaf-only-name', cls.web_names[:1])

    @classmethod
    def certificate(cls, stem, names, *, ca=False, days=10, purpose='serverAuth', common_name='Fixture'):
        key, csr = cls.root / (stem + '.key'), cls.root / (stem + '.csr')
        key.touch(mode=0o600)
        command('req', '-new', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
                '-nodes', '-keyout', key, '-out', csr, '-subj', '/CN=' + common_name)
        ext = cls.root / (stem + '.ext')
        ext.write_text(('basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' if ca else
                        'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=' + purpose + '\n') +
                       'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n' +
                       ('subjectAltName=' + ','.join('DNS:' + name for name in names) + '\n' if names else ''))
        issuer = 'ca' if ca else 'intermediate'
        cert = cls.root / (stem + '.crt')
        command('x509', '-req', '-in', csr, '-CA', cls.root / (issuer + '.crt'),
                '-CAkey', cls.root / (issuer + '.key'), '-CAcreateserial', '-out', cert,
                '-days', days, '-extfile', ext)
        (cls.root / (stem + '.chain')).write_bytes(cert.read_bytes() +
            (b'' if ca else (cls.root / 'intermediate.crt').read_bytes()))

    def stage(self, store, stem='web', **kwargs):
        return tls_material.stage(store, self.public, 'b', 'web',
            self.root / (stem + '.chain'), self.root / (stem + '.key'),
            ca_file=self.root / 'ca.crt', **kwargs)

    def test_full_chain_names_key_and_repeat_without_rewrite(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Path(directory) / 'tls'
            result = self.stage(store)
            self.assertEqual((result / 'web.crt').read_bytes(), (self.root / 'web.chain').read_bytes())
            self.assertEqual(result.stat().st_mode & 0o777, 0o700)
            before = (result / 'web.key').stat()
            self.assertEqual(before.st_mode & 0o777, 0o600)
            self.assertEqual(result, self.stage(store))
            self.assertEqual(before.st_mtime_ns, (result / 'web.key').stat().st_mtime_ns)
            turn = tls_material.stage(store, self.public, 'b', 'turn', self.root / 'turn.chain',
                self.root / 'turn.key', ca_file=self.root / 'ca.crt')
            self.assertEqual({p.name for p in turn.iterdir()}, {'turn.crt', 'turn.key'})
            renewed = self.stage(store, 'renewed')
            self.assertNotEqual(result, renewed)
            self.assertTrue((result / 'web.key').exists())

    def test_reject_wrong_name_purpose_expiry_cn_and_chain_without_creating_store(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Path(directory) / 'tls'
            for stem in ('turn', 'client', 'short', 'expired', 'cn-only', 'leaf-only-name'):
                with self.subTest(stem=stem), self.assertRaises(ValueError): self.stage(store, stem)
                self.assertFalse(store.exists())
            for chain, key, ca in [('web.crt', 'web.key', 'ca.crt'),
                                   ('web.chain', 'turn.key', 'ca.crt'),
                                   ('web.chain', 'web.key', None)]:
                with self.subTest(chain=chain, key=key, ca=ca), self.assertRaises(ValueError):
                    tls_material.stage(store, self.public, 'b', 'web', self.root / chain, self.root / key,
                                       ca_file=self.root / ca if ca else None)
                self.assertFalse(store.exists())
            self.stage(store, 'short', minimum_validity_days=1)

    def test_bad_inputs_and_encrypted_key_fail_without_prompt_or_secret_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key = root / 'key'
            key.write_bytes((self.root / 'web.key').read_bytes())
            key.chmod(0o644)
            with self.assertRaisesRegex(ValueError, 'owner-only'):
                tls_material.stage(root / 'store', self.public, 'b', 'web', self.root / 'web.chain', key)
            key.unlink(); key.symlink_to(self.root / 'web.key')
            with self.assertRaises(OSError): tls_material.read_material(key, private=True)
            key.unlink(); os.mkfifo(key)
            with self.assertRaises(ValueError): tls_material.read_material(key, private=True)
            key.unlink(); key.write_bytes(b'x' * 262145)
            with self.assertRaises(ValueError): tls_material.read_material(key)
            key.unlink(); key.touch(mode=0o600)
            command('pkey', '-in', self.root / 'web.key', '-aes256', '-passout', 'pass:fixture-secret', '-out', key)
            with self.assertRaisesRegex(ValueError, 'unencrypted') as error:
                tls_material.stage(root / 'store', self.public, 'b', 'web', self.root / 'web.chain', key)
            self.assertNotIn('fixture-secret', str(error.exception))
            for days in (0, 91, True):
                with self.assertRaises(ValueError): self.stage(root / 'store', minimum_validity_days=days)
            chain = root / 'chain'
            chain.write_bytes((self.root / 'web.chain').read_bytes() + b'garbage')
            with self.assertRaisesRegex(ValueError, 'PEM'):
                tls_material.stage(root / 'store', self.public, 'b', 'web', chain, self.root / 'web.key')

    def test_failed_staging_preserves_previous_and_tampered_generation_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Path(directory) / 'tls'
            previous = self.stage(store)
            with patch.object(tls_material.os, 'rename', side_effect=OSError('disk failure')):
                with self.assertRaises(OSError): self.stage(store, 'renewed')
            self.assertEqual({p.name for p in store.iterdir()}, {previous.name, 'apply.lock'})
            self.assertEqual(self.stage(store), previous)
            path = previous / 'web.key'
            path.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'modified'): self.stage(store)
            path.unlink(); path.symlink_to(self.root / 'web.key')
            with self.assertRaises(OSError): self.stage(store)

    def test_names_cover_canonical_and_reject_unknown_role(self):
        self.assertIn(self.public['canonical_origin'].removeprefix('https://'), self.web_names)
        self.assertEqual(len(self.web_names), 2)
        for edge, service in [('missing', 'web'), ('b', '../key')]:
            with self.assertRaises(ValueError): tls_material.names(self.public, edge, service)
        public = deepcopy(self.public)
        public['edges'][0]['origin'] = 'https://b.example.com:8443'
        with self.assertRaises(ValueError): tls_material.names(public, 'b', 'web')


if __name__ == '__main__': unittest.main()
