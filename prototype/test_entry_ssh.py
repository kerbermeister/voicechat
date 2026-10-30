from copy import deepcopy
from pathlib import Path
import sys
import unittest
import tempfile
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import entry_lifecycle
import managed_release
import role_release
import entry_ssh
import test_entry_lifecycle
from test_node_inventory import key


class EntrySshTests(unittest.TestCase):
    def setUp(self):
        fixture = test_entry_lifecycle.EntryLifecycleTests(); fixture.setUp()
        self.baseline = fixture.baseline

    def test_add_chooses_free_private_address_and_retains_existing_assignments(self):
        public, inventory = entry_ssh.target(self.baseline, {'id': 'd', 'public_ip': '192.0.2.20',
            'ssh_host_key': key(4), 'origin': 'https://d.example.com', 'turn_host': 'turn-d.example.com'})
        self.assertEqual(inventory['edges'][:-1], self.baseline['inventory']['edges'])
        self.assertEqual(inventory['edges'][-1]['tunnel_ip'], '10.88.0.4')
        self.assertEqual(inventory['edges'][-1]['generation'], 1)
        self.assertEqual(public['edges'][:-1], self.baseline['public']['edges'])
        self.assertIn('https://d.example.com', public['web_origins'])

    def test_replace_automatically_advances_generation_and_preserves_names_and_tunnel(self):
        public, inventory = entry_ssh.target(self.baseline, {'id': 'c', 'public_ip': '192.0.2.20', 'ssh_host_key': key(4)})
        self.assertEqual(public, self.baseline['public'])
        self.assertEqual(inventory['edges'][1]['generation'], 2)
        self.assertEqual(inventory['edges'][1]['tunnel_ip'], self.baseline['inventory']['edges'][1]['tunnel_ip'])
        self.assertEqual(inventory['edges'][0], self.baseline['inventory']['edges'][0])

    def test_same_or_unverified_host_and_extra_public_change_are_rejected(self):
        for entry in ({'id': 'c', 'public_ip': '192.0.2.12', 'ssh_host_key': key(3)},
                      {'id': 'c', 'public_ip': '192.0.2.20', 'ssh_host_key': key(4), 'origin': 'https://other.example.com'},
                      {'id': 'd', 'public_ip': '192.0.2.20', 'ssh_host_key': 'accept-any-key'}):
            with self.assertRaises(ValueError): entry_ssh.target(self.baseline, entry)

    def test_cancel_recovers_lost_begin_reply_but_never_cancels_another_attempt(self):
        fixture = test_entry_lifecycle.EntryLifecycleTests(); fixture.setUp()
        with tempfile.TemporaryDirectory() as temporary:
            local = Path(temporary).resolve()
            record = {'baseline': fixture.baseline, 'public': fixture.public, 'inventory': fixture.after,
                'settings': {'catalog': 'public-test-artifact'}, 'attempt': None,
                'delivery': {'source': 'd' * 64, 'commit': '2' * 40, 'manifest': {'web': fixture.image}}}
            driver = entry_ssh.Driver('/srv/managed', record, {}, local)
            target = managed_release.store_baseline(local, driver.plan['target'])
            pending = {'attempt': 'e' * 64, 'position': 0, 'steps': [{'action': 'prepare', 'node': 'edge-c'}],
                'request': {'source': driver.source, 'target': target, 'settings': role_release.json_digest(driver.settings)}}
            driver.core = Mock(side_effect=[{'pending': pending}, {'phase': 'cancelled'}])
            self.assertEqual(driver.cancel()['phase'], 'cancelled')
            self.assertEqual(driver.attempt, 'e' * 64)
            self.assertEqual(driver.core.call_args_list[1].args, ('cancel',))
            record = {**record, 'attempt': None}; driver = entry_ssh.Driver('/srv/managed', record, {}, local)
            driver.core = Mock(return_value={'pending': {**pending, 'request': {**pending['request'], 'source': 'f' * 64}}})
            with self.assertRaisesRegex(ValueError, 'different entry'): driver.cancel()
            self.assertEqual(driver.core.call_count, 1)

    def test_cancel_local_preparation_does_not_mislabel_completed_server_operation(self):
        fixture = test_entry_lifecycle.EntryLifecycleTests(); fixture.setUp()
        with tempfile.TemporaryDirectory() as temporary:
            local = Path(temporary).resolve()
            record = {'baseline': fixture.baseline, 'public': fixture.public, 'inventory': fixture.after,
                'settings': {'catalog': 'public-test-artifact'}, 'attempt': None,
                'delivery': {'source': 'd' * 64, 'commit': '2' * 40, 'manifest': {'web': fixture.image}}}
            driver = entry_ssh.Driver('/srv/managed', record, {}, local)
            driver.core = Mock(return_value={'pending': None})
            self.assertTrue(driver.cancel()['local_only'])
            target = managed_release.store_baseline(local, driver.plan['target'])
            pending = {'attempt': 'e' * 64, 'position': 1, 'steps': [{'action': 'prepare', 'node': 'edge-c'}],
                'request': {'source': driver.source, 'target': target, 'settings': role_release.json_digest(driver.settings)}}
            driver.core = Mock(return_value={'pending': pending})
            with self.assertRaisesRegex(ValueError, 'already completed'): driver.cancel()

    def test_retirement_checks_every_surviving_turn_before_dns_and_releases_after_commit(self):
        fixture = test_entry_lifecycle.EntryLifecycleTests(); fixture.setUp()
        plan = fixture.plan(); steps = entry_lifecycle.steps(plan)
        self.assertEqual([step['node'] for step in steps if step['action'] == 'verify-turn'], ['edge-b', 'edge-c'])
        actions = [step['action'] for step in steps]
        self.assertLess(max(i for i, action in enumerate(actions) if action == 'verify-turn'), actions.index('dns'))
        self.assertGreater(actions.index('release'), actions.index('commit'))


if __name__ == '__main__': unittest.main()
