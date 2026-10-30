from copy import deepcopy
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import host_identity
import host_network
import host_packages
import managed_state
import tunnel_config
from test_node_inventory import fixture
from test_host_registration import public


class HostNetworkTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.state = self.root / 'var/lib/voicechat-host'
        self.state.mkdir(mode=0o700, parents=True)
        self.network = self.root / 'var/lib/voicechat-network'
        self.inventory = fixture()
        self.enterContext(patch.object(host_packages, 'inspect_identity'))
        managed_state.persist(self.state / 'current.json', host_packages.binding(self.inventory, 'edge-b'))
        identity = host_identity.initialize(self.state, self.inventory, 'edge-b')
        self.request = {'schema': 1, 'inventory': self.inventory, 'node': 'edge-b',
            'edge_subnet': '10.241.0.0/28', 'public_keys': {
                'schema': 1, 'service_id': self.inventory['service_id'], 'nodes': {
                    'core': {'generation': 1, 'public_key': public(1)},
                    'edge-b': {'generation': 1, 'public_key': identity['public_key']},
                    'edge-c': {'generation': 1, 'public_key': public(3)}}}}
        self.apply = self.enterContext(patch.object(host_network.network_runtime, 'reconcile', side_effect=self.save))
        self.boot = self.enterContext(patch.object(host_network.network_bootstrap, 'install', return_value='a' * 64))
        self.commands = []
        self.containers = ''

    def save(self, directory, desired, **kwargs):
        directory.mkdir(mode=0o700, exist_ok=True)
        managed_state.persist(directory / 'desired.json', desired)

    def command(self, *args):
        self.commands.append(args)
        if args == ('docker', 'ps', '-aq'): return self.containers
        self.assertEqual(args, ('systemctl', 'list-unit-files', '--no-legend', '--no-pager'))
        return ''

    def initialize(self):
        return host_network.initialize(self.request, system_root=self.root, run=self.command)

    def test_applies_own_private_key_locally_and_repeat_keeps_exact_intent(self):
        before = (self.state / 'network.key').read_bytes()
        first = self.initialize()
        self.assertEqual(first, self.initialize())
        self.assertEqual(before, (self.state / 'network.key').read_bytes())
        desired = managed_state.read(self.network / 'desired.json')
        self.assertEqual(desired['private_key'], tunnel_config.read_private(self.state / 'network.key'))
        self.assertNotIn('private_key', first)
        self.assertEqual(first['boot_source_sha256'], 'a' * 64)

    def test_interrupted_boot_install_resumes_exact_network_without_rotating_key(self):
        self.boot.side_effect = RuntimeError('Interrupted boot installation')
        with self.assertRaises(RuntimeError): self.initialize()
        saved = (self.network / 'desired.json').read_bytes()
        self.boot.side_effect = None
        self.initialize()
        self.assertEqual(saved, (self.network / 'desired.json').read_bytes())

    def test_foreign_intent_stopped_container_and_unclaimed_state_are_preserved(self):
        self.network.mkdir(mode=0o700)
        managed_state.persist(self.network / 'foreign.json', {})
        with self.assertRaisesRegex(ValueError, 'unclaimed'): self.initialize()
        (self.network / 'foreign.json').unlink()
        self.containers = 'stopped-fixture-container'
        with self.assertRaisesRegex(ValueError, 'application-free'): self.initialize()
        self.containers = ''
        self.initialize()
        self.apply.reset_mock();self.boot.reset_mock()
        other = deepcopy(self.request);other['edge_subnet'] = '10.242.0.0/28'
        saved = (self.network / 'desired.json').read_bytes()
        with self.assertRaisesRegex(ValueError, 'coordinated'):
            host_network.initialize(other, system_root=self.root, run=self.command)
        self.assertEqual(saved, (self.network / 'desired.json').read_bytes())
        self.apply.assert_not_called();self.boot.assert_not_called()

    def test_wrong_key_or_pending_packages_fail_before_network_or_boot(self):
        self.request['public_keys']['nodes']['edge-b']['public_key'] = public(7)
        with self.assertRaises(ValueError): self.initialize()
        self.apply.assert_not_called();self.boot.assert_not_called()
        self.request['public_keys']['nodes']['edge-b']['public_key'] = tunnel_config.public_key(tunnel_config.read_private(self.state / 'network.key'))
        managed_state.persist(self.state / 'pending.json', {})
        with self.assertRaisesRegex(ValueError, 'preparation'): self.initialize()
        self.apply.assert_not_called();self.boot.assert_not_called()

    def test_foreign_boot_gate_is_rejected_before_network_changes(self):
        unit = self.root / host_network.network_bootstrap.UNIT
        unit.parent.mkdir(parents=True)
        unit.write_text('Preserve foreign unit')
        with self.assertRaisesRegex(ValueError, 'unclaimed network boot'):
            self.initialize()
        self.apply.assert_not_called();self.boot.assert_not_called()
        self.assertEqual(unit.read_text(), 'Preserve foreign unit')

    def test_request_bound_schema_and_duplicate_fields_are_rejected(self):
        for raw in (b'x' * 65537, b'{"schema":1,"schema":1}', b'{}'):
            with self.assertRaises(ValueError): host_network.request(raw)
        self.request['schema'] = True
        with self.assertRaises(ValueError): self.initialize()


if __name__ == '__main__':
    unittest.main()
