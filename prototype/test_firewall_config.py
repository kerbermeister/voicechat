from copy import deepcopy
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import firewall_config
import node_inventory
import role_config
from test_node_inventory import fixture
from topology import load


class FirewallConfigTests(unittest.TestCase):
    def test_core_private_api_and_public_media_are_scoped_to_their_paths(self):
        inventory = fixture()
        rules = firewall_config.render(inventory, 'core')
        self.assertIn('iifname "wg-vc" ip saddr { 10.88.0.2, 10.88.0.3 } return', rules)
        self.assertIn('ip daddr 10.88.0.1 drop', rules)
        self.assertIn('ip daddr 192.0.2.10 tcp dport 7981 ip saddr { 192.0.2.11, 192.0.2.12 } return', rules)
        self.assertIn('ct direction original ct original ip daddr 192.0.2.10 meta l4proto udp ct original proto-dst 50300-50400 drop', rules)
        for line in rules.splitlines():
            if 'ct original ip daddr' in line: self.assertIn('ct direction original', line)
        self.assertNotIn('flush ruleset', rules)
        self.assertNotIn('policy drop', rules)
        self.assertNotIn('    ct state established', rules)
        self.assertNotIn('tcp dport 22', rules)
        bridge = node_inventory.core_bridge(inventory)
        self.assertIn(f'ct direction original oifname "{bridge}" iifname != "{bridge}" drop', rules)
        self.assertIn(f'ct direction reply oifname "{bridge}" iifname != "{bridge}" udp dport 50300-50400 drop', rules)
        table, _ = firewall_config.identity(inventory, 'core')
        self.assertTrue(firewall_config.render(inventory, 'core', replace=True).startswith(f'delete table inet {table}\n'))
        self.assertNotIn('delete table', rules)

    def test_co_located_bridge_matches_compose_and_separates_relay_from_api(self):
        inventory = fixture()
        inventory['edges'] = [{'id': 'a', 'host': 'core'}]
        public = load(ROOT / 'infra/single-vps.example.json')
        compose, _ = role_config.edge(public, inventory, 'a')
        bridge = compose['networks']['default']['driver_opts']['com.docker.network.bridge.name']
        self.assertEqual(bridge, node_inventory.edge_bridge(inventory, 'a'))
        self.assertLessEqual(len(bridge), 15)
        self.assertTrue(re.fullmatch(r'[a-z0-9-]+', bridge))
        rules = firewall_config.render(inventory, 'core')
        self.assertIn(f'iifname "{bridge}" ip saddr {{ 10.241.0.3, 10.241.0.5 }} return', rules)
        self.assertIn(f'tcp dport 7981 iifname "{bridge}" ip saddr 10.241.0.4 return', rules)
        self.assertNotIn('iifname "wg-vc" ip saddr', rules)
        self.assertNotIn('ip saddr { 192.0.2.10 }', rules)

    def test_edge_does_not_filter_unrelated_public_services(self):
        rules = firewall_config.render(fixture(), 'edge-c')
        self.assertIn('ip saddr { 192.0.2.10 } udp dport 51820 return', rules)
        self.assertIn('ip daddr 10.88.0.3 drop', rules)
        self.assertIn('ip daddr 10.88.0.3 ct direction reply ct state established,related return', rules)
        self.assertIn('iifname "wg-vc" ct direction reply ct state established,related return', rules)
        self.assertEqual(rules.count('iifname "wg-vc" drop'), 2)
        for port in ('443', '3478', '7981', '8088', '50300'):
            self.assertNotIn(port, rules)

    def test_replacement_updates_allowlist_and_rejects_invalid_inputs(self):
        before = fixture()
        after = deepcopy(before)
        after['edges'][1]['public_ip'] = '192.0.2.13'
        rules = firewall_config.render(after, 'core')
        self.assertNotIn('192.0.2.12', rules)
        self.assertIn('192.0.2.13', rules)
        for identity in ('edge-unknown', 'edge-c; flush ruleset'):
            with self.assertRaises(ValueError): firewall_config.render(before, identity)
        for subnet in ('0.0.0.0/28', '192.0.2.0/28', '10.88.0.0/28', '10.241.0.0/24'):
            with self.assertRaises(ValueError): firewall_config.render(before, 'core', subnet)
