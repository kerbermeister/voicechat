from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import deploy
import legacy_core
import role_release
from test_node_inventory import fixture
import topology


class LegacyCorePreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / 'legacy'
        (self.root / 'runtime').mkdir(parents=True, mode=0o700)
        self.root.chmod(0o700)
        (self.root / 'runtime/stand.env').write_text('synthetic-do-not-print-secret\n')
        (self.root / 'runtime/stand.env').chmod(0o600)
        (self.root / 'deploy.lock').touch(mode=0o644)
        self.release = self.root / 'releases' / ('a' * 40)
        (self.release / 'infra').mkdir(parents=True)
        (self.release / 'prototype').mkdir()
        (self.release / 'infra/compose.yaml').write_text('name: voicechat\n')
        (self.release / 'infra/configure.py').write_text('# public fixture\n')
        (self.release / 'prototype/client-policy.json').write_text('{}\n')
        (self.release / 'infra/runtime').symlink_to(self.root / 'runtime')
        self.images = {name: ('ghcr.io/fixture/' + name if name in ('control', 'web') else 'fixture/' + name) +
                       '@sha256:' + str(index) * 64 for index, name in enumerate(legacy_core.SERVICES, 1)}
        self.manifest = {'schema': 1, 'commit': 'a' * 40, 'origin': 'https://chat.example.com',
                         'control': self.images['control'], 'web': self.images['web']}
        (self.release / 'release.json').write_text(json.dumps(self.manifest))
        (self.release / 'backend.sha256').write_text('f' * 64)
        self.model = {'name': 'voicechat', 'services': {},
            'volumes': {name: {'name': 'voicechat_' + name} for name in legacy_core.VOLUMES},
            'networks': {'default': {'name': 'voicechat_default'}, 'neighbor': {'name': 'deploy_default'}}}
        volumes = {
            'configure': [('synapse', '/matrix', False), ('media-config', '/media', False)],
            'postgres': [('postgres', '/var/lib/postgresql/data', False)],
            'synapse': [('synapse', '/data', False)],
            'control': [('control', '/work/.prototype', False), ('media-config', '/config', True)],
            'turn': [('turn-config', '/config', True)],
            'web': [('certificates', '/data', False), ('caddy-config', '/config', False)]}
        self.containers = {}
        for name in legacy_core.SERVICES:
            service = {'image': self.images[name], 'restart': 'no' if name == 'configure' else 'unless-stopped',
                'networks': {'default': {}}, 'volumes': [
                    {'type': 'volume', 'source': source, 'target': target, 'read_only': readonly}
                    for source, target, readonly in volumes[name]]}
            if name == 'configure':
                service['environment'] = {'PUBLIC_URL': self.manifest['origin'],
                    'MATRIX_SERVER_NAME': 'chat.example.com', 'TURN_SECRET': 'synthetic-do-not-print-secret'}
                service['volumes'].append({'type': 'bind', 'source': str(self.release / 'infra/configure.py'),
                                          'target': '/configure.py', 'read_only': True})
            if name in ('postgres', 'synapse', 'control', 'web'): service['healthcheck'] = {'test': ['CMD', 'fixture']}
            if name == 'synapse': service['ports'] = [{'target': 8008, 'published': '8088', 'host_ip': '127.0.0.1'}]
            if name == 'control':
                service.update(read_only=True, cap_drop=['ALL'], security_opt=['no-new-privileges:true'], tmpfs=['/tmp'])
                service['ports'] = [{'target': 7981, 'published': '7981', 'host_ip': '0.0.0.0'}]
            if name == 'web': service['networks']['neighbor'] = {}
            self.model['services'][name] = service
            mounts = []
            for item in service['volumes']:
                mount = {'Type': item['type'], 'Destination': item['target'], 'RW': not item['read_only']}
                mount['Name' if item['type'] == 'volume' else 'Source'] = ('voicechat_' + item['source'] if item['type'] == 'volume' else item['source'])
                mounts.append(mount)
            ports = {str(item['target']) + '/tcp': [{'HostPort': item['published'], 'HostIp': item['host_ip']}]
                     for item in service.get('ports', [])}
            identifier = hashlib.sha256(name.encode()).hexdigest()
            self.containers[name] = {'id': identifier, 'image': self.images[name],
                'image_id': 'sha256:' + hashlib.sha256(self.images[name].encode()).hexdigest(),
                'labels': {'com.docker.compose.project': 'voicechat', 'com.docker.compose.service': name},
                'readonly': service.get('read_only', False),
                'restart': {'Name': service['restart'], 'MaximumRetryCount': 0}, 'cap_add': None,
                'cap_drop': service.get('cap_drop'), 'security_opt': service.get('security_opt'),
                'tmpfs': {'/tmp': ''} if name == 'control' else None, 'mounts': mounts, 'ports': ports,
                'networks': {self.model['networks'][key]['name']: {} for key in service['networks']},
                'state': {'Status': 'exited' if name == 'configure' else 'running', 'Running': name != 'configure',
                          'ExitCode': 0, 'Health': {'Status': 'healthy'}}}
        self.record = deploy.release_record(self.release, self.manifest, self.model)
        (self.root / 'current.json').write_text(json.dumps(self.record))
        self.calls = []
        self.probe_server_name = 'chat.example.com'
        self.image_volumes = {}

    def execute(self, args, *, env=None):
        self.calls.append(args)
        if args[:2] == ['docker', 'compose']:
            self.assertEqual(env['COMPOSE_PROJECT_NAME'], 'voicechat')
            return json.dumps(self.model).encode()
        if args[:2] == ['docker', 'ps']:
            return '\n'.join(value['id'] for value in self.containers.values()).encode()
        if args[:2] == ['docker', 'inspect']:
            return json.dumps(next(value for value in self.containers.values() if value['id'] == args[-1])).encode()
        if args[:3] == ['docker', 'image', 'inspect']:
            return json.dumps({'id': 'sha256:' + hashlib.sha256(args[-1].encode()).hexdigest(),
                'volumes': self.image_volumes.get(args[-1])}).encode()
        if args[:3] == ['docker', 'volume', 'inspect']:
            return json.dumps({'name': args[-1], 'driver': 'local',
                'labels': {'com.docker.volume.anonymous': ''}, 'options': None}).encode()
        if args[:3] == ['docker', 'volume', 'ls']:
            return args[-1].removeprefix('name=^').removesuffix('$').encode()
        if args[:2] == ['docker', 'run']:
            self.assertIn('--read-only', args)
            self.assertEqual(args[args.index('--network') + 1], 'none')
            if 'pg_controldata' in args: return b'Database system identifier: 123456789\n'
            return json.dumps({'server_name': self.probe_server_name, 'sha256': 'f' * 64}).encode()
        raise AssertionError(args)

    def inspect(self, **kwargs): return legacy_core.inspect(self.root, execute=self.execute, **kwargs)

    def test_readonly_baseline_has_data_identity_without_runtime_credentials(self):
        before = {str(path): path.read_bytes() for path in self.release.rglob('*') if path.is_file()}
        result = self.inspect()
        self.assertEqual(result['data_identity']['postgres_system_identifier'], '123456789')
        self.assertEqual(result['matrix_server_name'], 'chat.example.com')
        self.assertNotIn('synthetic-do-not-print-secret', json.dumps(result))
        self.assertEqual(before, {str(path): path.read_bytes() for path in self.release.rglob('*') if path.is_file()})
        self.assertFalse(any('stop' in args or 'up' in args or 'down' in args for args in self.calls))

    def test_existing_legacy_lock_fences_preflight_before_any_docker_operation(self):
        with legacy_core.locked(self.root):
            with self.assertRaises(BlockingIOError): self.inspect()
        self.assertEqual(self.calls, [])

    def test_modified_baseline_and_unknown_mount_or_public_api_port_are_refused(self):
        self.containers['synapse']['ports']['8008/tcp'][0]['HostIp'] = '0.0.0.0'
        with self.assertRaisesRegex(ValueError, 'port bindings'): self.inspect()
        self.assertFalse(any(args[:2] == ['docker', 'run'] for args in self.calls))
        self.containers['synapse']['ports']['8008/tcp'][0]['HostIp'] = '127.0.0.1'
        self.containers['control']['mounts'].append({'Type': 'bind', 'Destination': '/unknown', 'Source': '/foreign', 'RW': True})
        with self.assertRaisesRegex(ValueError, 'Unknown legacy mount'): self.inspect()
        (self.root / 'current.json').write_text(json.dumps({**self.record, 'backend_config': '0' * 64}))
        with self.assertRaisesRegex(ValueError, 'recorded backend baseline'): self.inspect()

    def test_unknown_image_network_and_signing_identity_cannot_be_adopted(self):
        original = deepcopy(self.containers)
        self.containers['control']['image'] = 'mutable:tag'
        with self.assertRaisesRegex(ValueError, 'image, project'): self.inspect()
        self.containers = deepcopy(original)
        self.containers['web']['networks']['foreign'] = {}
        with self.assertRaisesRegex(ValueError, 'network attachment'): self.inspect()
        self.containers = original
        self.probe_server_name = 'foreign.example.com'
        with self.assertRaisesRegex(ValueError, 'another server'): self.inspect()

    def test_resume_preflight_accepts_stopped_writers_but_never_a_stopped_database(self):
        for name in ('synapse', 'control', 'turn', 'web'):
            self.containers[name]['state'].update(Running=False, Status='exited')
            self.containers[name]['networks'] = {}
        with self.assertRaisesRegex(ValueError, 'running and healthy'): self.inspect()
        self.inspect(require_running=False)
        self.containers['postgres']['state'].update(Running=False, Status='exited')
        with self.assertRaisesRegex(ValueError, 'running and healthy'): self.inspect(require_running=False)

    def test_pinned_coturn_implicit_volume_is_verified_and_reattached_without_baseline_edits(self):
        name = 'd' * 64
        self.image_volumes[self.images['turn']] = {'/var/lib/coturn': {}}
        self.containers['turn']['mounts'].append({'Type': 'volume', 'Destination': '/var/lib/coturn',
                                                 'Name': name, 'RW': True})
        before = (self.root / 'current.json').read_bytes()
        baseline = self.inspect()
        override = legacy_core.rollback_override(baseline)
        self.assertEqual(override['volumes']['legacy-turn-runtime'], {'name': name, 'external': True})
        self.assertEqual((self.root / 'current.json').read_bytes(), before)
        self.containers['turn']['mounts'][-1]['Name'] = 'unclaimed-named-volume'
        with self.assertRaisesRegex(ValueError, 'owned anonymous volume'): self.inspect()

    def test_adoption_preserves_public_identity_and_database_engine_versions(self):
        public = topology.load(ROOT / 'infra/three-vps.example.json')
        target = role_release.make(public, fixture(), 'core', 'b' * 40,
                                   'ghcr.io/example/control@sha256:' + 'a' * 64)
        baseline = self.inspect()
        target['identity'] = {'canonical_origin': self.manifest['origin'],
                              'matrix_server_name': baseline['matrix_server_name']}
        for name in ('postgres', 'synapse'): target['images'][name] = self.images[name]
        legacy_core.require_compatible(baseline, target)
        for field, value in (('canonical_origin', 'https://other.example.com'),
                             ('matrix_server_name', 'other.example.com')):
            changed = deepcopy(target); changed['identity'][field] = value
            with self.assertRaisesRegex(ValueError, 'Matrix/public identity'):
                legacy_core.require_compatible(baseline, changed)
        for name in ('postgres', 'synapse'):
            changed = deepcopy(target); changed['images'][name] = 'fixture/' + name + '@sha256:' + '0' * 64
            with self.assertRaisesRegex(ValueError, 'Engine upgrades'):
                legacy_core.require_compatible(baseline, changed)

    def test_restart_fence_resumes_partial_docker_update_without_changing_processes_or_baseline(self):
        baseline = self.inspect()
        calls = []
        lost = True
        def execute(args, **kwargs):
            nonlocal lost
            if args[:2] == ['docker', 'update']:
                calls.append(args)
                for identifier in args[3:]:
                    current = next(item for item in self.containers.values() if item['id'] == identifier)
                    current['restart']['Name'] = 'no'
                    if lost:
                        lost = False
                        raise SystemExit('Lost partial restart policy reply')
                return b''
            return self.execute(args, **kwargs)
        with self.assertRaises(SystemExit): legacy_core.fence_restart(self.root, baseline, execute=execute)
        with self.assertRaisesRegex(ValueError, 'restart contract'): self.inspect()
        self.assertEqual(legacy_core.fence_restart(self.root, baseline, execute=execute), baseline)
        self.assertEqual(self.inspect(restart_policy='fenced'), baseline)
        self.assertTrue(all(item['restart']['Name'] == 'no' for item in self.containers.values()))
        self.assertTrue(all(item['state']['Running'] for key,item in self.containers.items() if key != 'configure'))
        self.assertEqual(len(calls), 2)
        self.assertEqual(json.loads((self.root / 'current.json').read_text()), self.record)

    def test_fenced_resume_can_inspect_stopped_database_but_never_adopts_changed_data_or_policy(self):
        baseline = self.inspect()
        for item in self.containers.values():
            item['restart']['Name'] = 'no'
            item['state'].update(Running=False, Status='exited')
            item['networks'] = {}
        self.assertEqual(self.inspect(require_running=False, restart_policy='fenced'), baseline)
        self.containers['postgres']['restart']['Name'] = 'always'
        with self.assertRaisesRegex(ValueError, 'restart contract'):
            self.inspect(require_running=False, restart_policy='fencing')
        self.containers['postgres']['restart']['Name'] = 'no'
        changed = {**baseline, 'source_sha256': '0' * 64}
        with self.assertRaisesRegex(ValueError, 'baseline changed'):
            legacy_core.fence_restart(self.root, changed, execute=self.execute)
        self.assertFalse(any(args[:2] == ['docker','update'] for args in self.calls))

    def test_port_ranges_support_docker_expansion_and_preserve_private_bindings(self):
        service = {'ports': [{'target': '50300-50302', 'published': '50300-50302', 'host_ip': '0.0.0.0', 'protocol': 'udp'}]}
        actual = {str(port) + '/udp': [{'HostPort': str(port), 'HostIp': '0.0.0.0'}] for port in range(50300, 50303)}
        legacy_core._ports(service, actual)
        actual['50300/udp'][0]['HostIp'] = '::'
        with self.assertRaisesRegex(ValueError, 'port bindings'): legacy_core._ports(service, actual)


if __name__ == '__main__': unittest.main()
