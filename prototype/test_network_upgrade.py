from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import network_bootstrap
import network_runtime
from test_tunnel_runtime import state


class NetworkUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state_root = self.root / 'var/lib/voicechat-network'
        self.state_root.mkdir(mode=0o700, parents=True)
        self.value = {**state(), 'edge_subnet': '10.241.0.0/28'}
        managed_state.persist(self.state_root / 'desired.json', self.value)
        key = self.root / 'etc/ssh/ssh_host_ed25519_key.pub'
        key.parent.mkdir(parents=True)
        key.write_text(self.value['inventory']['core']['ssh_host_key'])
        self.calls = []
        self.fail_reload = False
        self.old = network_bootstrap.install(self.root, run=self.command)
        self.source = self.root / 'new-source'
        self.source.mkdir()
        for name in (*network_bootstrap.SOURCES, 'voicechat-network.service', 'voicechat-docker-network.conf'):
            shutil.copyfile(ROOT / 'infra' / name, self.source / name)
        with (self.source / 'firewall_config.py').open('a') as output:
            output.write('\n# new reviewed policy source\n')
        self.enterContext(patch.object(network_bootstrap, '__file__', str(self.source / 'network_bootstrap.py')))
        self.enterContext(patch.object(network_runtime, '__file__', str(self.source / 'network_runtime.py')))
        self.calls.clear()

    def command(self, *args):
        self.calls.append(args)
        if args == ('systemctl', 'show', '--property=SystemState', '--value'): return 'running'
        if args[:3] == ('systemctl', 'show', 'docker.service'): return 'MainPID=42\nExecMainStartTimestampMonotonic=123\n'
        if args[:2] == ('systemctl', 'reload'):
            if self.fail_reload: raise RuntimeError('Injected reload failure')
            managed_state.persist(self.state_root / 'applied.json', {'schema': 1,
                'sha256': network_runtime.fingerprint(self.value), 'phase': 'complete'})
        return ''

    def upgrade(self): return network_bootstrap.upgrade(self.root, run=self.command)

    def test_upgrade_uses_reload_preserves_old_sources_and_repeat_is_noop(self):
        digest = self.upgrade()
        self.assertNotEqual(digest, self.old)
        self.assertTrue((self.root / 'opt/voicechat/network' / self.old).is_dir())
        unit = (self.root / network_bootstrap.UNIT).read_text()
        self.assertIn('ExecReload=/usr/bin/python3 /opt/voicechat/network/' + digest, unit)
        self.assertTrue(any(call[:2] == ('systemctl', 'reload') for call in self.calls))
        self.assertFalse(any('restart' in call or 'stop' in call for call in self.calls))
        self.assertFalse((self.state_root / 'boot-install/upgrade.json').exists())
        self.calls.clear()
        self.assertEqual(self.upgrade(), digest)
        self.assertEqual(self.calls, [])

    def test_explicit_shared_host_upgrade_is_preserved_by_later_default_retry(self):
        digest = network_bootstrap.upgrade(self.root, run=self.command, shared_host=True)
        drop_in = (self.root / network_bootstrap.DROP_IN).read_text()
        self.assertIn('Wants=voicechat-network.service', drop_in)
        self.calls.clear()
        self.assertEqual(self.upgrade(), digest)
        self.assertTrue(all(call[:2] == ('docker', 'ps') for call in self.calls))
        self.assertNotIn('Requires=voicechat-network.service', (self.root / network_bootstrap.DROP_IN).read_text())

    def test_failed_reload_keeps_journal_and_resumes_same_source(self):
        self.fail_reload = True
        with self.assertRaisesRegex(RuntimeError, 'reload failure'): self.upgrade()
        before = managed_state.read(self.state_root / 'boot-install/desired.json')
        self.assertEqual(before['source_sha256'], self.old)
        self.assertTrue((self.state_root / 'boot-install/upgrade.json').exists())
        with self.assertRaisesRegex(ValueError, 'pending'): network_bootstrap.install(self.root, run=self.command)
        self.fail_reload = False
        self.assertNotEqual(self.upgrade(), self.old)
        self.assertFalse((self.state_root / 'boot-install/upgrade.json').exists())

    def test_interrupted_unit_replacement_resumes_without_losing_old_snapshot(self):
        original = network_bootstrap.replace_file
        def interrupted(path, content):
            original(path, content)
            raise OSError('Interrupted after replacing unit')
        with patch.object(network_bootstrap, 'replace_file', side_effect=interrupted):
            with self.assertRaises(OSError): self.upgrade()
        self.assertEqual(managed_state.read(self.state_root / 'boot-install/desired.json')['source_sha256'], self.old)
        self.assertNotEqual(self.upgrade(), self.old)

    def test_modified_old_sources_or_units_fail_before_journal_or_commands(self):
        path = self.root / 'opt/voicechat/network' / self.old / 'firewall_config.py'
        original = path.read_bytes()
        path.write_bytes(original + b'\n# unclaimed modification\n')
        with self.assertRaisesRegex(ValueError, 'checksums'): self.upgrade()
        self.assertEqual(self.calls, [])
        self.assertFalse((self.state_root / 'boot-install/upgrade.json').exists())
        path.write_bytes(original)
        (self.root / network_bootstrap.DROP_IN).write_text('foreign drop-in')
        with self.assertRaisesRegex(ValueError, 'checksums'): self.upgrade()
        self.assertEqual(self.calls, [])

    def test_pending_upgrade_rejects_a_different_target(self):
        self.fail_reload = True
        with self.assertRaises(RuntimeError): self.upgrade()
        (self.source / 'firewall_config.py').write_text('different code')
        with self.assertRaisesRegex(ValueError, 'same pending'): self.upgrade()

    def test_successful_command_without_new_policy_receipt_does_not_commit(self):
        def incomplete(*args):
            if args[:2] == ('systemctl', 'reload'): return ''
            return self.command(*args)
        managed_state.persist(self.state_root / 'applied.json', {'schema': 1, 'sha256': '0' * 64, 'phase': 'complete'})
        with self.assertRaisesRegex(ValueError, 'not successfully applied'):
            network_bootstrap.upgrade(self.root, run=incomplete)
        self.assertEqual(managed_state.read(self.state_root / 'boot-install/desired.json')['source_sha256'], self.old)
        self.assertTrue((self.state_root / 'boot-install/upgrade.json').exists())


if __name__ == '__main__': unittest.main()
