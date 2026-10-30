from copy import deepcopy
from pathlib import Path
import shutil
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import network_bootstrap
import network_runtime
import role_deploy
import test_network_bootstrap
from test_firewall_runtime import Firewall
from test_tunnel_runtime import Network


class InitialNetworkRollbackTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_network_bootstrap.NetworkBootstrapTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root, self.state = self.fixture.root, self.fixture.state_root
        self.multi = deepcopy(self.fixture.value)
        self.value = deepcopy(self.multi)
        self.value['inventory']['edges'] = [{'id': 'a', 'host': 'core'}]
        self.value['public_keys']['nodes'] = {'core': self.value['public_keys']['nodes']['core']}
        self.firewall, self.tunnel = Firewall(self.value), Network()
        self.calls = []
        self.containers = False
        self.monitor = False
        self.interrupt = False
        self.fail_restore = False
        self.docker_requires_network = False
        network_runtime.reconcile(self.state, self.value, run=self.command)
        network_bootstrap.install(self.root, run=self.command, shared_host=True)
        self.fingerprint = network_runtime.fingerprint(self.value)
        self.before = (self.state / 'desired.json').read_bytes()
        self.calls.clear()

    def command(self, *args):
        self.calls.append(args)
        if args[-1:] == ('--version',): return ''
        if args[:3] == ('nft', 'delete', 'table'):
            self.firewall.tables = [item for item in self.firewall.tables if item['name'] != args[-1]]
            return ''
        if args[0] == 'nft': return self.firewall.run(*args)
        if args == ('ip', 'link', 'delete', 'wg-vc'):
            self.tunnel.links = []; self.tunnel.addresses = []
            self.tunnel.routes = [item for item in self.tunnel.routes if item.get('dev') != 'wg-vc']
            if self.interrupt:
                self.interrupt = False
                raise SystemExit('Lost link deletion response')
            return ''
        if args == ('wg', 'show', 'wg-vc', 'peers'): return '\n'.join(self.tunnel.peers)
        if args[0] in ('ip', 'wg'): return self.tunnel.run(*args)
        if args[:2] == ('docker', 'ps'):
            if not self.containers: return ''
            return 'aaaaaaaaaaaa voicechat control' if 'service' in args[-1] else 'aaaaaaaaaaaa voicechat'
        if args[:2] == ('systemctl', 'show'):
            if '--property=SystemState' in args: return 'running'
            if '--property=Requires,BindsTo' in args:
                return 'voicechat-network.service' if self.docker_requires_network else 'containerd.service'
            return 'active' if self.monitor else 'inactive'
        if args[:2] == ('systemctl', 'start'):
            if self.fail_restore: raise RuntimeError('Interrupted restoration')
            network_runtime.reconcile(self.state, run=self.command)
        return ''

    def retire(self): return network_bootstrap.retire_initial(self.root, self.fingerprint, run=self.command)
    def restore(self):
        return network_bootstrap.install(self.root, run=self.command, shared_host=True,
                                         restore_initial=self.fingerprint)

    def test_retirement_and_same_intent_restore_preserve_key_and_neighbor_firewall(self):
        self.retire()
        self.assertEqual(self.firewall.tables, [{'family': 'inet', 'name': 'foreign', 'comment': 'unrelated'}])
        self.assertEqual(self.tunnel.links, [])
        self.assertFalse((self.root / network_bootstrap.UNIT).exists())
        self.assertFalse((self.root / network_bootstrap.DROP_IN).exists())
        self.assertEqual((self.state / 'desired.json').read_bytes(), self.before)
        self.retire()
        with self.assertRaisesRegex(ValueError, 'explicit initial network'):
            network_bootstrap.install(self.root, run=self.command, shared_host=True)
        with self.assertRaisesRegex(ValueError, 'retired'):
            network_runtime.reconcile(self.state, run=self.command)
        self.restore()
        self.assertTrue(self.tunnel.links)
        self.assertEqual(len(self.firewall.tables), 2)
        self.assertEqual((self.state / 'desired.json').read_bytes(), self.before)
        self.assertFalse((self.state / 'boot-install/initial-rollback.json').exists())
        self.assertFalse(any('restart' in call or ('docker' in call and 'stop' in call) for call in self.calls))

    def test_initial_runtime_failure_before_boot_install_can_be_retired_and_retried(self):
        receipt = managed_state.read(self.state / 'boot-install/desired.json')
        for name in (network_bootstrap.UNIT, network_bootstrap.DROP_IN): (self.root / name).unlink()
        shutil.rmtree(self.root / 'opt/voicechat/network' / receipt['source_sha256'])
        (self.state / 'boot-install/desired.json').unlink()
        self.retire()
        self.restore()
        self.assertTrue(self.tunnel.links)
        self.assertEqual((self.state / 'desired.json').read_bytes(), self.before)

    def test_process_death_after_link_delete_finishes_retirement_before_restore(self):
        self.interrupt = True
        with self.assertRaises(SystemExit): self.retire()
        self.assertEqual(managed_state.read(self.state / 'boot-install/initial-rollback.json')['phase'], 'retiring')
        with self.assertRaisesRegex(ValueError, 'same explicit initial'): self.restore()
        self.retire()
        self.restore()

    def test_roles_and_network_source_upgrade_remain_fenced_until_restoration_commits(self):
        self.retire()
        self.fail_restore = True
        with self.assertRaisesRegex(RuntimeError, 'Interrupted restoration'): self.restore()
        with self.assertRaisesRegex(ValueError, 'rollback/restoration'):
            with role_deploy.network_ready(self.value['inventory'], 'core', self.value['edge_subnet'],
                    execute=lambda *a: b'active', directory=self.state): pass
        with self.assertRaisesRegex(ValueError, 'initial network rollback'):
            network_bootstrap.upgrade(self.root, run=self.command, shared_host=True)
        self.fail_restore = False
        self.restore()

    def test_live_role_containers_or_monitors_prevent_any_retirement(self):
        self.containers = True
        with self.assertRaisesRegex(ValueError, 'Remove all owned'): self.retire()
        self.containers = False; self.monitor = True
        with self.assertRaisesRegex(ValueError, 'Stop role boot monitors'): self.retire()
        self.assertFalse((self.state / 'boot-install/initial-rollback.json').exists())
        self.assertTrue(self.tunnel.links)

    def test_unexpected_docker_dependency_cannot_stop_neighbors_during_retirement(self):
        self.docker_requires_network = True
        with self.assertRaisesRegex(ValueError, 'Docker must not require'): self.retire()
        self.assertTrue(self.tunnel.links)
        self.assertFalse((self.state / 'boot-install/initial-rollback.json').exists())
        self.assertFalse(any(call[:2] == ('systemctl', 'disable') for call in self.calls))

    def test_remote_peers_cannot_be_undone_by_initial_rollback(self):
        managed_state.persist(self.state / 'desired.json', self.multi)
        with self.assertRaisesRegex(ValueError, 'peerless core'): self.retire()
        managed_state.persist(self.state / 'desired.json', self.value)
        self.tunnel.peers = ['unexpected-live-peer']
        with self.assertRaisesRegex(ValueError, 'live peers'): self.retire()
        self.assertFalse((self.state / 'boot-install/initial-rollback.json').exists())

    def test_foreign_unit_or_table_is_preserved_before_any_change(self):
        unit = self.root / network_bootstrap.UNIT
        before = unit.read_bytes(); unit.write_text('foreign')
        with self.assertRaisesRegex(ValueError, 'Unknown network installation'): self.retire()
        self.assertEqual(unit.read_text(), 'foreign')
        unit.write_bytes(before)
        self.firewall.tables[-1]['comment'] = 'foreign-owner'
        with self.assertRaisesRegex(ValueError, 'foreign or unclaimed'): self.retire()
        self.assertTrue(self.tunnel.links)
        self.assertFalse((self.state / 'boot-install/initial-rollback.json').exists())


if __name__ == '__main__': unittest.main()
