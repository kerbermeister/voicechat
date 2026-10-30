from copy import deepcopy
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import acme
from test_node_inventory import fixture
from topology import load


def inputs():
    public = load(ROOT / 'infra/three-vps.example.json')
    public.update(canonical_origin='https://univc.duckdns.org', matrix_server_name='univc.duckdns.org',
                  web_origins=['https://univc.duckdns.org', 'https://vc-b.duckdns.org', 'https://vc-c.duckdns.org'])
    for edge in public['edges']:
        name = 'vc-' + edge['id'] + '.duckdns.org'
        edge.update(origin='https://' + name, turn_host='turn.' + name)
    config = {'schema': 1, 'provider': 'duckdns', 'environment': 'staging',
              'email': 'fixture@example.invalid',
              'domains': ['univc.duckdns.org', 'vc-b.duckdns.org', 'vc-c.duckdns.org']}
    return public, fixture(), config


class ACMETests(unittest.TestCase):
    def setUp(self):
        self.public, self.inventory, self.config = inputs()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.token = self.root / 'token'
        self.token.touch(mode=0o600)
        self.token.write_text('11111111-2222-3333-4444-555555555555')
        self.store = self.root / 'acme'
        self.calls = []

    def docker(self, command, **kwargs):
        self.calls.append(command)
        self.assertTrue(kwargs['capture_output'])
        if command[1] == 'create':
            self.assertNotIn(self.token.read_text(), ' '.join(command))
            bind = next(arg for arg in command if 'target=/run/secrets/duckdns' in arg)
            token_path = Path(bind.split('source=')[1].split(',')[0])
            self.assertEqual(token_path.read_text(), self.token.read_text())
            self.assertEqual(token_path.stat().st_mode & 0o777, 0o600)
        return subprocess.CompletedProcess(command, 0, b'container', b'')

    def execute(self, **kwargs):
        return acme.execute(self.store, self.public, self.inventory, self.config,
                            'b', 'web', self.token, accept_tos=True, run=self.docker, **kwargs)

    def test_plan_is_scoped_and_replacement_gets_new_certificate_identity(self):
        job = acme.plan(self.public, self.inventory, self.config, 'b', 'web')
        self.assertEqual(job['names'], ['univc.duckdns.org', 'vc-b.duckdns.org'])
        self.assertIn('--force-cert-domains', acme.arguments(job))
        self.assertNotIn('--reuse-key', acme.arguments(job))
        self.assertNotIn('--tls-skip-verify', acme.arguments(job))
        self.inventory['edges'][0]['generation'] += 1
        changed = acme.plan(self.public, self.inventory, self.config, 'b', 'web')
        self.assertNotEqual(job['certificate_id'], changed['certificate_id'])
        for change in (lambda c: c.update(environment='unknown'), lambda c: c.update(provider='cloudflare'),
                       lambda c: c.update(domains=['duckdns.org']), lambda c: c.update(domains=['vc-b.duckdns.org']),
                       lambda c: c.update(email='x\n--evil'), lambda c: c.update(schema=True)):
            config = deepcopy(self.config); change(config)
            with self.assertRaises(ValueError): acme.plan(self.public, self.inventory, config, 'b', 'web')

    def test_serialized_execution_stages_only_after_cleanup_and_cleans_token(self):
        def staged(*args, **kwargs):
            self.assertFalse((self.store / 'inflight.json').exists())
            self.assertEqual(self.calls[-1][1:3], ['rm', '--force'])
            self.assertEqual(args[4].name, 'edge-b-g1-web.crt')
            self.assertEqual(args[5].name, 'edge-b-g1-web.key')
            return self.root / 'verified'
        original = self.docker
        def locked_docker(command, **kwargs):
            with self.assertRaises(BlockingIOError):
                acme.execute(self.store, self.public, self.inventory, self.config, 'c', 'turn', self.token,
                             accept_tos=True, run=original)
            return original(command, **kwargs)
        self.docker = locked_docker
        with patch.object(acme.tls_material, 'stage', side_effect=staged):
            self.assertEqual(self.execute(), self.root / 'verified')
            self.execute()
        self.assertFalse(list(self.store.glob('.credential-*')))
        self.assertEqual([c[1] for c in self.calls], ['create', 'start', 'rm'] * 2)
        self.config['environment'] = 'production'
        with self.assertRaisesRegex(ValueError, 'account/environment'): self.execute()
        self.assertEqual(len(self.calls), 6)

    def test_failed_or_timed_out_ca_keeps_previous_and_redacts_errors(self):
        original = self.docker
        for timeout in (False, True):
            def failing(command, **kwargs):
                if command[1] == 'start':
                    if timeout: raise subprocess.TimeoutExpired(command, 1, stderr=self.token.read_bytes())
                    return subprocess.CompletedProcess(command, 1, b'', self.token.read_bytes())
                return original(command, **kwargs)
            self.docker = failing
            with patch.object(acme.tls_material, 'stage') as stage:
                with self.assertRaises(ValueError) as error: self.execute()
                self.assertNotIn(self.token.read_text(), str(error.exception))
                stage.assert_not_called()
            self.assertFalse((self.store / 'inflight.json').exists())
            self.assertEqual(self.calls[-1][1:3], ['rm', '--force'])

    def test_uncertain_cleanup_blocks_every_edge_until_reconciled(self):
        original = self.docker
        def failed_cleanup(command, **kwargs):
            if command[1] == 'rm': return subprocess.CompletedProcess(command, 1, b'', b'failure')
            return original(command, **kwargs)
        self.docker = failed_cleanup
        with self.assertRaisesRegex(ValueError, 'cleanup failed'): self.execute()
        self.assertTrue((self.store / 'inflight.json').exists())
        count = len(self.calls)
        with self.assertRaisesRegex(ValueError, 'Interrupted'):
            acme.execute(self.store, self.public, self.inventory, self.config, 'c', 'turn', self.token,
                         accept_tos=True, run=self.docker)
        self.assertEqual(len(self.calls), count)

    def test_uncertain_create_preserves_intent_without_removing_unknown_container(self):
        def uncertain(command, **kwargs):
            self.calls.append(command)
            raise subprocess.TimeoutExpired(command, 1)
        self.docker = uncertain
        with self.assertRaisesRegex(ValueError, 'creation uncertain'): self.execute()
        self.assertTrue((self.store / 'inflight.json').exists())
        self.assertEqual([c[1] for c in self.calls], ['create'])
        with self.assertRaisesRegex(ValueError, 'Interrupted'): self.execute()

    def test_reject_tos_trust_override_unclaimed_state_and_identity_changes(self):
        with self.assertRaisesRegex(ValueError, 'terms'):
            acme.execute(self.store, self.public, self.inventory, self.config, 'b', 'web', self.token)
        self.config['environment'] = 'production'
        with self.assertRaisesRegex(ValueError, 'system trust'): self.execute(ca_file=self.root / 'ca.crt')
        self.config['environment'] = 'staging'
        self.store.mkdir(mode=0o700)
        (self.store / 'foreign').touch()
        with self.assertRaisesRegex(ValueError, 'unclaimed'): self.execute()
        (self.store / 'foreign').unlink()
        with patch.object(acme.tls_material, 'stage', return_value=self.root / 'verified'): self.execute()
        self.public['edges'][0]['origin'] = 'https://new.vc-b.duckdns.org'
        with self.assertRaisesRegex(ValueError, 'identity changed'): self.execute()


if __name__ == '__main__': unittest.main()
