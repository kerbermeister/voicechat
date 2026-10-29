from copy import deepcopy
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import shared_ingress
import shared_update
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
            if 'pull' in args or 'up' in args: return b''
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


if __name__ == '__main__': unittest.main()
