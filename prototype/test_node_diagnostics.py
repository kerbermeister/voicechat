import json
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import node_diagnostics as diagnostic
import topology
from test_node_inventory import fixture


class NodeDiagnosticTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve(); self.root.chmod(0o700)
        self.inventory = fixture()
        self.public = topology.load(ROOT / 'infra/three-vps.example.json')
        self.host = self.enterContext(patch.object(diagnostic.network_bootstrap, 'existing',
            return_value=self.inventory['edges'][0]['ssh_host_key'].encode()))
        self.network = self.enterContext(patch.object(diagnostic, 'network', return_value=True))
        self.upstream = self.enterContext(patch.object(diagnostic.route_health, 'upstream_ready', return_value=True))
        self.tls = self.enterContext(patch.object(diagnostic, 'tls', return_value={
            'status':'passed','expires_in_days':30,'renewal_due':False}))
        self.processes = self.enterContext(patch.object(diagnostic, 'processes', return_value={
            'status':'passed','commit':'a'*40}))
        self.enterContext(patch.object(diagnostic, 'turn_metrics', return_value={'rx_bytes':100, 'tx_bytes':200}))
        self.enterContext(patch.object(diagnostic.shutil, 'disk_usage', return_value=SimpleNamespace(free=10*1024**3)))

    def report(self, node='edge-b'):
        return diagnostic.report(self.root, self.public, self.inventory, node)

    def test_entry_checks_only_its_own_services_and_marks_media_unchecked(self):
        report = self.report(); checks = report['checks']
        self.assertTrue(report['available_checks_passed'])
        self.assertEqual(set(checks), {'network','matrix','control','edge_b_processes','edge_b_web_tls','edge_b_turn_tls','disk'})
        self.assertIn('media_decryption', report['not_checked'])
        self.assertIn('authenticated_wss', report['not_checked'])
        self.assertEqual(self.tls.call_count, 2)
        self.assertEqual(self.tls.call_args_list[0].args[0], '192.0.2.11')
        self.assertNotIn('ssh-ed25519', json.dumps(report))

    def test_partial_failures_are_independent_and_never_print_exception_text(self):
        self.upstream.side_effect = [False, True]
        self.network.side_effect = RuntimeError('SECRET-private-key-token')
        self.tls.side_effect = OSError('SECRET-private-url')
        report = self.report(); checks = report['checks']
        self.assertFalse(report['available_checks_passed'])
        self.assertEqual(checks['matrix']['status'], 'failed')
        self.assertEqual(checks['control']['status'], 'passed')
        self.assertEqual(checks['edge_b_processes']['status'], 'passed')
        self.assertNotIn('SECRET', json.dumps(report))
        self.assertNotIn('192.0.2.', json.dumps(report))

    def test_core_and_cohost_are_both_checked_on_the_core_host(self):
        self.public = topology.load(ROOT / 'infra/single-vps.example.json')
        self.inventory['edges'] = [{'id':'a','host':'core'}]
        self.host.return_value = self.inventory['core']['ssh_host_key'].encode()
        checks = self.report('core')['checks']
        self.assertIn('core_processes', checks)
        self.assertIn('edge_a_processes', checks)

    def test_wrong_host_unknown_node_and_bad_subnet_fail_before_probes(self):
        for node in ('missing', 'core'):
            with self.subTest(node=node), self.assertRaises(ValueError): self.report(node)
        with self.assertRaises(ValueError):
            diagnostic.report(self.root, self.public, self.inventory, 'edge-b', subnet='0.0.0.0/0')
        self.network.assert_not_called(); self.upstream.assert_not_called(); self.tls.assert_not_called()


class DiagnosticMetricTests(unittest.TestCase):
    def test_network_counters_exclude_loopback_and_reject_malformed_values(self):
        raw = 'Inter-| Receive | Transmit\n lo: ' + '999 '*16 + '\n eth0: 100 1 0 0 0 0 0 0 200 1 0 0 0 0 0 0\n'
        self.assertEqual(diagnostic.netdev_bytes(raw), {'rx_bytes':100,'tx_bytes':200})
        for value in ('eth0: -1 '+ '0 '*15, 'eth0: 1', 'lo: '+'0 '*16, 'x'*65537):
            with self.subTest(value=value[:25]), self.assertRaises(ValueError):diagnostic.netdev_bytes(value)

    def test_host_load_is_informational_and_omits_unavailable_values(self):
        with patch.object(diagnostic.os, 'getloadavg', return_value=(.2,.3,.4)), patch.object(diagnostic.os, 'cpu_count', return_value=2):
            self.assertEqual(diagnostic.host_metrics(), {'cpu_count':2,'load_1m':.2,'load_5m':.3,'load_15m':.4})
        with patch.object(diagnostic.os, 'getloadavg', side_effect=OSError('SECRET')):
            self.assertEqual(diagnostic.host_metrics(), {})

    def test_turn_counters_require_owned_isolated_running_container(self):
        with patch.object(diagnostic.edge_deploy, 'read_state', return_value={'current':{}}), patch.object(diagnostic.edge_deploy, 'compose', return_value=('a'*64).encode()), patch.object(diagnostic.subprocess, 'check_output') as read:
            read.side_effect = ['bridge voicechat-edge-a turn', 'eth0: 100 1 0 0 0 0 0 0 200 1 0 0 0 0 0 0']
            self.assertEqual(diagnostic.turn_metrics(Path('/unused'), 'a'), {'rx_bytes':100,'tx_bytes':200})
            for identity in ('host voicechat-edge-a turn','bridge other turn','container:abc voicechat-edge-a turn'):
                read.reset_mock();read.side_effect=None;read.return_value=identity
                self.assertEqual(diagnostic.turn_metrics(Path('/unused'), 'a'), {})
                self.assertEqual(read.call_count, 1)


class PrimitiveDiagnosticTests(unittest.TestCase):
    def test_unprepared_network_is_reported_without_creating_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve() / 'missing'
            self.assertFalse(diagnostic.network(fixture(), 'edge-b', '10.241.0.0/28', directory))
            self.assertFalse(directory.exists())


    def test_network_requires_live_peers_routes_address_and_owned_firewall(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve(); (directory / 'apply.lock').touch()
            desired = {'public_keys':{'nodes':{'core':{'public_key':'core-public'},'edge-b':{'public_key':'edge-public'}}}}
            def command(*args):
                if args[:1] == ('wg',): return 'core-public\n'
                return '[{"addr_info":[{"local":"10.88.0.2"}]}]'
            with patch.object(diagnostic.role_deploy, 'network_ready', return_value=nullcontext()), \
                    patch.object(diagnostic.managed_state, 'read', return_value=desired), \
                    patch.object(diagnostic.network_runtime, 'components', return_value=({},{})), \
                    patch.object(diagnostic.tunnel_runtime, 'inspect', return_value=(True, {'10.88.0.1/32'}, {'10.88.0.1/32'}, '10.88.0.2')) as inspect, \
                    patch.object(diagnostic.firewall_runtime, 'inspect', return_value=True) as firewall, \
                    patch.object(diagnostic.tunnel_runtime, 'command', side_effect=command) as run:
                self.assertTrue(diagnostic.network(fixture(), 'edge-b', '10.241.0.0/28', directory))
                run.side_effect = lambda *args: '' if args[0]=='wg' else '[]'
                self.assertFalse(diagnostic.network(fixture(), 'edge-b', '10.241.0.0/28', directory))
                run.side_effect = command; firewall.return_value = False
                self.assertFalse(diagnostic.network(fixture(), 'edge-b', '10.241.0.0/28', directory))
                firewall.return_value = True; inspect.return_value = (True, {'10.88.0.1/32'}, set(), '10.88.0.2')
                self.assertFalse(diagnostic.network(fixture(), 'edge-b', '10.241.0.0/28', directory))

    def test_process_inspection_rejects_pending_and_redacts_docker_errors(self):
        module = SimpleNamespace(read_state=MagicMock(return_value={'current':None,'pending':None}))
        self.assertEqual(diagnostic.processes(Path('/fixture'), module), {'status':'failed'})
        module.read_state.side_effect = RuntimeError('SECRET')
        self.assertNotIn('SECRET', str(diagnostic.processes(Path('/fixture'), module)))
        module.read_state.side_effect = None
        module.read_state.return_value = {'current':{'manifest':{'commit':'a'*40}},'pending':{'phase':'applying'}}
        self.assertEqual(diagnostic.processes(Path('/fixture'), module), {'status':'failed'})

    def test_remote_docker_cannot_be_mistaken_for_node_local_processes(self):
        module = SimpleNamespace(read_state=lambda _: {'current':{'manifest':{'commit':'a'*40}},'pending':None})
        with patch.dict(diagnostic.os.environ, {'DOCKER_HOST':'ssh://unrelated'}), \
                patch.object(diagnostic.role_deploy, 'run') as run:
            self.assertEqual(diagnostic.processes(Path('/fixture'),module), {'status':'failed'})
            run.assert_not_called()
        with patch.dict(diagnostic.os.environ, {'DOCKER_HOST':''}), \
                patch.object(diagnostic.role_deploy, 'run', return_value=b'ssh://unrelated'), \
                patch.object(diagnostic.managed_release, 'process_snapshot') as snapshot:
            self.assertEqual(diagnostic.processes(Path('/fixture'),module), {'status':'failed'})
            snapshot.assert_not_called()

    def test_trusted_tls_reports_expiry_without_loading_private_key_or_disabling_validation(self):
        context = MagicMock(); stream = context.wrap_socket.return_value.__enter__.return_value
        stream.getpeercert.return_value = {'notAfter':'Jan  3 00:00:00 2030 GMT'}
        with patch.object(diagnostic.ssl, 'create_default_context', return_value=context), \
                patch.object(diagnostic.socket, 'create_connection') as connect:
            report = diagnostic.tls('192.0.2.11', 'entry.example.com', now=1893456000)
        self.assertEqual(report, {'status':'passed','expires_in_days':2,'renewal_due':True})
        connect.assert_called_once_with(('192.0.2.11',443),timeout=5)
        self.assertEqual(context.wrap_socket.call_args.kwargs, {'server_hostname':'entry.example.com'})
        context.load_cert_chain.assert_not_called()
