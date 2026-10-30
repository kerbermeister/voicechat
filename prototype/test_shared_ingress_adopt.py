from copy import deepcopy
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import shared_ingress
import test_shared_ingress_inspect


class LegacyIngressAdoptionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_shared_ingress_inspect.LegacyIngressInspectionTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root, self.plan = self.fixture.root, self.fixture.plan
        self.managed = False
        self.up_calls = []
        self.health_calls = []
        self.fail_up = None
        self.fail_health = False
        self.change_neighbor = False
        self.bad_model = False

    def execute(self, args, *, env=None):
        fixture = self.fixture
        if args[0] == 'docker' and args[1] == 'compose':
            if 'up' in args:
                self.up_calls.append(args)
                self.managed = 'compose.override.yaml' in ' '.join(args)
                if self.fail_up is not None:
                    failure, self.fail_up = self.fail_up, None
                    raise failure
                return b''
            model = deepcopy(fixture.config)
            if 'env-probe.json' in ' '.join(args):
                return json.dumps({'services': {'inspect': {'environment': {'VC_COMPOSE_FILE': '', 'VC_SEPARATOR': ''}}}}).encode()
            if str(self.plan / 'compose.override.yaml') in args:
                service = model['services']['caddy']
                service['image'] = shared_ingress.CADDY_IMAGE
                service['volumes'][0] = {'type': 'bind', 'source': str(self.root / 'runtime/caddy'),
                    'target': '/etc/caddy', 'read_only': True, 'bind': {'create_host_path': False}}
                if self.bad_model: model['services']['frontend']['environment']['PRIVATE_VALUE'] = 'changed'
            return json.dumps(model).encode()
        if args[0:2] == ['docker', 'inspect']:
            template = args[args.index('--format') + 1]
            if 'State.StartedAt}} {{.RestartCount' in template:
                return (fixture.neighbor + (' changed-start 1\n' if self.change_neighbor else ' preserved-start 0\n')).encode()
            if '"image_id"' not in template:
                current = deepcopy(fixture.current)
                if self.managed:
                    current['mounts'][0]['Destination'] = '/etc/caddy'
                    current['mounts'][0]['Source'] = str(self.root / 'runtime/caddy')
                current['image'] = current['image_id']
                return json.dumps(current).encode()
        return fixture.execute(args, env=env)

    def health(self, target, baseline, *, execute):
        self.health_calls.append(self.managed)
        if self.managed and self.fail_health:
            self.fail_health = False
            raise ValueError('Synthetic HTTPS mismatch')

    def adopt(self):
        return shared_ingress.adopt_legacy(self.root, self.plan, execute=self.execute,
            health=self.health, system_root=self.fixture.system)

    def test_directory_migration_and_retry_preserve_secrets_neighbors_and_git(self):
        record = self.adopt()
        self.assertTrue(self.managed)
        self.assertEqual(len(self.up_calls), 1)
        self.assertEqual(self.adopt(), record)
        self.assertEqual(len(self.up_calls), 1)
        self.assertFalse((self.root / 'pending.json').exists())
        self.assertEqual(self.fixture.environment.read_bytes(), self.fixture.original + (self.plan / 'compose.env-line').read_bytes())
        self.assertEqual(self.fixture.environment.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / 'runtime/caddy/Caddyfile').read_bytes(), self.fixture.legacy)
        self.assertEqual((self.fixture.repo / 'deploy/Caddyfile').read_bytes(), self.fixture.legacy)
        self.assertNotIn(self.fixture.secret, json.dumps(record))
        self.assertIn('--no-deps', self.up_calls[0]); self.assertIn('never', self.up_calls[0])

    def test_command_failure_and_https_mismatch_restore_original_environment_and_leaf_mount(self):
        for failure in ('up', 'health'):
            with self.subTest(failure=failure):
                if failure == 'up': self.fail_up = RuntimeError('synthetic failure')
                else: self.fail_health = True
                with self.assertRaises((RuntimeError, ValueError)): self.adopt()
                self.assertFalse(self.managed)
                self.assertEqual(self.fixture.environment.read_bytes(), self.fixture.original)
                self.assertFalse((self.root / 'pending.json').exists())
                self.assertFalse((self.root / 'current.json').exists())
                override = self.up_calls[-1][self.up_calls[-1].index('-f', self.up_calls[-1].index('-f') + 1) + 1]
                self.assertEqual(json.loads(Path(override).read_text())['services']['caddy']['image'], shared_ingress.CADDY_IMAGE)

    def test_process_death_leaves_journal_then_recovery_precedes_a_fresh_adoption(self):
        self.fail_up = SystemExit('synthetic kill')
        with self.assertRaises(SystemExit): self.adopt()
        self.assertTrue((self.root / 'pending.json').exists())
        with self.assertRaisesRegex(ValueError, 'Interrupted legacy adoption recovered'): self.adopt()
        self.assertEqual(self.fixture.environment.read_bytes(), self.fixture.original)
        self.assertFalse(self.managed)
        self.adopt()
        self.assertTrue(self.managed)

    def test_recovery_refuses_external_environment_edit_without_restarting_caddy(self):
        self.fail_up = SystemExit()
        with self.assertRaises(SystemExit): self.adopt()
        self.fixture.environment.write_bytes(b'FOREIGN_EDIT=preserve\n')
        calls = len(self.up_calls)
        with self.assertRaisesRegex(ValueError, 'externally changed'): self.adopt()
        self.assertEqual(len(self.up_calls), calls)
        self.assertEqual(self.fixture.environment.read_bytes(), b'FOREIGN_EDIT=preserve\n')
        self.assertTrue((self.root / 'pending.json').exists())

    def test_non_caddy_compose_change_is_rejected_before_any_live_write(self):
        self.bad_model = True
        with self.assertRaisesRegex(ValueError, 'neighboring Compose'): self.adopt()
        self.assertEqual(self.fixture.environment.read_bytes(), self.fixture.original)
        self.assertFalse((self.root / 'runtime').exists())
        self.assertFalse(self.up_calls)

    def test_unexpected_neighbor_restart_keeps_recovery_pending(self):
        original_health = self.health
        def health(*args, **kwargs):
            original_health(*args, **kwargs)
            if self.managed: self.change_neighbor = True
        self.health = health
        with self.assertRaisesRegex(ValueError, '[Nn]eighboring services'): self.adopt()
        self.assertFalse((self.root / 'current.json').exists())
        self.assertTrue((self.root / 'pending.json').exists())

    def test_tampered_private_recovery_snapshot_is_not_used(self):
        self.fail_up = SystemExit()
        with self.assertRaises(SystemExit): self.adopt()
        pending = managed_state.read(self.root / 'pending.json')
        (self.root / 'attempts' / pending['attempt'] / 'original.env').write_bytes(b'tampered')
        calls = len(self.up_calls)
        with self.assertRaisesRegex(ValueError, 'snapshot changed'): self.adopt()
        self.assertEqual(len(self.up_calls), calls)

    def test_recovery_refuses_another_host_or_edited_source_before_live_writes(self):
        self.fail_up = SystemExit()
        with self.assertRaises(SystemExit): self.adopt()
        source = self.fixture.repo / 'deploy/Caddyfile'
        source.write_text('foreign routes')
        calls = len(self.up_calls)
        with self.assertRaisesRegex(ValueError, 'Business source changed'): self.adopt()
        self.assertEqual(len(self.up_calls), calls)
        source.write_bytes(self.fixture.legacy)
        host = self.fixture.system / 'etc/ssh/ssh_host_ed25519_key.pub'
        host.write_text(self.fixture.inventory['core']['ssh_host_key'].replace('AAAAC3', 'AAAAD3'))
        with self.assertRaises(ValueError): self.adopt()
        self.assertEqual(len(self.up_calls), calls)

    def test_committed_intent_is_validated_before_finishing_interrupted_journal_cleanup(self):
        record = self.adopt()
        managed_state.persist(self.root / 'pending.json', record)
        self.assertEqual(self.adopt(), record)
        self.assertFalse((self.root / 'pending.json').exists())
        self.assertEqual(len(self.up_calls), 1)
        managed_state.persist(self.root / 'pending.json', {**record, 'attempt': '0' * 32})
        with self.assertRaisesRegex(ValueError, 'Conflicting'): self.adopt()
        self.assertTrue((self.root / 'pending.json').exists())


if __name__ == '__main__': unittest.main()
