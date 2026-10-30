from copy import deepcopy
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import ssl

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import shared_config
import shared_ingress
import test_shared_update


class CohostCertificatePreparationTests(unittest.TestCase):
    def setUp(self):
        self.business = test_shared_update.SharedBusinessUpdateTests()
        self.business.setUp()
        self.addCleanup(self.business.doCleanups)
        self.fixture = self.business.fixture
        self.root, self.system = self.business.root, self.business.system
        self.plan = shared_ingress.stage(self.root, self.fixture.repo, self.fixture.directory / 'edge',
            self.fixture.public, self.fixture.inventory, 'a', self.fixture.business,
            mode='legacy-certs', system_root=self.system)
        self.failed = False
        self.killed = False
        self.fail_certificate = False
        self.certified = 0
        self.calls = []

    def execute(self, args, *, env=None):
        self.calls.append(args)
        if args[:2] == ['docker', 'inspect'] and 'State.StartedAt}} {{.RestartCount' in args[args.index('--format') + 1]:
            return ''.join(identifier + (' caddy-start 0\n' if identifier == self.fixture.identifier else
                ' ' + self.business.neighbor_started + ' 0\n') for identifier in args[4:]).encode()
        result = self.business.execute(args, env=env)
        if args[:2] == ['docker', 'compose'] and 'reload' in args:
            if self.failed:
                self.failed = False
                raise RuntimeError('lost reload response')
            if self.killed:
                self.killed = False
                raise SystemExit('process died after reload')
        return result

    def certify(self, target):
        self.certified += 1
        self.assertEqual(target['mode'], 'legacy-certs')
        if self.fail_certificate: raise RuntimeError('synthetic issuance not ready')
        return {'chat.example.com': 'a' * 64, 'turn-a.example.com': 'b' * 64}

    def configure(self):
        return shared_config.prepare_certificates(self.root, self.plan, execute=self.execute,
            health=self.business.adoption.health, certify=self.certify, system_root=self.system)

    def reloads(self):
        return [args for args in self.calls if args[:2] == ['docker', 'compose'] and 'reload' in args]

    def test_certificate_sinks_preserve_old_upstream_and_select_only_http_challenge(self):
        text = (self.plan / 'Caddyfile').read_text()
        self.assertIn('reverse_proxy voicechat-web:80', text)
        self.assertIn('turn-a.example.com', text)
        self.assertEqual(text.count('disable_tlsalpn_challenge'), 2)
        self.assertIn('respond 421', text)
        changed = deepcopy(self.fixture.public)
        changed['edges'][0]['origin'] = 'https://entry-a.example.com'
        with self.assertRaisesRegex(ValueError, 'canonical cohost'): shared_ingress.legacy_certificates_config(self.fixture.business, changed, 'a')
        with self.assertRaisesRegex(ValueError, 'previous TURN'): shared_ingress.legacy_certificates_config(
            self.fixture.business + '\nturn-a.example.com {}\n', self.fixture.public, 'a')

    def test_reload_commit_and_retry_do_not_restart_containers_or_change_environment(self):
        original = self.fixture.environment.read_bytes()
        result = self.configure()
        self.assertEqual(result['current']['plan'], self.plan.name)
        self.assertEqual(self.fixture.environment.read_bytes(), original)
        self.assertFalse((self.root / 'configuration.json').exists())
        self.assertEqual(len(self.reloads()), 1)
        self.assertEqual(self.configure(), result)
        self.assertEqual(len(self.reloads()), 1)
        self.assertEqual(self.certified, 2)
        self.assertFalse(any('up' in args or 'pull' in args for args in self.calls))

    def test_lost_reload_response_and_issuance_failure_restore_known_routes(self):
        original_plan = managed_state.read(self.root / 'current.json')['plan']
        for failure in ('reload', 'certificate'):
            with self.subTest(failure=failure):
                self.failed = failure == 'reload'
                self.fail_certificate = failure == 'certificate'
                with self.assertRaises(RuntimeError): self.configure()
                self.assertEqual(managed_state.read(self.root / 'current.json')['plan'], original_plan)
                self.assertEqual((self.root / 'runtime/caddy/Caddyfile').read_bytes(), self.fixture.legacy)
                self.assertFalse((self.root / 'configuration.json').exists())

    def test_process_death_resumes_same_plan_and_fences_business_deploy(self):
        self.killed = True
        with self.assertRaises(SystemExit): self.configure()
        self.assertTrue((self.root / 'configuration.json').exists())
        with self.assertRaisesRegex(ValueError, 'pending ingress configuration'): self.business.update()
        with self.assertRaisesRegex(ValueError, 'pending ingress configuration'): self.business.adoption.adopt()
        self.assertEqual(self.configure()['current']['plan'], self.plan.name)
        self.assertFalse((self.root / 'configuration.json').exists())

    def test_external_environment_edit_is_preserved_and_recovery_stays_pending(self):
        self.killed = True
        with self.assertRaises(SystemExit): self.configure()
        self.fixture.environment.write_bytes(b'EXTERNAL_CHANGE=preserve\n')
        count = len(self.reloads())
        with self.assertRaisesRegex(ValueError, 'environment changed'): self.configure()
        self.assertEqual(len(self.reloads()), count)
        self.assertEqual(self.fixture.environment.read_bytes(), b'EXTERNAL_CHANGE=preserve\n')
        self.assertTrue((self.root / 'configuration.json').exists())

    def test_pointer_commit_crash_is_finished_without_another_reload(self):
        persist = managed_state.persist
        def die_after_commit(path, value):
            persist(path, value)
            if path == self.root / 'current.json': raise SystemExit('process died after pointer commit')
        with patch.object(managed_state, 'persist', side_effect=die_after_commit):
            with self.assertRaises(SystemExit): self.configure()
        reloads = len(self.reloads())
        self.assertEqual(self.configure()['current']['plan'], self.plan.name)
        self.assertEqual(len(self.reloads()), reloads)
        self.assertFalse((self.root / 'configuration.json').exists())

    def test_certificate_wait_is_bounded_and_does_not_disable_hostname_or_ca_validation(self):
        target = shared_ingress.read_plan(self.root, self.plan, system_root=self.system)[0]
        context = ssl.create_default_context()
        with patch.object(shared_config.ssl, 'create_default_context', return_value=context), patch.object(
                shared_config.socket, 'create_connection', side_effect=OSError('synthetic timeout')):
            with self.assertRaisesRegex(RuntimeError, 'issuance did not become ready'):
                shared_config.certificates_healthy(target, timeout=0)
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)

    def test_foreign_host_and_pending_business_update_are_rejected_before_reload(self):
        inventory = deepcopy(self.fixture.inventory)
        inventory['core']['public_ip'] = '203.0.113.15'
        self.plan = shared_ingress.stage(self.root, self.fixture.repo, self.fixture.directory / 'edge',
            self.fixture.public, inventory, 'a', self.fixture.business,
            mode='legacy-certs', system_root=self.system)
        with self.assertRaisesRegex(ValueError, 'installation or host'): self.configure()
        self.assertFalse(self.reloads())
        self.assertFalse((self.root / 'configuration.json').exists())
        managed_state.persist(self.root / 'update.json', {'schema': 1})
        self.calls.clear()
        with self.assertRaisesRegex(ValueError, 'pending business deployment'): self.configure()
        self.assertEqual(self.calls, [])

    def test_tampered_immutable_sources_are_not_activated(self):
        target, _ = shared_ingress.read_plan(self.root, self.plan, system_root=self.system)
        source = self.system / 'opt/voicechat/operators' / target['operator']['operator_sha256'] / 'infra/shared_config.py'
        source.write_text('foreign source')
        with self.assertRaisesRegex(ValueError, 'Operator source changed'): self.configure()
        self.assertFalse(self.reloads())
        self.assertFalse((self.root / 'configuration.json').exists())

    def test_later_business_deployment_keeps_the_certificate_sinks(self):
        self.configure()
        self.business.paths = ['deploy/Caddyfile']
        self.business.business = self.fixture.business.replace(' reverse_proxy', ' header X-Fixture changed\n reverse_proxy')
        result = self.business.update()
        target, files = shared_ingress.read_plan(self.root, self.root / 'plans' / result['plan'], system_root=self.system)
        self.assertEqual(target['mode'], 'legacy-certs')
        self.assertEqual(files['Caddyfile'].count(b'disable_tlsalpn_challenge'), 2)
        self.assertIn(b'header X-Fixture changed', files['Caddyfile'])
        self.assertIn(b'respond 421', files['Caddyfile'])


if __name__ == '__main__': unittest.main()
