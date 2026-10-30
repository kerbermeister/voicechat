import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import host_packages
import managed_state
from test_host_preflight import facts
from test_node_inventory import fixture, key


class Apt:
    def __init__(self):
        self.rows = {'python3': ('ii ', '3.11.2-1+b1')}
        self.calls = []
        self.fail = None
        self.rootless = False
        self.nftables = 'inactive'

    def __call__(self, args):
        self.calls.append(args)
        if args[:3] == ['systemctl', 'show', 'nftables.service']:
            return self.nftables
        if args[0] == 'dpkg-query':
            return ''.join(name + '\t' + status + '\t' + version + '\n'
                           for name, (status, version) in self.rows.items())
        if args[:2] == ['dpkg', '--audit']:
            return ''
        if args[:2] == ['dpkg', '--configure']:
            self.rows = {name: ('ii ', version) for name, (_, version) in self.rows.items()}
            return ''
        if args[0] == 'apt-get':
            if args[1] == 'update':
                return ''
            specs = [arg.split('=', 1) for arg in args if '=' in arg]
            if '--simulate' in args:
                return ''.join('Inst ' + name + ' (' + version + ' repository [amd64])\n'
                               for name, version in specs)
            if self.fail:
                self.fail = None
                name, version = specs[0]
                self.rows[name] = ('iU ', version)
                raise RuntimeError('Interrupted fixture apt transaction')
            self.rows.update({name: ('ii ', version) for name, version in specs})
            return ''
        if args[:2] == ['docker', 'info']:
            return '/var/lib/docker' if 'DockerRootDir' in args[-1] else ('["rootless"]' if self.rootless else '[]')
        raise AssertionError(args)


class HostPackagesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.inventory = fixture()
        self.facts = facts(self.inventory)
        ssh = self.root / 'etc/ssh'
        ssh.mkdir(parents=True)
        (ssh / 'ssh_host_ed25519_key.pub').write_text(self.inventory['core']['ssh_host_key'] + '\n')
        self.apt = Apt()
        self.state = self.root / 'state'
        self.key = b'public synthetic signing key fixture'
        self.enterContext(patch.object(host_packages, 'KEY_SHA', hashlib.sha256(self.key).hexdigest()))
        self.enterContext(patch.multiple(host_packages.platform, system=lambda: 'Linux',
                          machine=lambda: 'x86_64', freedesktop_os_release=lambda: {'ID': 'debian', 'VERSION_ID': '12'}))

    def install(self, **kwargs):
        return host_packages.install(self.state, self.inventory, 'core', system_root=self.root,
                                     run=self.apt, collect=lambda _: self.facts,
                                     download=lambda: self.key, **kwargs)

    def test_install_repeat_and_lost_commit_reply_never_reinstall(self):
        with patch.object(host_packages, 'clear_pending', side_effect=RuntimeError('lost commit result')):
            with self.assertRaisesRegex(RuntimeError, 'lost commit'):
                self.install()
        self.assertTrue((self.state / 'current.json').exists())
        self.assertTrue((self.state / 'pending.json').exists())
        self.apt.calls.clear()
        target = self.install()
        self.assertFalse((self.state / 'pending.json').exists())
        self.assertEqual(target, managed_state.read(self.state / 'current.json'))
        self.assertFalse(any(args[0] in ('apt-get', 'dpkg') for args in self.apt.calls))
        self.apt.calls.clear()
        self.assertEqual(target, self.install())
        self.assertFalse(any(args[0] == 'apt-get' for args in self.apt.calls))

    def test_resume_configures_only_recorded_package_closure(self):
        self.apt.fail = True
        with self.assertRaisesRegex(RuntimeError, 'Interrupted fixture'):
            self.install()
        journal = managed_state.read(self.state / 'pending.json')
        self.assertEqual(journal['phase'], 'base')
        self.assertIn('ca-certificates', journal['packages'])
        self.install()
        self.assertIn(['dpkg', '--configure', '--pending'], self.apt.calls)
        host_packages.verify_versions(self.apt.rows)

    def test_unrelated_package_and_container_data_block_resume(self):
        self.apt.fail = True
        with self.assertRaises(RuntimeError):
            self.install()
        self.apt.rows['foreign-service'] = ('iU ', '1')
        self.apt.calls.clear()
        with self.assertRaisesRegex(ValueError, 'unrelated unfinished'):
            self.install()
        self.assertFalse(any(args[0] in ('apt-get', 'dpkg') for args in self.apt.calls))
        del self.apt.rows['foreign-service']
        containers = self.root / 'var/lib/docker/containers'
        containers.mkdir(parents=True)
        (containers / 'foreign-container').mkdir()
        self.apt.calls.clear()
        with self.assertRaisesRegex(ValueError, 'Container data appeared'):
            self.install()
        self.assertFalse(any(args[0] in ('apt-get', 'dpkg') for args in self.apt.calls))

    def test_wrong_host_existing_runtime_repository_and_bad_key_fail_closed(self):
        host = self.root / 'etc/ssh/ssh_host_ed25519_key.pub'
        host.write_text(key(9))
        with self.assertRaisesRegex(ValueError, 'another SSH host'):
            self.install()
        self.assertFalse(self.apt.calls)
        host.write_text(self.inventory['core']['ssh_host_key'])
        self.apt.rows['docker.io'] = ('ii ', '20')
        with self.assertRaisesRegex(ValueError, 'explicit adoption'):
            self.install()
        self.assertFalse((self.state / 'pending.json').exists())
        del self.apt.rows['docker.io']
        sources = self.root / 'etc/apt/sources.list.d'
        sources.mkdir(parents=True)
        foreign = sources / 'provider.sources'
        foreign.write_text('URIs: https://download.docker.com/linux/debian\n')
        with self.assertRaisesRegex(ValueError, 'repository requires explicit adoption'):
            self.install()
        self.assertEqual(foreign.read_text(), 'URIs: https://download.docker.com/linux/debian\n')
        foreign.unlink()
        with patch.object(host_packages, 'KEY_SHA', 'a' * 64):
            with self.assertRaisesRegex(ValueError, 'signing key differs'):
                self.install()
        self.assertFalse((self.root / host_packages.SOURCE_PATH).exists())

    def test_completed_profile_or_runtime_drift_never_triggers_upgrade(self):
        self.install()
        self.apt.calls.clear()
        with patch.dict(host_packages.DOCKER, {'docker-ce': 'different'}):
            with self.assertRaisesRegex(ValueError, 'explicit upgrade'):
                self.install()
        self.assertFalse(any(args[0] == 'apt-get' for args in self.apt.calls))
        self.apt.rootless = True
        with self.assertRaisesRegex(ValueError, 'rootful Docker'):
            self.install()
        self.assertFalse(any(args[0] == 'apt-get' for args in self.apt.calls))

    def test_clock_and_platform_fail_before_package_mutation(self):
        with patch.object(host_packages.platform, 'machine', return_value='aarch64'):
            with self.assertRaisesRegex(ValueError, 'Debian 12 amd64'):
                self.install()
        self.assertFalse(self.apt.calls)
        self.facts['ntp'] = False
        with self.assertRaisesRegex(ValueError, 'inspection failed'):
            self.install()
        self.assertFalse((self.state / 'pending.json').exists())
        self.assertFalse(any(args[0] == 'apt-get' for args in self.apt.calls))

    def test_active_nftables_service_is_preserved_without_apt_or_stop(self):
        self.apt.nftables = 'active'
        with self.assertRaisesRegex(ValueError, 'do not stop it'):
            self.install()
        self.assertFalse((self.state / 'pending.json').exists())
        self.assertEqual(len(self.apt.calls), 1)
        self.assertEqual(self.apt.calls[0][:3], ['systemctl', 'show', 'nftables.service'])

    def test_apt_simulation_rejects_removal_malformed_and_unbounded_closure(self):
        with self.assertRaisesRegex(ValueError, 'remove packages'):
            host_packages.closure('Remv foreign-service [1]\n', ['nftables'])
        with self.assertRaises(ValueError):
            host_packages.closure('Inst ../../foreign\n', [])
        with self.assertRaises(ValueError):
            host_packages.closure(''.join('Inst package' + str(n) + ' (1)\n' for n in range(257)), [])
        self.assertEqual(host_packages.closure('Inst libdependency (1)\nConf libdependency (1)\n', ['nftables']),
                         ['libdependency', 'nftables'])


if __name__ == '__main__':
    unittest.main()
