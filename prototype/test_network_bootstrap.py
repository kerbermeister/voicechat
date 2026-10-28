from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import network_bootstrap
from test_tunnel_runtime import state


class NetworkBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state_root = self.root / 'var/lib/voicechat-network'
        self.state_root.mkdir(mode=0o700, parents=True)
        self.value = {**state(), 'edge_subnet': '10.241.0.0/28'}
        managed_state.persist(self.state_root / 'desired.json', self.value)
        self.key = self.root / 'etc/ssh/ssh_host_ed25519_key.pub'
        self.key.parent.mkdir(parents=True)
        self.key.write_text(self.value['inventory']['core']['ssh_host_key'])
        self.calls = []
        self.fail_start = False

    def command(self, *args):
        self.calls.append(args)
        if args == ('systemctl', 'show', '--property=SystemState', '--value'): return 'running'
        if self.fail_start and args[:2] == ('systemctl', 'start'):
            raise RuntimeError('Injected boot unit failure')
        return ''

    def install(self):
        return network_bootstrap.install(self.root, run=self.command)

    def test_owned_repeat_preserves_files_and_does_not_restart_docker(self):
        digest = self.install()
        files = [path for path in (self.root / 'opt').rglob('*') if path.is_file()]
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in files}
        program = self.root / 'opt/voicechat/network' / digest / 'network_runtime.py'
        help_result = subprocess.run([sys.executable, '-B', str(program), '--help'],
            cwd=self.root, env={**os.environ, 'PYTHONPATH': ''}, text=True, capture_output=True, check=True)
        self.assertIn('--directory', help_result.stdout)
        self.assertEqual(self.install(), digest)
        self.assertEqual(before, {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in files})
        unit = (self.root / network_bootstrap.UNIT).read_text()
        self.assertIn('/opt/voicechat/network/' + digest + '/network_runtime.py', unit)
        self.assertEqual(managed_state.read(self.state_root / 'boot-install/desired.json')['phase'], 'complete')
        self.assertFalse(any('docker' in part or 'restart' == part for call in self.calls for part in call))
        self.assertLess(next(i for i, call in enumerate(self.calls) if call[0] == 'systemd-analyze'),
                        next(i for i, call in enumerate(self.calls) if call[:2] == ('systemctl', 'daemon-reload')))

    def test_interrupted_copy_and_unit_start_resume_same_installation(self):
        original = network_bootstrap.create_file
        count = 0
        def interrupted(path, content):
            nonlocal count
            count += 1
            if count == 3: raise OSError('Injected copy failure')
            original(path, content)
        with patch.object(network_bootstrap, 'create_file', side_effect=interrupted):
            with self.assertRaises(OSError): self.install()
        self.assertEqual(managed_state.read(self.state_root / 'boot-install/desired.json')['phase'], 'prepared')
        self.fail_start = True
        with self.assertRaises(RuntimeError): self.install()
        self.assertEqual(managed_state.read(self.state_root / 'boot-install/desired.json')['phase'], 'prepared')
        self.fail_start = False
        self.install()
        self.assertEqual(managed_state.read(self.state_root / 'boot-install/desired.json')['phase'], 'complete')

    def test_wrong_host_foreign_file_symlink_and_modified_owned_file_are_rejected(self):
        self.key.write_text(self.value['inventory']['edges'][0]['ssh_host_key'])
        with self.assertRaisesRegex(ValueError, 'host does not match'): self.install()
        self.key.write_text(self.value['inventory']['core']['ssh_host_key'])
        unit = self.root / network_bootstrap.UNIT
        unit.parent.mkdir(parents=True)
        unit.write_text('foreign service')
        with self.assertRaisesRegex(ValueError, 'unclaimed'): self.install()
        self.assertEqual(unit.read_text(), 'foreign service')
        unit.unlink(); unit.symlink_to(self.key)
        with self.assertRaises(OSError): self.install()
        unit.unlink()
        digest = self.install()
        target = self.root / 'opt/voicechat/network' / digest / 'network_runtime.py'
        target.write_text('modified')
        with self.assertRaisesRegex(ValueError, 'modified'): self.install()
        self.assertEqual(target.read_text(), 'modified')

    def test_source_upgrade_or_existing_vendor_unit_requires_migration(self):
        def foreign_unit(*args):
            return 'voicechat-network.service enabled' if args[1:2] == ('list-unit-files',) else self.command(*args)
        with self.assertRaisesRegex(ValueError, 'already installed'):
            network_bootstrap.install(self.root, run=foreign_unit)
        self.install()
        source = self.root / 'source'
        source.mkdir()
        for name in (*network_bootstrap.SOURCES, 'voicechat-network.service', 'voicechat-docker-network.conf'):
            shutil.copyfile(ROOT / 'infra' / name, source / name)
        with (source / 'network_runtime.py').open('a') as output: output.write('\n# changed source\n')
        with patch.object(network_bootstrap, '__file__', str(source / 'network_bootstrap.py')):
            with self.assertRaisesRegex(ValueError, 'upgrade'): self.install()
