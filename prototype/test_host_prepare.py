from contextlib import contextmanager
import io
import json
from pathlib import Path
from types import SimpleNamespace
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import host_packages
import host_prepare
from test_node_inventory import fixture


class HostPrepareTests(unittest.TestCase):
    def setUp(self):
        self.inventory = fixture()
        self.node = 'edge-b'
        self.target = host_packages.binding(self.inventory, self.node)
        self.receipt = {'target': self.target, 'base': host_packages.BASE,
                        'docker': host_packages.DOCKER, 'installed': True,
                        'scope': 'Dependencies only; no role/network/DNS deployment'}
        self.connected = []

        @contextmanager
        def connection(inventory, node, identity):
            self.connected.append((inventory, node, identity))
            yield ['ssh', 'verified-host']

        self.enterContext(patch.object(host_prepare.host_connection, 'connection', connection))
        self.receive = self.enterContext(patch.object(host_prepare.ssh_deploy, 'receive',
            return_value={'path': '/var/lib/voicechat-host-source/bundles/' + 'd' * 64}))
        self.run = self.enterContext(patch.object(host_prepare.subprocess, 'run',
            return_value=SimpleNamespace(stdout=json.dumps(self.receipt).encode())))

    def prepare(self):
        return host_prepare.prepare(self.inventory, self.node, Path('/fixture/identity'),
                                    'a' * 40, Path('/fixture/source.tar.gz'), checkout=ROOT)

    def test_public_source_and_inventory_use_same_pinned_node_without_secret_arguments(self):
        self.assertEqual(self.prepare(), self.receipt)
        self.assertEqual(self.connected, [(self.inventory, self.node, Path('/fixture/identity'))])
        self.receive.assert_called_once_with(['ssh', 'verified-host'],
            '/var/lib/voicechat-host-source', 'a' * 40, Path('/fixture/source.tar.gz'), checkout=ROOT)
        arguments, = self.run.call_args.args
        self.assertEqual(arguments[:2], ['ssh', 'verified-host'])
        self.assertIn('--inventory - --node edge-b --execute', arguments[2])
        self.assertEqual(json.loads(self.run.call_args.kwargs['input']), self.inventory)
        self.assertEqual(self.run.call_args.kwargs['timeout'], 3600)
        self.assertTrue(self.run.call_args.kwargs['check'])

    def test_reject_assignment_before_ssh_and_never_run_unverified_sources(self):
        self.node = 'edge-unknown'
        with self.assertRaises(ValueError): self.prepare()
        self.assertFalse(self.connected)
        self.node = 'edge-b'
        self.receive.side_effect = ValueError('Unreviewed source tree')
        with self.assertRaisesRegex(ValueError, 'Unreviewed'): self.prepare()
        self.run.assert_not_called()

    def test_receipt_must_match_host_profile_types_and_complete_install(self):
        variants = [dict(self.receipt, installed=False), dict(self.receipt, installed=1),
                    dict(self.receipt, target={**self.target, 'node': 'core'}),
                    dict(self.receipt, target={**self.target, 'schema': True})]
        for value in variants:
            self.run.return_value.stdout = json.dumps(value).encode()
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'Unexpected'):
                self.prepare()
        self.run.return_value.stdout = b'x' * 65537
        with self.assertRaisesRegex(ValueError, 'bound'): self.prepare()
        self.run.return_value.stdout = b'{"installed":true,"installed":false}'
        with self.assertRaises(ValueError): self.prepare()

    def test_plan_does_not_connect_or_require_delivery_credentials(self):
        with patch.object(host_prepare.node_inventory, 'load', return_value=self.inventory), \
             patch.object(sys, 'argv', ['host_prepare.py', '--inventory', 'fixture.json', '--node', self.node]), \
             patch('sys.stdout', new_callable=io.StringIO) as output:
            host_prepare.main()
        self.assertFalse(json.loads(output.getvalue())['installed'])
        self.assertFalse(self.connected)
        self.receive.assert_not_called()

    def test_remote_stdin_is_bounded_validated_and_plan_only_without_execute(self):
        for raw, valid in [(json.dumps(self.inventory).encode(), True),
                           (b'x' * 65537, False), (b'{"schema":1,"schema":1}', False)]:
            stdin = SimpleNamespace(buffer=io.BytesIO(raw))
            with patch.object(sys, 'stdin', stdin), \
                 patch.object(sys, 'argv', ['host_packages.py', '--inventory', '-', '--node', self.node]), \
                 patch('sys.stdout', new_callable=io.StringIO) as output:
                if valid:
                    host_packages.main()
                    self.assertFalse(json.loads(output.getvalue())['installed'])
                else:
                    with self.assertRaises(ValueError): host_packages.main()


if __name__ == '__main__':
    unittest.main()
