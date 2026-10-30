import base64
from copy import deepcopy
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import core_deploy
import entry_network
import managed_state
import network_runtime
import role_deploy
import role_prepare
import role_release
import topology
import tunnel_config
from test_firewall_runtime import Firewall
from test_node_inventory import key
from test_tunnel_runtime import Network, state


class EntryNetworkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.system = Path(self.temporary.name).resolve()
        self.root = self.system / 'srv/voicechat'; self.root.mkdir(parents=True, mode=0o700)
        self.network = self.system / 'var/lib/voicechat-network'
        self.network.parent.mkdir(parents=True)
        self.before = {**state(), 'edge_subnet': '10.241.0.0/28'}
        self.after = deepcopy(self.before['inventory'])
        self.after['edges'][1].update(generation=2, public_ip='192.0.2.20', ssh_host_key=key(4))
        self.identity = {'schema': 1, 'service_id': self.after['service_id'], 'node': 'edge-c',
                         'generation': 2, 'public_key': tunnel_config.public_key(base64.b64encode(bytes([9]) * 32).decode())}
        self.public = topology.load(ROOT / 'infra/three-vps.example.json')
        manifest = role_release.make(self.public, self.before['inventory'], 'core', '1' * 40,
                                     'ghcr.io/example/control@sha256:' + 'a' * 64)
        role = self.root / 'core'
        role_prepare.prepare(role, self.public, self.before['inventory'], manifest)
        (role / 'runtime/stand.env').write_text('FIXTURE_ONLY=true\n'); (role / 'runtime/stand.env').chmod(0o600)
        record = core_deploy.record_for(role, self.before['inventory'], manifest)
        managed_state.persist(role / 'state.json', {'schema': 1, 'current': record, 'previous': None,
            'pending': None, 'data_identity': {'postgres_system_identifier': '1234', 'signing_sha256': 'a' * 64}})
        self.attempt = 'b' * 64
        managed_state.persist(role / 'runtime/managed-release.json', {'schema': 1,
            'operation': 'managed-release', 'root': str(role), 'attempt': self.attempt,
            'owner': role_release.json_digest(managed_state.read(role / 'role.json')),
            'before': manifest, 'target': manifest, 'active': manifest, 'phase': 'held', 'result': None})
        managed_state.persist(role / 'runtime/full-rollout.json', role_deploy.rollout_marker(role, manifest, self.attempt))
        host = self.system / 'etc/ssh/ssh_host_ed25519_key.pub'; host.parent.mkdir(parents=True)
        host.write_text(self.before['inventory']['core']['ssh_host_key'] + ' fixture\n')
        self.firewall, self.tunnel = Firewall(self.before), Network()
        self.calls = []
        network_runtime.reconcile(self.network, self.before, run=self.run_command)
        self.calls.clear()

    def run_command(self, *args):
        self.calls.append(args)
        return self.firewall.run(*args) if args[0] == 'nft' else self.tunnel.run(*args)

    def transition(self, **changes):
        arguments = dict(subnet=self.before['edge_subnet'], system_root=self.system, run=self.run_command)
        arguments.update(changes)
        return entry_network.transition(self.root, self.before['inventory'], self.after,
            self.before['public_keys'], self.identity, 'core', self.attempt, **arguments)

    def test_revoke_and_repeat_keep_local_key_and_do_not_run_application_commands(self):
        retired = self.before['public_keys']['nodes']['edge-c']['public_key']
        with patch.object(entry_network.network_bootstrap, 'upgrade') as upgrade:
            result = self.transition()
            self.assertEqual(result, self.transition())
        self.assertEqual(upgrade.call_count, 2)
        desired = managed_state.read(self.network / 'desired.json')
        self.assertEqual(desired['private_key'], self.before['private_key'])
        self.assertNotIn(retired, self.tunnel.peers)
        self.assertIn(self.identity['public_key'], self.tunnel.peers)
        self.assertNotIn(self.before['private_key'], str(result))
        self.assertFalse(any(args[0] in ('docker', 'systemctl') for args in self.calls))

    def test_missing_role_fence_rejects_before_changing_network(self):
        (self.root / 'core/runtime/full-rollout.json').unlink()
        with self.assertRaises(ValueError): self.transition()
        self.assertEqual(self.calls, [])
        self.assertEqual(managed_state.read(self.network / 'desired.json'), self.before)

    def test_different_live_intent_cannot_be_overwritten(self):
        unrelated = deepcopy(self.before); unrelated['edge_subnet'] = '10.242.0.0/28'
        managed_state.persist(self.network / 'desired.json', unrelated)
        with self.assertRaisesRegex(ValueError, 'intent changed'):
            self.transition()
        self.assertEqual(self.calls, [])
        self.assertEqual(managed_state.read(self.network / 'desired.json'), unrelated)

    def test_wrong_host_pin_rejects_before_network_commands(self):
        (self.system / 'etc/ssh/ssh_host_ed25519_key.pub').write_text(key(9))
        with self.assertRaisesRegex(ValueError, 'SSH host'): self.transition()
        self.assertEqual(self.calls, [])


if __name__ == '__main__': unittest.main()
