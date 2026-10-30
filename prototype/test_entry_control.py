import base64
from copy import deepcopy
import hashlib
import hmac
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import core_deploy
import entry_control
import entry_core
import entry_journal
import managed_state
import role_release
import route_catalog
import test_entry_lifecycle
from test_tunnel_runtime import state as network_state


class EntryControlTests(unittest.TestCase):
    def setUp(self):
        fixture = test_entry_lifecycle.EntryLifecycleTests(); fixture.setUp()
        self.public, self.inventory = deepcopy(fixture.public), fixture.inventory
        self.public['web_origins'][2] = 'https://entry-c.duckdns.org'
        self.public['edges'][1].update(origin='https://entry-c.duckdns.org', turn_host='turn.entry-c.duckdns.org')
        self.baseline = deepcopy(fixture.baseline); self.baseline['public'] = self.public
        self.baseline['core'] = role_release.make(self.public, self.inventory, 'core', '1' * 40,
                                                 fixture.baseline['core']['images']['control'])
        self.baseline['edges'] = {edge['id']: role_release.make(self.public, self.inventory, 'edge', '1' * 40,
                                    fixture.image, edge['id']) for edge in self.public['edges']}
        self.after = fixture.after
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.system = Path(self.temporary.name).resolve(); self.root = self.system / 'managed'; self.root.mkdir(mode=0o700)
        core = self.root / 'core'; (core / 'runtime').mkdir(parents=True, mode=0o700)
        (core / 'runtime/stand.env').write_text("TURN_SECRET='" + '3' * 64 + "'\nOTHER=untouched\n")
        (core / 'runtime/stand.env').chmod(0o600)
        managed_state.persist(core / 'state.json', {'schema': 1, 'current': {
            'manifest': self.baseline['core'], 'address': self.inventory['core']['tunnel_ip'],
            'runtime_sha256': core_deploy.runtime_digest(core)}, 'previous': None, 'pending': None,
            'data_identity': {'postgres_system_identifier': '1234', 'signing_sha256': 'a' * 64}})
        network = self.system / 'var/lib/voicechat-network'; network.mkdir(parents=True, mode=0o700)
        self.network = {**network_state(), 'edge_subnet': self.baseline['subnet']}
        managed_state.persist(network / 'desired.json', self.network)
        self.key = self.system / 'synthetic-signer.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(self.key)], check=True, capture_output=True)
        self.pubkey = route_catalog.public_key(self.key)
        managed_state.persist(self.root / 'initial.json', {'phase': 'complete',
            'target': {'catalog_key': self.pubkey, 'edge': {'edge_id': 'b'}}})
        now = int(time.time())
        old = route_catalog.sign(self.public, self.key, 1, now, now + 86400)
        signed = route_catalog.sign(self.public, self.key, 2, now, now + 86400)
        managed_state.persist(self.root / 'catalog.json', old)
        self.settings = {'catalog': json.dumps(signed), 'dns_domain': 'entry-c.duckdns.org',
            'dns_expected': ['192.0.2.12'], 'dns_token_file': '/central/duckdns-token',
            'tls': {'mode': 'existing', 'web_chain': '/central/web.crt', 'web_key': '/central/web.key',
                    'turn_chain': '/central/turn.crt', 'turn_key': '/central/turn.key'}}
        self.pointer = {'schema': 1, 'kind': 'managed', 'baseline': role_release.json_digest(self.baseline),
            'data_identity': {'postgres_system_identifier': '1234', 'signing_sha256': 'a' * 64},
            'legacy_root': str(self.system / 'legacy'), 'shared_root': str(self.system / 'shared')}
        self.receipt = {'backend': self.baseline['backend'], 'core_guard': self.baseline['core_guard'],
            'manifest': {'schema': 1, 'commit': '2' * 40, 'origin': self.public['canonical_origin'],
                'control': self.baseline['core']['images']['control'], 'web': fixture.image}}
        for name, value in (('_delivery', self.receipt), ('current', (self.pointer, self.baseline, 'shared'))):
            item = patch.object(entry_control.managed_journal, name, return_value=value)
            item.start(); self.addCleanup(item.stop)

    def begin(self):
        return entry_control.begin(self.root, 'd' * 64, role_release.json_digest(self.baseline),
                                    self.public, self.after, self.settings, system_root=self.system)

    def test_addition_reads_the_quoted_epoch_without_rotating_it(self):
        from test_node_inventory import key
        self.after = deepcopy(self.inventory)
        self.after['edges'].append({'id': 'd', 'generation': 1, 'public_ip': '192.0.2.24',
                                   'tunnel_ip': '10.88.0.4', 'ssh_host_key': key(5)})
        self.public = deepcopy(self.public)
        self.public['edges'].append({'id': 'd', 'origin': 'https://entry-d.duckdns.org',
                                     'turn_host': 'turn.entry-d.duckdns.org'})
        self.public['web_origins'].append('https://entry-d.duckdns.org')
        now = int(time.time())
        self.settings.update(catalog=json.dumps(route_catalog.sign(self.public, self.key, 2, now, now + 86400)),
                             dns_domain='entry-d.duckdns.org', dns_expected=[])
        value = self.begin()
        self.assertEqual(entry_control.read_secret(self.root, value['attempt'])['secret'], '3' * 64)
        with self.assertRaisesRegex(ValueError, 'Only a replacement'):
            entry_control.previous_turn_credential(self.root, value['attempt'])

    def test_lost_begin_resume_after_network_change_retains_exact_epoch(self):
        value = self.begin(); attempt = value['attempt']
        secret = entry_control.read_secret(self.root, attempt)
        desired = {**self.network, 'inventory': self.after}
        managed_state.persist(self.system / 'var/lib/voicechat-network/desired.json', desired)
        self.assertEqual(self.begin(), value)
        self.assertEqual(entry_control.read_secret(self.root, attempt), secret)
        self.assertNotEqual(secret['secret'], '3' * 64)
        old = entry_control.previous_turn_credential(self.root, attempt)
        expected = base64.b64encode(hmac.new(b'3' * 64, old['username'].encode(), hashlib.sha1).digest()).decode()
        self.assertEqual(old['credential'], expected)
        self.assertNotIn('3' * 64, str(old))

    def test_missing_committed_secret_is_never_regenerated(self):
        value = self.begin(); path = entry_control.directory(self.root, value['attempt']) / 'turn-secret'
        path.unlink()
        with self.assertRaises((ValueError, FileNotFoundError)): self.begin()
        self.assertFalse(path.exists())

    def test_wrong_source_or_baseline_is_rejected_before_entry_journal(self):
        self.receipt['backend'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'matching full'): self.begin()
        self.assertFalse((self.root / 'entry-lifecycle').exists())

    def test_planned_manifest_and_private_nested_data_cannot_acknowledge_real_step(self):
        value = self.begin(); attempt = value['attempt']
        for result in ({'manifest': self.baseline['core']}, {'nested': {'secret': 'must-not-be-saved'}}):
            with self.assertRaises(ValueError): entry_control.acknowledge(self.root, attempt, 0, result)
        self.assertEqual(entry_journal.load(self.root / 'entry-lifecycle')['position'], 0)
        self.assertFalse((entry_control.directory(self.root, attempt) / 'results').exists())
        with self.assertRaisesRegex(ValueError, 'future'):
            entry_control.acknowledge(self.root, attempt, 1, {'schema': 1})

    def test_operator_settings_cannot_change_while_attempt_is_active(self):
        self.begin(); self.settings['dns_expected'] = ['192.0.2.90']
        with self.assertRaisesRegex(ValueError, 'original frozen'): self.begin()

    def test_early_cancel_is_archived_and_idempotent_without_live_changes(self):
        import managed_fence
        import role_deploy
        value = self.begin()
        with patch.object(managed_fence, '_committed'), patch.object(role_deploy, 'in_maintenance', return_value=False):
            result = entry_control.cancel(self.root, value['attempt'], 'd' * 64, system_root=self.system)
            self.assertEqual(result['phase'], 'cancelled')
            self.assertEqual(entry_control.cancel(self.root, value['attempt'], 'd' * 64, system_root=self.system), result)
        self.assertFalse((self.root / 'entry-lifecycle/current.json').exists())
        archive = entry_control.directory(self.root, value['attempt']) / 'cancelled-journal.json'
        self.assertEqual(managed_state.read(archive), value)
        self.assertEqual(core_deploy.read_state(self.root / 'core')['current']['manifest'], self.baseline['core'])

    def test_cancel_refuses_once_tls_delivery_could_have_started(self):
        value = self.begin()
        while value['steps'][value['position']]['action'] != 'tls':
            position = value['position']
            value = entry_journal.acknowledge(self.root / 'entry-lifecycle', {
                'schema': 1, 'attempt': value['attempt'], 'position': position,
                'step': value['steps'][position], 'result_sha256': 'e' * 64})
        managed_state.persist(entry_control.directory(self.root, value['attempt']) / 'credential-delivery.json',
                              {'schema': 1, 'attempt': value['attempt']})
        with self.assertRaisesRegex(ValueError, 'Credential delivery'):
            entry_control.cancel(self.root, value['attempt'], 'd' * 64, system_root=self.system)
        self.assertTrue((self.root / 'entry-lifecycle/current.json').exists())

    def test_coordinator_request_rejects_unknown_or_ambiguous_action(self):
        for value in ({'schema': True, 'action': 'snapshot'}, {'schema': 1, 'action': []},
                      {'schema': 1, 'action': 'shell'}, {'schema': 1, 'action': 'secret', 'attempt': True}):
            with self.assertRaises(ValueError): entry_core.request(json.dumps(value).encode())


if __name__ == '__main__': unittest.main()
