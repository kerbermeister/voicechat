from copy import deepcopy
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_state
import role_prepare
import role_release
import shared_front
import topology
from test_node_inventory import fixture


class SharedFrontWarmTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name).resolve()
        self.root, self.edge, self.system = (directory / name for name in ('front', 'edge', 'host'))
        public = topology.load(ROOT / 'infra/single-vps.example.json')
        inventory = fixture()
        inventory['edges'] = [{'id': 'a', 'host': 'core', 'shared_tls': {
            'network': 'voicechat-shared-ingress', 'subnet': '172.29.0.0/29',
            'legacy_ip': '172.29.0.2', 'ingress_ip': '172.29.0.3'}}]
        self.public, self.inventory = public, inventory
        host = self.system / 'etc/ssh/ssh_host_ed25519_key.pub'
        host.parent.mkdir(parents=True); host.write_text(inventory['core']['ssh_host_key'])
        self.manifest = role_release.make(public, inventory, 'edge', 'a' * 40,
            'ghcr.io/fixture/web@sha256:' + '1' * 64, 'a')
        self.release = role_prepare.prepare(self.edge, public, inventory, self.manifest)
        self.plan = shared_front.prepare(self.root, self.edge, self.manifest)
        self.record, self.model = shared_front.read_plan(self.root, self.plan, system_root=self.system)
        self.networks = {}
        self.container = None
        self.calls = []
        self.interrupt = False
        self.fail_parse = False

    def create(self):
        service = self.model['services']['ingress']
        for name, network in self.model['networks'].items():
            self.networks[network['name']] = {'name': network['name'], 'driver': 'bridge',
                'labels': {'com.docker.compose.project': shared_front.PROJECT, 'com.docker.compose.network': name},
                'ipam': [{'Subnet': network['ipam']['config'][0]['subnet']}],
                'options': network.get('driver_opts', {})}
        self.container = {'id': 'a' * 64, 'running': True, 'image': service['image'],
            'labels': {'com.docker.compose.project': shared_front.PROJECT, 'com.docker.compose.service': 'ingress'},
            'mounts': [{'Type': 'bind', 'Source': str(self.plan / 'haproxy.cfg'),
                'Destination': '/usr/local/etc/haproxy/haproxy.cfg', 'RW': False}],
            'ports': {'8443/tcp': [{'HostIp': '127.0.0.1', 'HostPort': '19443'}]},
            'networks': {self.model['networks'][name]['name']: {'IPAddress': value['ipv4_address']}
                         for name, value in service['networks'].items()}}

    def execute(self, args, *, env=None):
        self.calls.append(args)
        if args[:3] == ['docker', 'network', 'ls']:
            name = args[-1][6:-1]
            return b'fixture-network' if name in self.networks else b''
        if args[:3] == ['docker', 'network', 'inspect']:
            return json.dumps(self.networks[args[-1]]).encode()
        if args[:2] == ['docker', 'ps']: return b'a' * 64 if self.container else b''
        if args[:2] == ['docker', 'inspect']: return json.dumps(self.container).encode()
        if args[:2] == ['docker', 'pull']: return b''
        if args[:2] == ['docker', 'run']:
            self.assertIn('--network', args); self.assertIn('none', args)
            if self.fail_parse: raise RuntimeError('synthetic parse error')
            return b'Configuration file is valid'
        self.assertEqual(args[:2], ['docker', 'compose'])
        if 'pull' in args:
            self.assertIn('--policy', args); self.assertIn('missing', args)
            self.assertEqual(args[-1], 'ingress')
            return b''
        self.assertIn('--no-deps', args); self.assertIn('--no-build', args)
        self.assertEqual(args[-1], 'ingress')
        self.create()
        if self.interrupt: raise SystemExit('lost compose response')
        return b''

    def warm(self, plan=None):
        return shared_front.warm(self.root, plan or self.plan, execute=self.execute, system_root=self.system)

    def mutations(self):
        return [args for args in self.calls if args[:2] in (['docker', 'compose'], ['docker', 'pull'])]

    def test_prepare_and_warm_are_idempotent_without_public_listener_or_application_start(self):
        self.assertEqual(shared_front.prepare(self.root, self.edge, self.manifest), self.plan)
        self.assertEqual(self.model['services']['ingress']['ports'], ['127.0.0.1:19443:8443/tcp'])
        self.assertFalse((self.edge / 'state.json').exists())
        self.assertFalse((self.root / 'warm.json').exists())
        expected = {'schema': 1, 'plan': self.plan.name, 'phase': 'running'}
        self.assertEqual(self.warm(), expected)
        self.calls.clear()
        self.assertEqual(self.warm(), expected)
        self.assertFalse(self.mutations())

    def test_public_definition_is_sealed_but_never_selected_by_warm(self):
        model = json.loads((self.plan / 'compose.public.json').read_text())
        self.assertEqual(model['services']['ingress']['ports'], ['443:8443/tcp', '127.0.0.1:19443:8443/tcp'])
        model['services']['ingress']['ports'] = self.model['services']['ingress']['ports']
        self.assertEqual(model, self.model)
        self.warm()
        self.assertFalse(any(str(self.plan / 'compose.public.json') in args for args in self.calls))
        (self.plan / 'compose.public.json').write_text('{}')
        self.calls.clear()
        with self.assertRaisesRegex(ValueError, 'checksum'): self.warm()
        self.assertFalse(self.calls)

    def test_interrupted_up_resumes_the_same_plan_and_rejects_another(self):
        self.interrupt = True
        with self.assertRaises(SystemExit): self.warm()
        self.assertEqual(managed_state.read(self.root / 'warm.json')['phase'], 'applying')
        other = shared_front.prepare(self.root, self.edge, self.manifest, warm_port=19444)
        with self.assertRaisesRegex(ValueError, 'same shared front'): self.warm(other)
        self.interrupt = False
        self.assertEqual(self.warm()['phase'], 'running')

    def test_web_image_release_does_not_change_the_independent_front_plan(self):
        updated = role_release.make(self.public, self.inventory, 'edge', 'b' * 40,
            'ghcr.io/fixture/web@sha256:' + '2' * 64, 'a')
        role_prepare.prepare(self.edge, self.public, self.inventory, updated)
        self.assertEqual(shared_front.prepare(self.root, self.edge, updated), self.plan)
        with managed_state.locked(self.root):
            with self.assertRaises(BlockingIOError): self.warm()
        self.assertFalse(self.calls)

    def test_foreign_container_or_network_are_never_adopted(self):
        self.create()
        with self.assertRaisesRegex(ValueError, 'existing shared front network'): self.warm()
        self.assertFalse(self.mutations())
        self.networks.clear()
        with self.assertRaisesRegex(ValueError, 'unclaimed shared front'): self.warm()
        self.assertFalse(self.mutations())

    def test_parser_failure_does_not_claim_or_start_a_listener(self):
        self.fail_parse = True
        with self.assertRaises(RuntimeError): self.warm()
        self.assertFalse((self.root / 'warm.json').exists())
        self.assertFalse(self.container)
        self.assertFalse(any(args[:2] == ['docker', 'compose'] and 'up' in args for args in self.calls))

    def test_owned_stopped_listener_can_be_recovered_without_other_services(self):
        self.warm()
        self.container['running'] = False
        self.calls.clear()
        self.assertEqual(self.warm()['phase'], 'running')
        starts = [args for args in self.calls if args[:2] == ['docker', 'compose'] and 'up' in args]
        self.assertEqual(len(starts), 1)
        self.assertEqual(starts[0][-1], 'ingress')
        self.assertTrue(self.container['running'])

    def test_wrong_host_tampered_sources_and_extra_imports_fail_before_docker(self):
        host = self.system / 'etc/ssh/ssh_host_ed25519_key.pub'
        original = host.read_text()
        host.write_text(original.replace('AAAAC3', 'AAAAD3'))
        with self.assertRaises(ValueError): self.warm()
        host.write_text(original)
        config = self.plan / 'haproxy.cfg'; original_config = config.read_bytes()
        config.write_bytes(original_config + b'\n# foreign change\n')
        with self.assertRaisesRegex(ValueError, 'checksum'): self.warm()
        config.write_bytes(original_config)
        (self.plan / 'foreign.py').write_text('foreign')
        with self.assertRaisesRegex(ValueError, 'Unexpected'): self.warm()
        self.assertEqual(self.calls, [])

    def test_running_container_port_mount_and_network_edits_fail_closed(self):
        self.warm()
        original = deepcopy(self.container)
        self.container['ports']['8443/tcp'][0]['HostIp'] = '0.0.0.0'
        with self.assertRaises(ValueError): self.warm()
        self.container = deepcopy(original)
        self.container['mounts'][0]['RW'] = True
        with self.assertRaises(ValueError): self.warm()
        self.container = deepcopy(original)
        name = next(iter(self.networks))
        self.networks[name]['labels']['com.docker.compose.project'] = 'foreign'
        with self.assertRaisesRegex(ValueError, 'network ownership'): self.warm()


if __name__ == '__main__': unittest.main()
