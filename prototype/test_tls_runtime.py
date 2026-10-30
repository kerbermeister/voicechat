from copy import deepcopy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import tls_runtime
from check_route_tls import certificate


class TLSRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='voicechat-publish-test-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.source = Path(cls.temporary.name)
        (cls.source / 'ca.key').touch(mode=0o600)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
            '-nodes', '-days', '30', '-keyout', str(cls.source / 'ca.key'), '-out', str(cls.source / 'ca.crt'),
            '-subj', '/CN=Disposable Publisher CA', '-addext', 'basicConstraints=critical,CA:TRUE',
            '-addext', 'keyUsage=critical,keyCertSign,cRLSign'], check=True, capture_output=True)
        cls.public = {'schema': 1, 'service_id': 'fixture', 'matrix_server_name': 'web.routes.test',
            'canonical_origin': 'https://web.routes.test', 'web_origins': ['https://web.routes.test'],
            'edges': [{'id': 'b', 'origin': 'https://web.routes.test', 'turn_host': 'turn.routes.test'}]}
        for stem in ('old', 'new'):
            certificate(cls.source, 'web.routes.test')
            for suffix in ('crt', 'key'):
                target = cls.source / (stem + '.' + suffix)
                target.touch(mode=0o600)
                shutil.copyfile(cls.source / ('web.routes.test.' + suffix), target)
        certificate(cls.source, 'turn.routes.test')
        (cls.source / 'turn.routes.test.key').chmod(0o600)

    def setUp(self):
        self.runtime = tempfile.TemporaryDirectory()
        self.addCleanup(self.runtime.cleanup)
        self.root = Path(self.runtime.name) / 'tls'

    def publish(self, stem='old', **kwargs):
        return tls_runtime.publish(self.root, self.public, 'b', 'web', self.source / (stem + '.crt'),
            self.source / (stem + '.key'), ca_file=self.source / 'ca.crt', minimum_validity_days=1, **kwargs)

    def test_initial_rotation_repeat_and_rollback_keep_complete_pairs(self):
        self.root.mkdir(mode=0o700)
        (self.root / 'web').mkdir(mode=0o700)
        old = self.publish()
        self.assertIsNone(old['previous'])
        old_key = (self.root / 'web/web.key').read_bytes()
        renewed = self.publish('new')
        self.assertEqual(renewed['previous'], old['generation'])
        self.assertNotEqual((self.root / 'web/web.key').read_bytes(), old_key)
        self.assertEqual(self.publish('new'), renewed)
        old_path = self.root / 'web/generations' / old['generation'] / 'web.key'
        self.assertEqual(old_path.read_bytes(), old_key)
        self.assertEqual(old_path.stat().st_mode & 0o777, 0o600)
        rollback = self.publish()
        self.assertEqual(rollback['previous'], renewed['generation'])
        self.assertEqual((self.root / 'web/web.key').read_bytes(), old_key)
        self.assertEqual(json.loads((self.root / 'web.json').read_text())['phase'], 'selected')
        self.assertTrue(rollback['reload_required'])

    def test_resume_before_and_after_selector_without_accepting_other_generation(self):
        old = self.publish()
        replace = os.replace
        def interrupted(source, destination):
            if Path(destination).name == 'current': raise OSError('interrupt before selection')
            return replace(source, destination)
        with patch.object(tls_runtime.os, 'replace', side_effect=interrupted):
            with self.assertRaises(OSError): self.publish('new')
        self.assertEqual(tls_runtime.link_target(self.root / 'web/current'), old['generation'])
        with self.assertRaisesRegex(ValueError, 'interrupted'): self.publish('old')
        persist = managed_state.persist
        def interrupted_receipt(path, value):
            if path.name == 'web.json' and value.get('phase') == 'selected': raise OSError('interrupt after selection')
            return persist(path, value)
        with patch.object(managed_state, 'persist', side_effect=interrupted_receipt):
            with self.assertRaises(OSError): self.publish('new')
        new_selected = tls_runtime.link_target(self.root / 'web/current')
        self.assertNotEqual(new_selected, old['generation'])
        self.assertEqual(self.publish('new')['generation'], new_selected)

    def test_resume_partial_copy_and_invalid_input_never_select_partial_pair(self):
        self.publish()
        old_target = os.readlink(self.root / 'web/current')
        write = tls_runtime.write_serving
        count = 0
        def fail_second(*args):
            nonlocal count
            count += 1
            if count == 2: raise OSError('disk full')
            return write(*args)
        with patch.object(tls_runtime, 'write_serving', side_effect=fail_second):
            with self.assertRaises(OSError): self.publish('new')
        self.assertEqual(os.readlink(self.root / 'web/current'), old_target)
        self.publish('new')
        selected = os.readlink(self.root / 'web/current')
        with self.assertRaises(ValueError): self.publish('turn.routes.test')
        self.assertEqual(os.readlink(self.root / 'web/current'), selected)

    def test_foreign_files_symlinks_and_changed_generation_are_not_overwritten(self):
        self.root.mkdir(mode=0o700)
        (self.root / 'web').symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'adopt'): self.publish()
        (self.root / 'web').unlink()
        result = self.publish()
        selected = self.root / 'web/generations' / result['generation'] / 'web.key'
        selected.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'modified'): self.publish()
        self.assertEqual(selected.read_bytes(), b'changed')

    def test_identity_and_parallel_writer_guards(self):
        self.publish()
        original = deepcopy(self.public)
        self.public = {**original, 'service_id': 'foreign'}
        with self.assertRaisesRegex(ValueError, 'foreign'): self.publish()
        self.public = original
        with managed_state.locked(self.root):
            with self.assertRaises(BlockingIOError): self.publish()


if __name__ == '__main__': unittest.main()
