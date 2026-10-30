from copy import deepcopy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import shared_ingress
import shared_update
import role_bootstrap
import test_shared_ingress_adopt


class SharedBusinessUpdateTests(unittest.TestCase):
    def setUp(self):
        self.adoption = test_shared_ingress_adopt.LegacyIngressAdoptionTests()
        self.adoption.setUp()
        self.addCleanup(self.adoption.doCleanups)
        self.adoption.adopt()
        self.fixture = self.adoption.fixture
        self.root, self.system = self.fixture.root, self.fixture.system
        self.repo = self.fixture.repo
        self.head, self.revision = 'd' * 40, 'e' * 40
        self.origin = 'git@example.invalid:owner/business.git'
        self.business = self.fixture.business
        self.compose = (self.repo / 'deploy/docker-compose.yml').read_bytes()
        self.paths = ['.github/workflows/deploy.yml']
        self.git_dirty = b'deploy/Caddyfile\n'
        self.calls = []
        self.fail_reload = False
        self.fail_merge = False
        self.fail_application = False
        self.protected_change = False
        self.neighbor_started = 'preserved-start'
        self.installed = shared_update.install(self.root, execute=self.execute,
            health=self.adoption.health, system_root=self.system)
        self.calls.clear()

    def execute(self, args, *, env=None):
        self.calls.append(args)
        if args[0] == 'git':
            if 'config' in args: return self.origin.encode()
            if 'branch' in args: return b'main'
            if 'rev-parse' in args: return (self.revision if args[-1] == 'FETCH_HEAD' else self.head).encode()
            if 'show' in args:
                revision, path = args[-1].split(':', 1)
                if path == 'deploy/docker-compose.yml': return self.compose
                return (self.business if revision != 'd' * 40 else self.fixture.business).encode()
            if '--cached' in args or 'fetch' in args or 'merge-base' in args: return b''
            if '--name-only' in args:
                return self.git_dirty if 'HEAD' in args else '\n'.join(self.paths).encode()
            if 'restore' in args:
                (self.repo / 'deploy/Caddyfile').write_text(self.fixture.business)
                self.git_dirty = b''
                return b''
            if 'merge' in args:
                self.head = args[-1]
                (self.repo / 'deploy/Caddyfile').write_text(self.business)
                (self.repo / 'deploy/docker-compose.yml').write_bytes(self.compose)
                self.git_dirty = b''
                if self.fail_merge:
                    self.fail_merge = False
                    raise SystemExit('process died after merge')
                return b''
        if args[:2] == ['docker', 'compose']:
            if 'config' in args:
                model = deepcopy(self.fixture.config)
                service = model['services']['caddy']
                service['image'] = shared_ingress.CADDY_IMAGE
                service['volumes'][0] = {'type': 'bind', 'source': str(self.root / 'runtime/caddy'),
                    'target': '/etc/caddy', 'read_only': True, 'bind': {'create_host_path': False}}
                sources = [args[index + 1] for index, value in enumerate(args) if value == '-f']
                if self.protected_change and sources[0] != str(self.repo / 'deploy/docker-compose.yml'):
                    service['ports'][0]['published'] = '8080'
                return json.dumps(model).encode()
            if 'exec' in args:
                if self.fail_reload:
                    self.fail_reload = False
                    raise RuntimeError('synthetic reload failed')
                content = (self.root / 'runtime/caddy/Caddyfile').read_bytes()
                self.fixture.live = self.fixture.active if content == self.fixture.legacy else {'unreviewed': True}
                return b''
            if 'pull' in args or 'up' in args:
                if 'up' in args and self.fail_application:
                    self.fail_application = False
                    raise RuntimeError('synthetic application failure')
                return b''
        if args[:2] == ['docker', 'inspect'] and 'State.StartedAt}} {{.RestartCount' in args[args.index('--format') + 1]:
            return (self.fixture.neighbor + ' ' + self.neighbor_started + ' 0\n').encode()
        return self.adoption.execute(args, env=env)

    def update(self):
        return shared_update.update(self.root, execute=self.execute,
            health=self.adoption.health, system_root=self.system)

    def mutations(self):
        return [args for args in self.calls if args[:2] == ['docker', 'compose'] and
                any(word in args for word in ('up', 'pull', 'exec'))]

    def test_installed_wrapper_and_workflow_only_update_preserve_ingress_without_reload(self):
        wrapper = self.system / 'usr/local/sbin/voicechat-shared-deploy'
        self.assertIn(b'shared_update.py --root ', wrapper.read_bytes())
        self.assertIn(b'exec /usr/bin/python3 -B ', wrapper.read_bytes())
        self.assertEqual(wrapper.stat().st_mode & 0o777, 0o755)
        environment = self.fixture.environment.read_bytes()
        result = self.update()
        self.assertEqual(result['baseline']['head'], self.revision)
        self.assertEqual(self.fixture.environment.read_bytes(), environment)
        self.assertEqual((self.repo / 'deploy/Caddyfile').read_text(), self.fixture.business)
        self.assertEqual((self.root / 'runtime/caddy/Caddyfile').read_bytes(), self.fixture.legacy)
        self.assertFalse(self.mutations())
        self.assertFalse((self.root / 'update.json').exists())
        self.assertNotIn(self.fixture.secret, json.dumps(result))
        self.assertEqual(self.update(), result)

    def test_business_routes_reload_without_restarting_neighboring_applications(self):
        self.paths = ['deploy/Caddyfile']
        self.business = self.fixture.business.replace(' reverse_proxy', ' header X-Fixture changed\n reverse_proxy')
        self.update()
        self.assertEqual([args[args.index('exec')] for args in self.mutations()], ['exec'])
        self.assertIn(b'X-Fixture changed', (self.root / 'runtime/caddy/Caddyfile').read_bytes())

    def test_application_update_uses_managed_overlay_and_preserves_owned_environment(self):
        self.paths = ['backend/main.py']
        self.update()
        actions = self.mutations()
        self.assertEqual(len(actions), 3)
        self.assertTrue(any('pull' in args for args in actions))
        self.assertTrue(any('up' in args for args in actions))
        self.assertTrue(all(str(self.root / 'runtime/compose.override.yaml') in args for args in actions))
        up = next(args for args in actions if 'up' in args)
        self.assertIn('--wait', up); self.assertIn('--no-build', up); self.assertIn('never', up)

    def test_reload_failure_resumes_pinned_revision_without_fetching_again(self):
        self.paths = ['deploy/Caddyfile']
        self.business = self.fixture.business + '\n# reviewed route revision\n'
        self.fail_reload = True
        with self.assertRaises(RuntimeError): self.update()
        self.assertTrue((self.root / 'update.json').exists())
        self.calls.clear(); self.revision = 'f' * 40
        result = self.update()
        self.assertEqual(result['baseline']['head'], 'e' * 40)
        self.assertFalse(any('fetch' in args or 'merge' in args for args in self.calls))
        self.assertFalse((self.root / 'update.json').exists())

    def test_process_death_after_merge_is_recoverable_and_does_not_checkout_unrelated_paths(self):
        self.fail_merge = True
        with self.assertRaises(SystemExit): self.update()
        self.assertEqual(managed_state.read(self.root / 'update.json')['phase'], 'checkout')
        self.update()
        restore = [args for args in self.calls if 'restore' in args]
        self.assertEqual(len(restore), 1)
        self.assertEqual(restore[0][-1], 'deploy/Caddyfile')
        self.assertFalse(any('checkout' in args for args in self.calls))

    def test_protected_port_change_and_new_git_origin_are_rejected_before_checkout(self):
        self.protected_change = True
        with self.assertRaisesRegex(ValueError, 'protected ingress'): self.update()
        self.assertEqual(self.head, 'd' * 40)
        self.assertFalse((self.root / 'update.json').exists())
        self.assertFalse(self.mutations())
        self.origin = 'git@example.invalid:other/repository.git'
        with self.assertRaisesRegex(ValueError, 'origin changed'): self.update()

    def test_pending_update_fences_adoption_and_preserves_external_environment_edit(self):
        self.fail_merge = True
        with self.assertRaises(SystemExit): self.update()
        self.fixture.environment.write_bytes(b'EXTERNAL_CHANGE=preserve\n')
        self.calls.clear()
        with self.assertRaisesRegex(ValueError, 'environment changed'): self.update()
        self.assertFalse(self.mutations())
        with self.assertRaisesRegex(ValueError, 'pending business deployment'): self.adoption.adopt()

    def test_external_neighbor_restart_between_deployments_is_not_treated_as_our_mutation(self):
        self.neighbor_started = 'legitimate-reboot-start'
        result = self.update()
        self.assertEqual(result['baseline']['neighbors'], [self.fixture.neighbor + ' legitimate-reboot-start 0'])

    def test_foreign_wrapper_and_concurrent_operator_are_not_overwritten_or_run(self):
        wrapper = self.system / 'usr/local/sbin/voicechat-shared-deploy'
        wrapper.write_text('#!/bin/sh\n# foreign executable\n')
        with self.assertRaisesRegex(ValueError, 'executable differs'): self.update()
        with self.assertRaisesRegex(ValueError, 'wrapper changed'):
            shared_update.install(self.root, execute=self.execute, health=self.adoption.health, system_root=self.system)
        self.assertIn('foreign executable', wrapper.read_text())
        wrapper.write_bytes(shared_update._wrapper(self.root, self.installed['operator']))
        self.calls.clear()
        with managed_state.locked(self.root):
            with self.assertRaises(BlockingIOError): self.update()
        self.assertEqual(self.calls, [])

    def test_edited_working_source_after_interruption_is_preserved(self):
        self.fail_merge = True
        with self.assertRaises(SystemExit): self.update()
        source = self.repo / 'deploy/Caddyfile'
        source.write_text('foreign route change\n')
        self.calls.clear()
        with self.assertRaisesRegex(ValueError, 'changed externally'): self.update()
        self.assertEqual(source.read_text(), 'foreign route change\n')
        self.assertFalse(self.mutations())
        self.assertTrue((self.root / 'update.json').exists())

    def test_environment_edit_during_health_check_blocks_recovery_commands(self):
        self.paths = ['deploy/Caddyfile']
        self.business = self.fixture.business + '\n# changed fixture routes\n'
        original_health = self.adoption.health
        def health(*args, **kwargs):
            original_health(*args, **kwargs)
            if self.fixture.live != self.fixture.active:
                self.fixture.environment.write_bytes(b'EXTERNAL_EDIT=preserve\n')
        self.adoption.health = health
        with self.assertRaisesRegex(ValueError, 'externally changed Compose environment'): self.update()
        reloads = [args for args in self.mutations() if 'reload' in args]
        self.assertEqual(len(reloads), 1)
        self.assertEqual(self.fixture.environment.read_bytes(), b'EXTERNAL_EDIT=preserve\n')
        self.assertTrue((self.root / 'update.json').exists())

    def test_application_failure_keeps_same_target_pending_without_undoing_data_or_git(self):
        self.paths = ['backend/main.py']
        self.fail_application = True
        environment = self.fixture.environment.read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'application failure'): self.update()
        self.assertEqual(self.head, 'e' * 40)
        self.assertEqual(self.fixture.environment.read_bytes(), environment)
        self.assertEqual(managed_state.read(self.root / 'update.json')['phase'], 'applying')
        self.calls.clear(); self.revision = 'f' * 40
        self.assertEqual(self.update()['baseline']['head'], 'e' * 40)
        self.assertFalse(any('fetch' in args or 'restore' in args or 'down' in args for args in self.calls))


class SharedModeBusinessUpdateTests(unittest.TestCase):
    """Model an already committed port cutover; never perform that migration."""
    def setUp(self):
        self.business = SharedBusinessUpdateTests()
        self.business.setUp()
        self.addCleanup(self.business.doCleanups)
        b = self.business
        f = b.fixture
        inventory = deepcopy(f.inventory)
        profile = {'network': 'voicechat-shared-ingress', 'subnet': '172.29.0.0/29',
                   'legacy_ip': '172.29.0.2', 'ingress_ip': '172.29.0.3'}
        inventory['edges'][0]['shared_tls'] = profile
        plan = shared_ingress.stage(b.root, b.repo, f.directory / 'edge', f.public,
            inventory, 'a', f.business, mode='shared', system_root=b.system)
        target, files = shared_ingress.read_plan(b.root, plan, system_root=b.system)
        record = managed_state.read(b.root / 'current.json')
        record['plan'] = plan.name
        record['ports'] = {'80/tcp': f.ports['80/tcp']}
        record['networks'] = ['deploy_default', profile['network']]
        f.current['ports'] = record['ports']
        f.current['networks'][profile['network']] = {'IPAddress': profile['legacy_ip']}
        f.config['services']['caddy']['ports'] = f.config['services']['caddy']['ports'][:1]
        f.config['services']['caddy']['networks']['shared-tls'] = {'ipv4_address': profile['legacy_ip']}
        f.config['networks']['shared-tls'] = {'name': profile['network'], 'external': True}
        f.legacy = files['Caddyfile']
        shared_ingress._write(b.root / 'runtime/caddy/Caddyfile', f.legacy)
        shared_ingress._write(b.root / 'runtime/compose.override.yaml', files['compose.override.yaml'])
        managed_state.persist(b.root / 'current.json', record)
        self.target = target
        b.calls.clear()

    def assert_shared(self, record):
        b = self.business
        target, files = shared_ingress.read_plan(b.root, b.root / 'plans' / record['plan'], system_root=b.system)
        self.assertEqual(target['mode'], 'shared')
        self.assertIn(b'allow 172.29.0.3/32', files['Caddyfile'])
        self.assertIn(b'fallback_policy reject', files['Caddyfile'])
        self.assertIn(b'respond 421', files['Caddyfile'])
        self.assertNotIn(b'reverse_proxy voicechat-web', files['Caddyfile'])
        self.assertNotIn(b'"443:443"', files['compose.override.yaml'])
        self.assertEqual(record['networks'], ['deploy_default', 'voicechat-shared-ingress'])

    def test_workflow_and_routes_keep_shared_proxy_and_certificate_sinks(self):
        b = self.business
        self.assert_shared(b.update())
        self.assertFalse(b.mutations())
        b.revision = 'f' * 40
        b.paths = ['deploy/Caddyfile']
        b.business = b.fixture.business.replace(' reverse_proxy', ' header X-Fixture changed\n reverse_proxy')
        self.assert_shared(b.update())
        self.assertFalse(any('up' in args or 'pull' in args for args in b.calls))

    def test_shared_reload_failure_preserves_mode_and_resumes_same_target(self):
        b = self.business
        b.paths = ['deploy/Caddyfile']
        b.business = b.fixture.business + '\n# changed business routes\n'
        b.fail_reload = True
        with self.assertRaises(RuntimeError): b.update()
        self.assertEqual((b.root / 'runtime/caddy/Caddyfile').read_bytes(), b.fixture.legacy)
        self.assertTrue((b.root / 'update.json').exists())
        self.assert_shared(b.update())
        self.assertFalse((b.root / 'update.json').exists())

    def test_legacy_recovery_rejects_shared_but_installed_manager_accepts_it(self):
        b = self.business
        record = managed_state.read(b.root / 'current.json')
        with self.assertRaisesRegex(ValueError, 'Legacy journal'):
            shared_ingress._attempt(b.root, record, system_root=b.system)
        shared_update.install(b.root, execute=b.execute, health=b.adoption.health, system_root=b.system)
        self.assert_shared(b.update())


class SharedManagerSourceUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.fixture = SharedBusinessUpdateTests()
        # Model an installed, verified historical source roster, as the role
        # bootstrap tests do; no old Python package is executed by this unit test.
        with patch.object(role_bootstrap, 'SOURCES', role_bootstrap.MANAGER_SOURCES):
            self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.old = managed_state.read(self.fixture.root / 'manager.json')
        self.environment = self.fixture.fixture.environment.read_bytes()

    def install(self):
        return shared_update.install(self.fixture.root, execute=self.fixture.execute,
            health=self.fixture.adoption.health, system_root=self.fixture.system)

    def test_code_upgrade_changes_only_owned_pointer_and_wrapper(self):
        result = self.install()
        self.assertNotEqual(result['operator']['operator_sha256'], self.old['operator']['operator_sha256'])
        self.assertEqual(self.fixture.fixture.environment.read_bytes(), self.environment)
        self.assertFalse(self.fixture.mutations())
        self.assertEqual((self.fixture.root / 'runtime/caddy/Caddyfile').read_bytes(), self.fixture.fixture.legacy)
        role_bootstrap.verify_record(self.fixture.system, self.old['operator'])
        self.assertEqual(self.install(), result)

    def test_pointer_commit_interruption_fences_old_wrapper_and_install_resumes(self):
        persist = managed_state.persist
        def die_after_pointer(path, value):
            persist(path, value)
            if path == self.fixture.root / 'current.json': raise SystemExit('interrupted owner upgrade')
        with patch.object(managed_state, 'persist', side_effect=die_after_pointer):
            with self.assertRaises(SystemExit): self.install()
        self.fixture.calls.clear()
        with self.assertRaisesRegex(ValueError, 'sources differ'): self.fixture.update()
        self.assertFalse(any('fetch' in args for args in self.fixture.calls))
        self.install()
        self.assertFalse(self.fixture.mutations())
        self.assertEqual(self.fixture.fixture.environment.read_bytes(), self.environment)

    def test_wrapper_receipt_interruption_fences_commands_and_install_resumes(self):
        persist = managed_state.persist
        def die_before_receipt(path, value):
            if path == self.fixture.root / 'manager.json': raise SystemExit('interrupted wrapper receipt')
            persist(path, value)
        with patch.object(managed_state, 'persist', side_effect=die_before_receipt):
            with self.assertRaises(SystemExit): self.install()
        self.fixture.calls.clear()
        with self.assertRaisesRegex(ValueError, 'executable differs'): self.fixture.update()
        self.assertFalse(any('fetch' in args for args in self.fixture.calls))
        self.install()
        self.assertFalse(self.fixture.mutations())


if __name__ == '__main__': unittest.main()
