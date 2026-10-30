import hashlib
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import role_bootstrap
import role_prepare
import role_release
from test_node_inventory import fixture
from topology import load


class RoleBootInstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.root, self.system = self.directory / 'core', self.directory / 'host'
        self.system.mkdir()
        public = load(ROOT / 'infra/three-vps.example.json')
        manifest = role_release.make(public, fixture(), 'core', 'a' * 40, 'ghcr.io/fixture/control@sha256:' + 'a' * 64)
        role_prepare.prepare(self.root, public, fixture(), manifest)
        self.calls = []
        self.fail_enable = False

    def command(self, *args):
        self.calls.append(args)
        if self.fail_enable and args[:2] == ('systemctl', 'enable'): raise RuntimeError('Enable interrupted')
        return ''

    def install(self):
        return role_bootstrap.install(self.root, 'core', system_root=self.system, run=self.command)

    def ready(self):
        return role_bootstrap.ready(self.root, 'core', system_root=self.system, run=self.command)

    def test_installs_verified_sources_and_per_role_dependency_without_starting_services(self):
        record = self.install()
        self.ready()
        unit = (self.system / 'etc/systemd/system/voicechat-core.service').read_text()
        self.assertIn('Requires=docker.service voicechat-network.service', unit)
        self.assertIn('After=docker.service voicechat-network.service', unit)
        self.assertIn('WantedBy=docker.service', unit)
        self.assertIn('PartOf=docker.service', unit)
        self.assertIn(record['operator_sha256'], unit)
        self.assertFalse(any(value in ('start', 'stop', 'restart') for call in self.calls for value in call))
        self.assertEqual(self.install(), record)
        self.assertFalse((self.root / 'runtime/boot/pending.json').exists())

    def test_source_only_package_does_not_claim_a_unit_and_legacy_roster_upgrades(self):
        _, code, contents, _, record = role_bootstrap.plan(self.root, 'core', None)
        role_bootstrap.install_sources(self.system, code, contents)
        role_bootstrap.verify_record(self.system, record)
        self.assertFalse((self.system / 'etc/systemd/system/voicechat-core.service').exists())
        self.assertEqual(self.calls, [])
        with patch.object(role_bootstrap, 'SOURCES', role_bootstrap.LEGACY_SOURCES):
            previous = self.install()
        current = self.install()
        self.assertNotEqual(previous['operator_sha256'], current['operator_sha256'])
        role_bootstrap.verify_record(self.system, previous)
        self.ready()

    def test_interrupted_enable_blocks_deployment_and_resumes_same_source(self):
        self.fail_enable = True
        with self.assertRaises(RuntimeError): self.install()
        with self.assertRaisesRegex(ValueError, 'interrupted'): self.ready()
        self.fail_enable = False
        self.install()
        self.ready()

    def test_unclaimed_unit_tampering_and_import_shadowing_are_refused(self):
        unit = self.system / 'etc/systemd/system/voicechat-core.service'
        unit.parent.mkdir(parents=True)
        unit.write_text('foreign')
        with self.assertRaisesRegex(ValueError, 'unclaimed'): self.install()
        self.assertEqual(unit.read_text(), 'foreign')
        unit.unlink()
        record = self.install()
        code = self.system / 'opt/voicechat/operators' / record['operator_sha256'] / 'infra'
        (code / 'json.py').write_text('foreign import')
        with self.assertRaisesRegex(ValueError, 'source set'): self.ready()
        (code / 'json.py').unlink()
        (code / 'core_deploy.py').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'source changed'): self.install()

    def test_source_upgrade_keeps_old_operators_and_rejects_new_source_while_pending(self):
        before = self.install()
        source = self.directory / 'new-source'
        source.mkdir()
        for name in role_bootstrap.SOURCES: shutil.copyfile(ROOT / 'infra' / name, source / name)
        with (source / 'core_deploy.py').open('a') as output: output.write('\n# reviewed new operator\n')
        with patch.object(role_bootstrap, '__file__', str(source / 'role_bootstrap.py')):
            with self.assertRaisesRegex(ValueError, 'reviewed role boot'): self.ready()
            self.fail_enable = True
            with self.assertRaises(RuntimeError): self.install()
            with (source / 'core_deploy.py').open('a') as output: output.write('# another target\n')
            with self.assertRaisesRegex(ValueError, 'same pending'): self.install()
            text = (source / 'core_deploy.py').read_text().removesuffix('# another target\n')
            (source / 'core_deploy.py').write_text(text)
            self.fail_enable = False
            after = self.install()
            self.ready()
        self.assertNotEqual(before['operator_sha256'], after['operator_sha256'])
        self.assertTrue((self.system / 'opt/voicechat/operators' / before['operator_sha256']).is_dir())


if __name__ == '__main__': unittest.main()
