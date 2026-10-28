from copy import deepcopy
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import edge_deploy
import managed_state
import role_prepare
import role_release
from test_node_inventory import fixture
from topology import load


class RolePrepareTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / 'edge'
        self.public = load(ROOT / 'infra/three-vps.example.json')
        self.inventory = fixture()
        self.image = 'ghcr.io/fixture/web@sha256:' + '1' * 64
        self.manifest = role_release.make(self.public, self.inventory, 'edge', 'a' * 40, self.image, 'b')

    def prepare(self, manifest=None):
        return role_prepare.prepare(self.root, self.public, self.inventory, manifest or self.manifest)

    def test_repeat_preserves_runtime_and_config_only_release_coexists(self):
        first = self.prepare()
        record = edge_deploy.record_for(self.public, self.inventory, self.manifest)
        self.assertEqual(edge_deploy.release_path(self.root, record), first)
        secret = self.root / 'runtime/turn-secret'
        secret.write_text('synthetic-existing-secret')
        before = {path: path.stat().st_mtime_ns for path in first.rglob('*') if path.is_file()}
        self.assertEqual(self.prepare(), first)
        self.assertEqual(before, {path: path.stat().st_mtime_ns for path in first.rglob('*') if path.is_file()})
        self.assertEqual((first / 'infra/runtime').resolve(), self.root / 'runtime')
        self.public['web_origins'].append('https://fallback.example.com')
        changed = role_release.make(self.public, self.inventory, 'edge', 'a' * 40, self.image, 'b')
        second = self.prepare(changed)
        self.assertNotEqual(first, second)
        self.assertEqual(secret.read_text(), 'synthetic-existing-secret')
        self.assertEqual(managed_state.read(first / 'release.json'), self.manifest)
        self.assertEqual(managed_state.read(second / 'release.json'), changed)
        self.assertFalse((self.root / 'state.json').exists())

    def test_subsequent_release_preserves_tls_publishers_serving_permissions(self):
        self.prepare()
        serving = self.root / 'runtime/tls/turn'
        serving.mkdir(mode=0o750)
        serving.chmod(0o750)
        (serving / 'turn.key').write_text('synthetic-serving-material')
        manifest = role_release.make(self.public, self.inventory, 'edge', 'b' * 40, self.image, 'b')
        self.prepare(manifest)
        self.assertEqual(serving.stat().st_mode & 0o777, 0o750)
        self.assertEqual((serving / 'turn.key').read_text(), 'synthetic-serving-material')

    def test_core_role_has_no_generated_secrets_or_service_side_effects(self):
        core = role_release.make(self.public, self.inventory, 'core', 'a' * 40, self.image)
        target = self.prepare(core)
        self.assertEqual(list((self.root / 'runtime').iterdir()), [])
        self.assertEqual(managed_state.read(target / 'release.json'), core)
        with self.assertRaisesRegex(ValueError, 'another identity'): self.prepare()

    def test_unreviewed_manifest_and_foreign_root_are_not_adopted(self):
        changed = deepcopy(self.manifest)
        changed['files']['infra/Caddyfile'] = '0' * 64
        with self.assertRaises(ValueError): self.prepare(changed)
        self.assertFalse(self.root.exists())
        self.root.mkdir(mode=0o700)
        (self.root / 'unclaimed').write_text('retain')
        with self.assertRaisesRegex(ValueError, 'adoption'): self.prepare()
        self.assertEqual((self.root / 'unclaimed').read_text(), 'retain')
        self.assertFalse((self.root / 'role.json').exists())

    def test_interrupted_staging_resumes_without_partial_release(self):
        original = role_prepare.write_bundle
        def interrupted(*args):
            original(*args)
            raise OSError('injected staging interruption')
        with patch.object(role_prepare, 'write_bundle', side_effect=interrupted):
            with self.assertRaises(OSError): self.prepare()
        self.assertFalse(list((self.root / 'releases').iterdir()))
        self.assertTrue((self.root / 'role.json').is_file())
        self.assertTrue(self.prepare().is_dir())

    def test_tampering_symlinks_and_concurrent_writer_are_rejected(self):
        first = self.prepare()
        with managed_state.locked(self.root):
            with self.assertRaises(BlockingIOError): self.prepare()
        source = first / 'infra/Caddyfile'
        original = source.read_bytes()
        source.write_bytes(original + b'\n# changed\n')
        with self.assertRaises(ValueError): self.prepare()
        source.write_bytes(original)
        (first / 'infra/runtime').unlink()
        (first / 'infra/runtime').symlink_to(self.root)
        with self.assertRaises(ValueError): self.prepare()
        (first / 'infra/runtime').unlink()
        (first / 'infra/runtime').symlink_to(self.root / 'runtime')
        catalog = self.root / 'runtime/catalog'
        catalog.rmdir(); catalog.symlink_to(self.root)
        with self.assertRaises(ValueError): self.prepare()


if __name__ == '__main__': unittest.main()
