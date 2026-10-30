from copy import deepcopy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import edge_deploy
import managed_state
import role_prepare
import role_release
import shared_cutover
import shared_front
import shared_ingress
import test_shared_config
import test_shared_front


class SharedPortCutoverTests(unittest.TestCase):
    def setUp(self):
        self.certificates = test_shared_config.CohostCertificatePreparationTests()
        self.certificates.setUp()
        self.addCleanup(self.certificates.doCleanups)
        self.certificates.configure()
        self.business = self.certificates.business
        self.fixture = self.certificates.fixture
        self.root, self.system = self.certificates.root, self.certificates.system
        self.old = managed_state.read(self.root / 'current.json')
        self.fixture.current['labels'] = {'com.docker.compose.project': 'deploy', 'com.docker.compose.service': 'caddy'}
        self.old_files = shared_ingress.read_plan(self.root, self.root / 'plans' / self.old['plan'], system_root=self.system)[1]
        inventory = deepcopy(self.fixture.inventory)
        self.profile = {'network': 'voicechat-shared-ingress', 'subnet': '172.29.0.0/29',
                        'legacy_ip': '172.29.0.2', 'ingress_ip': '172.29.0.3'}
        inventory['edges'][0]['shared_tls'] = self.profile
        self.edge = self.fixture.directory / 'edge'
        manifest = role_release.make(self.fixture.public, inventory, 'edge', 'a' * 40,
            'ghcr.io/fixture/web@sha256:' + '1' * 64, 'a')
        role_prepare.prepare(self.edge, self.fixture.public, inventory, manifest)
        record = edge_deploy.record_for(self.fixture.public, inventory, manifest)
        managed_state.persist(self.edge / 'state.json', {'schema': 1, 'current': record, 'previous': None, 'pending': None})
        self.front_plan = shared_front.prepare(self.root / 'front', self.edge, manifest)
        self.front = test_shared_front.SharedFrontWarmTests()
        self.front.plan = self.front_plan
        self.front.model = json.loads((self.front_plan / 'compose.json').read_text())
        self.front.networks = {}; self.front.container = None; self.front.calls = []
        self.front.fail_parse = False; self.front.interrupt = False
        self.front.create(); self.front.container['id'] = 'f' * 64
        managed_state.persist(self.root / 'front/warm.json', {'schema': 1, 'plan': self.front_plan.name, 'phase': 'running'})
        self.plan = shared_ingress.stage(self.root, self.fixture.repo, self.edge,
            self.fixture.public, inventory, 'a', self.fixture.business, mode='shared', system_root=self.system)
        self.public_front = False
        self.kill = None
        self.fail_public = False
        self.fail_warm = False
        self.events = []

    def execute(self, args, *, env=None):
        if args[:2] == ['docker', 'network']: return self.front.execute(args, env=env)
        if args[:2] == ['docker', 'ps'] and any('project=voicechat-shared-front' in item for item in args):
            return b'f' * 64 if self.front.container else b''
        if args[:2] == ['docker', 'inspect'] and args[-1] == 'f' * 64:
            return json.dumps(self.front.container).encode()
        if args[:2] == ['docker', 'compose'] and 'up' in args:
            if '--project-name' in args:
                self.public_front = str(self.front_plan / 'compose.public.json') in args
                self.front.create(); self.front.container['id'] = 'f' * 64
                ports = self.front.container['ports']['8443/tcp']
                if self.public_front: ports.insert(0, {'HostIp': '', 'HostPort': '443'})
                self.events.append('front-public' if self.public_front else 'front-warm')
                if self.kill == ('front' if self.public_front else 'rollback-front'):
                    self.kill = None; raise SystemExit('lost front recreation response')
            else:
                shared = b'"443:443"' not in (self.root / 'runtime/compose.override.yaml').read_bytes()
                self.fixture.current['ports'] = {'80/tcp': self.fixture.ports['80/tcp']} if shared else deepcopy(self.fixture.ports)
                self.fixture.current['networks'] = {'deploy_default': {}}
                if shared: self.fixture.current['networks'][self.profile['network']] = {'IPAddress': self.profile['legacy_ip']}
                self.fixture.current['running'] = True
                self.fixture.live = {'unreviewed': True}
                self.events.append('caddy')
                if self.kill == 'caddy':
                    self.kill = None; raise SystemExit('lost Caddy recreation response')
            return b''
        return self.certificates.execute(args, env=env)

    def business_health(self, target, baseline, *, execute):
        caddy_has_public = '443/tcp' in self.fixture.current['ports']
        if caddy_has_public == self.public_front:
            raise ValueError('Neither or both frontends own the fixture public port')

    def edge_health(self, root, record, *, execute, warm_port=None):
        if warm_port is not None:
            self.assertEqual(warm_port, 19443)
            if self.fail_warm: raise ValueError('warm readiness failed')
        else:
            self.assertTrue(self.public_front)
            if self.fail_public: raise ValueError('public readiness failed')

    def activate(self):
        return shared_cutover.activate(self.root, self.plan, self.front_plan, execute=self.execute,
            check_edge=self.edge_health, check_business=self.business_health, system_root=self.system)

    def test_full_migration_reuses_parent_lock_and_keeps_neighbor_deployments_fenced(self):
        with managed_state.locked(self.root):
            with self.assertRaises(BlockingIOError): self.activate()
            self.assertEqual(self.events, [])
            result = shared_cutover._activate_locked(self.root, self.plan, self.front_plan,
                execute=self.execute, check_edge=self.edge_health,
                check_business=self.business_health, system_root=self.system)
            self.assertEqual(result['plan'], self.plan.name)
            with self.assertRaises(BlockingIOError):
                with managed_state.locked(self.root): pass
        # The coordinator releasing its lock also releases the neighbor fence.
        self.assertEqual(self.activate(), result)
        self.assertEqual(self.events, ['caddy', 'front-public'])

    def test_cutover_and_repeat_preserve_environment_and_select_shared_ownership(self):
        environment = self.fixture.environment.read_bytes()
        result = self.activate()
        self.assertEqual(result['plan'], self.plan.name)
        self.assertEqual(set(result['ports']), {'80/tcp'})
        self.assertEqual(result['networks'], ['deploy_default', self.profile['network']])
        self.assertEqual(self.events, ['caddy', 'front-public'])
        self.assertEqual(self.fixture.environment.read_bytes(), environment)
        self.assertEqual(managed_state.read(self.root / 'front/warm.json')['phase'], 'public')
        self.assertFalse((self.root / 'configuration.json').exists())
        self.activate()
        self.assertEqual(self.events, ['caddy', 'front-public'])

    def test_failed_public_readiness_releases_front_port_before_restoring_caddy(self):
        self.fail_public = True
        with self.assertRaisesRegex(ValueError, 'public readiness'): self.activate()
        self.assertEqual(self.events, ['caddy', 'front-public', 'front-warm', 'caddy'])
        self.assertEqual(managed_state.read(self.root / 'current.json')['plan'], self.old['plan'])
        self.assertEqual((self.root / 'runtime/caddy/Caddyfile').read_bytes(), self.old_files['Caddyfile'])
        self.assertEqual(managed_state.read(self.root / 'front/warm.json')['phase'], 'running')
        self.assertFalse((self.root / 'configuration.json').exists())

    def test_process_death_after_command_boundary_resumes_same_cutover(self):
        for phase in ('caddy', 'front'):
            with self.subTest(phase=phase):
                # Each successful subcase starts from a fresh independent fixture.
                if phase == 'front':
                    case = SharedPortCutoverTests(); case.setUp()
                    self.addCleanup(case.doCleanups)
                else: case = self
                case.kill = phase
                with self.assertRaises(SystemExit): case.activate()
                self.assertTrue((case.root / 'configuration.json').exists())
                self.assertEqual(case.activate()['plan'], case.plan.name)

    def test_commit_boundary_crash_only_validates_and_cleans_up(self):
        persist = managed_state.persist
        def interrupted(path, value):
            persist(path, value)
            if path == self.root / 'current.json': raise SystemExit('after pointer commit')
        with patch.object(managed_state, 'persist', side_effect=interrupted):
            with self.assertRaises(SystemExit): self.activate()
        events = self.events[:]
        self.activate()
        self.assertEqual(self.events, events)
        self.assertFalse((self.root / 'configuration.json').exists())

    def test_foreign_runtime_after_interruption_is_preserved_without_recovery_commands(self):
        self.kill = 'caddy'
        with self.assertRaises(SystemExit): self.activate()
        path = self.root / 'runtime/compose.override.yaml'; path.write_bytes(b'foreign edit\n')
        events = self.events[:]
        with self.assertRaisesRegex(ValueError, 'Unknown ingress runtime'): self.activate()
        self.assertEqual(path.read_bytes(), b'foreign edit\n')
        self.assertEqual(self.events, events)
        self.assertTrue((self.root / 'configuration.json').exists())

    def test_warm_readiness_failure_stops_before_port_changes_and_journal_claim(self):
        self.fail_warm = True
        with self.assertRaisesRegex(ValueError, 'warm readiness'): self.activate()
        self.assertFalse(self.events)
        self.assertFalse((self.root / 'configuration.json').exists())

    def test_interrupted_rollback_finishes_before_accepting_a_fresh_attempt(self):
        self.fail_public = True
        self.kill = 'rollback-front'
        with self.assertRaises(SystemExit): self.activate()
        self.assertEqual(managed_state.read(self.root / 'configuration.json')['phase'], 'rollback')
        with self.assertRaisesRegex(RuntimeError, 'rollback completed'): self.activate()
        self.assertEqual(self.events[-2:], ['front-warm', 'caddy'])
        self.assertEqual(managed_state.read(self.root / 'current.json')['plan'], self.old['plan'])
        self.assertFalse((self.root / 'configuration.json').exists())

    def test_owned_stopped_caddy_after_recreation_failure_can_resume(self):
        self.kill = 'caddy'
        with self.assertRaises(SystemExit): self.activate()
        self.fixture.current['running'] = False
        self.assertEqual(self.activate()['plan'], self.plan.name)

    def test_unknown_caddy_volume_is_not_replaced_by_recovery(self):
        self.kill = 'caddy'
        with self.assertRaises(SystemExit): self.activate()
        events = self.events[:]
        volume = next(item for item in self.fixture.current['mounts'] if item['Destination'] == '/data')
        volume['Name'] = 'foreign-volume'
        with self.assertRaisesRegex(ValueError, 'data volume changed'): self.activate()
        self.assertEqual(self.events, events)

    def test_external_caddy_ports_and_active_routes_are_not_replaced_after_interruption(self):
        self.kill = 'caddy'
        with self.assertRaises(SystemExit): self.activate()
        events = self.events[:]
        current = self.fixture.current
        ports = deepcopy(current['ports'])
        current['ports']['80/tcp'][0]['HostPort'] = '8080'
        with self.assertRaisesRegex(ValueError, 'Unknown Caddy ports'): self.activate()
        self.assertEqual(self.events, events)
        current['ports'] = ports
        self.fixture.live = {'foreign-routes': True}
        with self.assertRaisesRegex(ValueError, 'Unknown active Caddy routes'): self.activate()
        self.assertEqual(self.events, events)
        self.assertTrue((self.root / 'configuration.json').exists())


if __name__ == '__main__': unittest.main()
