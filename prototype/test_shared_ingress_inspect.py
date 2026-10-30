from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import shared_ingress
import topology
from test_node_inventory import fixture, key


class LegacyIngressInspectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.root, self.system, self.repo = (self.directory / name for name in ('shared', 'host', 'repo'))
        self.system.mkdir()
        deploy = self.repo / 'deploy'; deploy.mkdir(parents=True)
        self.environment = deploy / '.env'
        self.secret = 'synthetic-private-value-not-for-logs'
        self.original = ('JWT_SECRET=' + self.secret + '\n').encode()
        self.environment.write_bytes(self.original); self.environment.chmod(0o600)
        self.public = topology.load(ROOT / 'infra/single-vps.example.json')
        self.inventory = fixture(); self.inventory['edges'] = [{'id': 'a', 'host': 'core'}]
        host = self.system / 'etc/ssh/ssh_host_ed25519_key.pub'
        host.parent.mkdir(parents=True); host.write_text(self.inventory['core']['ssh_host_key'] + ' fixture\n')
        self.business = '{$DOMAIN} {\n reverse_proxy frontend:80\n}\n'
        self.legacy = shared_ingress.legacy_config(self.business, self.public).encode()
        (deploy / 'Caddyfile').write_bytes(self.legacy)
        self.plan = shared_ingress.stage(self.root, self.repo, self.directory / 'edge', self.public,
            self.inventory, 'a', self.business, system_root=self.system)
        self.identifier, self.neighbor = 'a' * 64, 'c' * 64
        self.image = 'sha256:' + 'b' * 64
        self.active = {'apps': {'http': {'servers': {'fixture': {'routes': ['reviewed']}}}}}
        self.ports = {'80/tcp': [{'HostIp': '', 'HostPort': '80'}], '443/tcp': [{'HostIp': '', 'HostPort': '443'}]}
        self.current = {'id': self.identifier, 'image_id': self.image, 'running': True,
            'started': '2026-10-29T00:00:00Z', 'restarts': 0, 'ports': self.ports,
            'restart': {'Name': 'unless-stopped', 'MaximumRetryCount': 0},
            'networks': {'deploy_default': {}}, 'mounts': [
                {'Type': 'bind', 'Source': str(deploy / 'Caddyfile'), 'Destination': '/etc/caddy/Caddyfile', 'RW': False},
                {'Type': 'volume', 'Name': 'deploy_caddy_data', 'Destination': '/data', 'RW': True},
                {'Type': 'volume', 'Name': 'deploy_caddy_config', 'Destination': '/config', 'RW': True}]}
        self.config = {'name': 'deploy', 'services': {'caddy': {'image': 'caddy:2.8',
            'environment': {'DOMAIN': 'neighbor.fixture.invalid'}, 'restart': 'unless-stopped',
            'networks': {'default': None}, 'ports': [
                {'target': 80, 'published': '80', 'protocol': 'tcp'},
                {'target': 443, 'published': '443', 'protocol': 'tcp'}], 'volumes': [
                {'type': 'bind', 'source': str(deploy / 'Caddyfile'), 'target': '/etc/caddy/Caddyfile', 'read_only': True},
                {'type': 'volume', 'source': 'caddy_data', 'target': '/data'},
                {'type': 'volume', 'source': 'caddy_config', 'target': '/config'}]},
            'frontend': {'image': 'fixture/frontend', 'environment': {'PRIVATE_VALUE': self.secret}}},
            'volumes': {'caddy_data': {'name': 'deploy_caddy_data'}, 'caddy_config': {'name': 'deploy_caddy_config'}},
            'networks': {'default': {'name': 'deploy_default'}}}
        (deploy / 'docker-compose.yml').write_text(json.dumps(self.config))
        self.calls = []
        self.changed = b'deploy/Caddyfile\n'
        self.existing_override = ''
        self.live = deepcopy(self.active)

    def execute(self, args, *, env=None):
        self.calls.append(args)
        if args[0] == 'git':
            if '--show-toplevel' in args: return str(self.repo).encode() + b'\n'
            if 'branch' in args: return b'main\n'
            if args[-1] == 'HEAD': return b'd' * 40 + b'\n'
            if '--name-only' in args: return self.changed
            if '--cached' in args: return b''
            if 'show' in args: return self.business.encode()
        self.assertEqual(args[0], 'docker')
        if args[1] == 'compose':
            snapshot = Path(args[args.index('--env-file') + 1])
            self.assertEqual(snapshot.read_bytes(), self.original)
            self.assertEqual(snapshot.stat().st_mode & 0o777, 0o600)
            self.assertEqual(env['PWD'], str(self.repo / 'deploy'))
            if args[args.index('-f') + 1].endswith('env-probe.json'):
                return json.dumps({'services': {'inspect': {'environment': {
                    'VC_COMPOSE_FILE': self.existing_override, 'VC_SEPARATOR': ''}}}}).encode()
            return json.dumps(self.config).encode()
        if args[1] == 'ps':
            if any('service=caddy' in item for item in args): return self.identifier.encode()
            return (self.identifier + '\n' + self.neighbor).encode() if args[-1].endswith('=deploy') else b''
        if args[1:3] == ['image', 'inspect']: return self.image.encode()
        if args[1] == 'inspect':
            self.assertNotIn('.Config.Env', args[args.index('--format') + 1])
            if 'State.StartedAt}} {{.RestartCount' in args[args.index('--format') + 1]:
                return (self.neighbor + ' preserved-start 0\n').encode()
            return json.dumps(self.current).encode()
        if args[1] == 'run':
            self.assertIn('--network', args); self.assertEqual(args[args.index('--network') + 1], 'none')
            mount = args[args.index('--volume') + 1]
            content = Path(mount.split(':/etc/caddy/', 1)[0]).read_bytes()
            return json.dumps(self.active if content == self.legacy else {'unreviewed': True}).encode()
        if args[1] == 'exec': return json.dumps(self.live).encode()
        raise AssertionError('Unexpected mutation/command in read-only inspection')

    def inspect(self):
        return shared_ingress.inspect_legacy_plan(self.root, self.plan, execute=self.execute, system_root=self.system)

    def test_preflight_preserves_environment_git_and_services_without_disclosing_secrets(self):
        baseline = self.inspect()
        self.assertEqual(baseline['environment_sha256'], hashlib.sha256(self.original).hexdigest())
        self.assertEqual(baseline['caddy_id'], self.identifier)
        self.assertEqual(baseline['neighbors'], [self.neighbor + ' preserved-start 0'])
        self.assertNotIn(self.secret, json.dumps(baseline))
        self.assertNotIn(self.secret, json.dumps(self.calls))
        self.assertEqual(self.environment.read_bytes(), self.original)
        self.assertEqual((self.repo / 'deploy/Caddyfile').read_bytes(), self.legacy)
        self.assertFalse((self.root / 'runtime').exists())
        self.assertFalse(any(word in ('up', 'reload', 'restart', 'checkout', 'restore') for args in self.calls for word in args))

    def test_wrong_host_and_tampered_plan_stop_before_git_or_environment_inspection(self):
        host = self.system / 'etc/ssh/ssh_host_ed25519_key.pub'
        host.write_text(key(9))
        with self.assertRaisesRegex(ValueError, 'another SSH host'): self.inspect()
        self.assertEqual(self.calls, [])
        host.write_text(self.inventory['core']['ssh_host_key'])
        (self.plan / 'Caddyfile').write_text('tampered')
        with self.assertRaisesRegex(ValueError, 'plan file changed'): self.inspect()
        self.assertEqual(self.calls, [])

    def test_unrelated_git_changes_and_foreign_compose_override_are_not_adopted(self):
        self.changed += b'deploy/docker-compose.yml\n'
        with self.assertRaisesRegex(ValueError, 'Unrelated tracked'): self.inspect()
        self.assertFalse(any(args[0] == 'docker' for args in self.calls))
        self.changed = b'deploy/Caddyfile\n'; self.existing_override = '/foreign/compose.yaml'
        with self.assertRaisesRegex(ValueError, 'Compose file ownership'): self.inspect()

    def test_unknown_routes_mounts_and_binary_are_not_silently_overwritten(self):
        self.live = {'unreviewed': True}
        with self.assertRaisesRegex(ValueError, 'Active or on-disk'): self.inspect()
        self.live = deepcopy(self.active)
        self.current['mounts'].append({'Destination': '/unrelated-volume'})
        with self.assertRaisesRegex(ValueError, 'Unknown Caddy mounts'): self.inspect()
        self.current['mounts'].pop(); self.current['image_id'] = 'sha256:' + 'e' * 64
        with self.assertRaisesRegex(ValueError, 'pinned binary'): self.inspect()

    def test_environment_symlink_and_writable_source_fail_closed(self):
        self.environment.chmod(0o666)
        with self.assertRaisesRegex(ValueError, 'owned regular file'): self.inspect()
        self.environment.unlink(); self.environment.symlink_to(self.repo / 'deploy/Caddyfile')
        with self.assertRaises(OSError): self.inspect()


if __name__ == '__main__': unittest.main()
