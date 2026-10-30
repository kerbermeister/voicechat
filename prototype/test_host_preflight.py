from copy import deepcopy
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import host_preflight
from test_node_inventory import fixture


def facts(inventory, node='core'):
    return {'system': 'Linux', 'machine': 'x86_64', 'uid': 0, 'errors': [],
            'os': {'ID': 'debian', 'VERSION_ID': '12'}, 'memory': 8 * 1024**3,
            'disk_free': 40 * 1024**3, 'host_key': host_preflight.physical_nodes(inventory)[node]['ssh_host_key'],
            'systemd': 'running', 'ntp': True, 'ports': [], 'networks': ['0.0.0.0/0', '172.17.0.0/16'], 'links': [],
            'tools': {'docker': True, 'wg': True}, 'compose': '2.19.1'}


class HostPreflightTests(unittest.TestCase):
    def test_roles_one_host_and_public_ssh_identity(self):
        inventory = fixture()
        report = host_preflight.evaluate(inventory, 'core', facts(inventory))
        self.assertTrue(report['ready_for_initial_install'])
        self.assertNotIn('ssh-ed25519', str(report))
        ports = [{'protocol': 'tcp', 'port': 443}]
        self.assertTrue(host_preflight.evaluate(inventory, 'core', {**facts(inventory), 'ports': ports})['ready_for_initial_install'])
        self.assertFalse(host_preflight.evaluate(inventory, 'edge-b', {**facts(inventory, 'edge-b'), 'ports': ports})['ready_for_initial_install'])
        one = deepcopy(inventory)
        one['edges'] = [{'id': 'a', 'host': 'core'}]
        report = host_preflight.evaluate(one, 'core', {**facts(one), 'ports': ports})
        self.assertIn('Port already reserved: tcp/443', report['blockers'])
        with self.assertRaises(ValueError):
            host_preflight.evaluate(one, 'edge-a', facts(one))
        one['ssh_port'] = 443
        self.assertIn('Port already reserved: tcp/443', host_preflight.evaluate(one, 'core', facts(one))['blockers'])

    def test_fail_closed_resources_clock_identity_and_incomplete_inspection(self):
        inventory = fixture()
        for update in ({'uid': 1000}, {'os': {'ID': 'other', 'VERSION_ID': '1'}},
                       {'machine': 'unknown'}, {'memory': None}, {'disk_free': 1},
                       {'host_key': 'unverified'}, {'ntp': False}, {'systemd': 'degraded'},
                       {'compose': None}, {'errors': ['Docker published ports']}):
            with self.subTest(update=update):
                self.assertFalse(host_preflight.evaluate(inventory, 'core', {**facts(inventory), **update})['ready_for_initial_install'])
        self.assertFalse(host_preflight.evaluate(inventory, 'core', {'system': 'Darwin'})['ready_for_initial_install'])
        missing = {**facts(inventory), 'tools': {'docker': False, 'wg': False}, 'compose': None}
        result = host_preflight.evaluate(inventory, 'core', missing)
        self.assertTrue(result['ready_for_initial_install'])
        self.assertIn('docker, wg', result['warnings'][0])

    def test_overlaps_include_remote_tunnel_ips_docker_and_route_tables(self):
        inventory = fixture()
        for network in ('10.88.0.0/24', '10.88.0.3/32', '10.241.0.0/16'):
            with self.subTest(network=network):
                report = host_preflight.evaluate(inventory, 'edge-b', {**facts(inventory, 'edge-b'), 'networks': [network]})
                self.assertTrue(any('overlaps' in item for item in report['blockers']))
        for subnet in ('0.0.0.0/28', '10.241.0.0/24', '10.241.0.1/28'):
            with self.assertRaises(ValueError):
                host_preflight.evaluate(inventory, 'core', facts(inventory), subnet)
        report = host_preflight.evaluate(inventory, 'edge-b', facts(inventory, 'edge-b'), '10.88.0.0/28')
        self.assertIn('Edge bridge overlaps an inventory tunnel address', report['blockers'])
        report = host_preflight.evaluate(inventory, 'edge-b', {**facts(inventory, 'edge-b'),
            'links': [host_preflight.node_inventory.edge_bridge(inventory, 'b')]})
        self.assertIn('Planned edge bridge interface already exists', report['blockers'])
        report = host_preflight.evaluate(inventory, 'core', {**facts(inventory),
            'links': [host_preflight.node_inventory.core_bridge(inventory)]})
        self.assertIn('Planned core bridge interface already exists', report['blockers'])

    def test_socket_parser_ipv4_ipv6_and_bad_output(self):
        parsed = host_preflight.listeners('tcp LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*\n'
                                         'udp UNCONN 0 0 [::]:51820 [::]:*\n'
                                         'tcp LISTEN 0 128 *:3478 *:*\n')
        self.assertEqual(parsed, [{'protocol': 'tcp', 'port': 443}, {'protocol': 'udp', 'port': 51820},
                                  {'protocol': 'tcp', 'port': 3478}])
        for text in ('incomplete', 'tcp LISTEN 0 0 addr:0 *:*', 'tcp LISTEN 0 0 addr:65536 *:*'):
            with self.assertRaises(ValueError): host_preflight.listeners(text)

    def test_collect_reads_docker_nat_without_exposing_container_environment(self):
        calls = []
        public_key = fixture()['core']['ssh_host_key']

        def run(arguments):
            calls.append(arguments)
            if arguments[:3] == ['ip', '-j', 'link']:
                return '[{"ifname":"eth0"}]'
            if arguments[:2] == ['docker', 'inspect']:
                return '{"443/tcp":[{"HostIp":"0.0.0.0","HostPort":"443"}],"9999/tcp":null}\n'
            if arguments[:3] == ['docker', 'network', 'inspect']:
                return '[{"Subnet":"10.241.0.0/28"}]\n'
            return {('systemctl',): 'running', ('timedatectl',): 'yes', ('ss',): '', ('ip',): '[{"dst":"default"}]',
                    ('docker', 'compose'): '2.19.1', ('docker', 'network'): 'networkid', ('docker', 'ps'): 'containerid'}[
                        tuple(arguments[:2] if arguments[0] == 'docker' else arguments[:1])]

        def read(path):
            return 'MemTotal: 8388608 kB\n' if str(path) == '/proc/meminfo' else public_key + ' comment\n'

        with patch.object(host_preflight.platform, 'system', return_value='Linux'), \
                patch.object(host_preflight.platform, 'freedesktop_os_release', return_value={'ID': 'debian', 'VERSION_ID': '12'}), \
                patch.object(host_preflight.shutil, 'which', return_value='/usr/bin/tool'), \
                patch.object(host_preflight, 'command', side_effect=run), patch.object(Path, 'read_text', read):
            result = host_preflight.collect(ROOT)
        self.assertEqual(result['errors'], [])
        self.assertEqual(result['ports'], [{'protocol': 'tcp', 'port': 443}])
        self.assertEqual(result['networks'], ['10.241.0.0/28'])
        self.assertIn(['docker', 'inspect', '--format', '{{json .NetworkSettings.Ports}}', 'containerid'], calls)

    def test_collection_failure_is_not_a_successful_empty_inspection(self):
        with patch.object(host_preflight.platform, 'system', return_value='Linux'), \
                patch.object(host_preflight, 'command', side_effect=subprocess.TimeoutExpired('inspection', 15)):
            result = host_preflight.collect(ROOT)
        self.assertIn('listening sockets', result['errors'])
        self.assertIn('IPv4 routes', result['errors'])
        self.assertFalse(host_preflight.evaluate(fixture(), 'core', result)['ready_for_initial_install'])
