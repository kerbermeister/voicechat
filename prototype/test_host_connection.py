from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import host_connection
from test_node_inventory import fixture


class HostConnectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.key = Path(self.temporary.name) / 'private key'
        self.key.touch(mode=0o600)
        self.inventory = fixture()

    def test_only_verified_node_and_identity_are_used_and_arguments_remain_literal(self):
        self.inventory['ssh_port'] = 2222
        arguments = ['python3', '-c', 'import sys; print(sys.argv[1:])', '$(touch /tmp/bad)', 'a\nb', "x'y"]
        captured = []
        def run(command, **kwargs):
            path = Path(next(value.split('=', 1)[1] for value in command if value.startswith('UserKnownHostsFile=')))
            captured.append(path)
            self.assertEqual(path.read_text(), '[192.0.2.11]:2222 ' + self.inventory['edges'][0]['ssh_host_key'] + '\n')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(command[-2], self.inventory['ssh_user'] + '@192.0.2.11')
            self.assertEqual(shlex.split(command[-1]), arguments)
            for guard in ('StrictHostKeyChecking=yes', 'HostKeyAlgorithms=ssh-ed25519',
                          'IdentitiesOnly=yes', 'BatchMode=yes', 'UpdateHostKeys=no',
                          'ControlPath=none', 'ForwardAgent=no', 'GlobalKnownHostsFile=/dev/null'):
                self.assertIn(guard, command)
            self.assertEqual(kwargs['input'], b'private stdin')
            self.assertTrue(kwargs['check'])
            return subprocess.CompletedProcess(command, 0, b'ok', b'')
        with patch.object(host_connection.subprocess, 'run', side_effect=run):
            result = host_connection.execute(self.inventory, 'edge-b', self.key, arguments, input=b'private stdin')
        self.assertEqual(result.stdout, b'ok')
        self.assertFalse(captured[0].exists())

    def test_separate_endpoint_pins_same_inventory_key_without_forwarding_or_tofu(self):
        profile = {'identity_file': str(self.key), 'host': 'ssh.example.com', 'port': 2207, 'user': 'operator'}
        with host_connection.connection(self.inventory, 'edge-b', profile) as command:
            self.assertEqual(command[command.index('-p') + 1], '2207')
            self.assertEqual(command[-1], 'operator@ssh.example.com')
            trust = Path(next(value.split('=', 1)[1] for value in command if value.startswith('UserKnownHostsFile=')))
            self.assertEqual(trust.read_text(), '[ssh.example.com]:2207 ' + self.inventory['edges'][0]['ssh_host_key'] + '\n')
            for guard in ('StrictHostKeyChecking=yes', 'HostKeyAlgorithms=ssh-ed25519', 'ForwardAgent=no', 'ControlPath=none'):
                self.assertIn(guard, command)
        self.assertFalse(trust.exists())
        self.assertEqual(self.inventory['edges'][0]['public_ip'], '192.0.2.11')

    def test_malformed_endpoint_profile_cannot_add_options_or_open_a_connection(self):
        for change in ({'host': '-oProxyCommand=unsafe'}, {'host': 'https://host.example'},
                       {'port': True}, {'port': 65536}, {'user': 'root@other'},
                       {'ProxyCommand': 'unsafe'}, {'identity_file': None}):
            profile = {'identity_file': str(self.key), **change}
            with self.subTest(change=change), patch.object(host_connection.subprocess, 'run') as run:
                with self.assertRaises(ValueError):
                    host_connection.execute(self.inventory, 'core', profile, ['true'])
                run.assert_not_called()
        with self.assertRaises(ValueError):
            host_connection.parameters(self.inventory, 'core', {'host': 'host.example'})

    def test_unsafe_identity_or_node_and_malformed_command_never_connect(self):
        with patch.object(host_connection.subprocess, 'run') as run:
            self.key.chmod(0o644)
            with self.assertRaises(ValueError): host_connection.execute(self.inventory, 'core', self.key, ['true'])
            self.key.chmod(0o600)
            alias = self.key.with_name('alias'); alias.symlink_to(self.key)
            with self.assertRaises(OSError): host_connection.execute(self.inventory, 'core', alias, ['true'])
            with self.assertRaises(ValueError): host_connection.execute(self.inventory, 'edge-missing', self.key, ['true'])
            for arguments in ([], [''], ['true', '\x00'], 'echo unsafe'):
                with self.assertRaises(ValueError): host_connection.execute(self.inventory, 'core', self.key, arguments)
            with self.assertRaises(ValueError): host_connection.execute(self.inventory, 'core', self.key, ['true'], timeout=0)
            run.assert_not_called()

    def test_failed_or_timed_out_operation_retains_failure_and_cleans_trust_file(self):
        for error in (subprocess.CalledProcessError(255, ['ssh']), subprocess.TimeoutExpired(['ssh'], 1)):
            captured = []
            def run(command, **kwargs):
                captured.append(Path(next(value.split('=', 1)[1] for value in command if value.startswith('UserKnownHostsFile='))))
                raise error
            with patch.object(host_connection.subprocess, 'run', side_effect=run):
                with self.assertRaises(type(error)): host_connection.execute(self.inventory, 'core', self.key, ['true'])
            self.assertFalse(captured[0].exists())
