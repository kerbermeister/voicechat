from copy import deepcopy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import cohost_tls
import managed_state
import test_shared_config
import test_tls_material


class CohostTLSCaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix='voicechat-cohost-source-')
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name).resolve()
        key = cls.root / 'ca.key'; key.touch(mode=0o600)
        test_tls_material.command('req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
            '-nodes', '-keyout', key, '-out', cls.root / 'ca.crt', '-days', '30', '-subj', '/CN=Disposable Source CA',
            '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
        for stem, names, options in (('intermediate', [], {'ca': True, 'days': 20}),
                ('web', ['chat.example.com'], {}), ('turn', ['turn-a.example.com'], {}),
                ('renewed', ['chat.example.com'], {}), ('short', ['chat.example.com'], {'days': 2})):
            test_tls_material.TLSMaterialTests.certificate.__func__(cls, stem, names, **options)
        cls.material = cls.root
        del cls.root

    def setUp(self):
        self.controller = test_shared_config.CohostCertificatePreparationTests()
        self.controller.setUp()
        self.addCleanup(self.controller.doCleanups)
        self.controller.configure()
        self.fixture = self.controller.fixture
        self.root, self.system = self.controller.root, self.controller.system
        self.data = self.fixture.directory / 'caddy-data'
        self.source = self.data / 'caddy/certificates' / cohost_tls.ISSUER
        self.calls = []
        self.volume = {'name': 'deploy_caddy_data', 'mountpoint': str(self.data), 'driver': 'local', 'options_empty': True}
        self.current = {'id': self.fixture.identifier, 'image_id': self.fixture.image, 'running': True,
            'labels': {'com.docker.compose.project': 'deploy', 'com.docker.compose.service': 'caddy'},
            'ports': deepcopy(self.fixture.ports), 'mounts': [
                {'Destination': '/data', 'Type': 'volume', 'RW': True, 'Name': 'deploy_caddy_data', 'Source': str(self.data)},
                {'Destination': '/config', 'Type': 'volume', 'RW': True, 'Name': 'deploy_caddy_config', 'Source': str(self.fixture.directory / 'caddy-config')},
                {'Destination': '/etc/caddy', 'Type': 'bind', 'RW': False, 'Source': str(self.root / 'runtime/caddy')}]}
        self.write_source('web', 'chat.example.com')
        self.write_source('turn', 'turn-a.example.com')

    def write_source(self, stem, hostname):
        directory = self.source / hostname
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        (directory / (hostname + '.crt')).write_bytes((self.material / (stem + '.chain')).read_bytes())
        key = directory / (hostname + '.key')
        key.write_bytes((self.material / (stem + '.key')).read_bytes()); key.chmod(0o600)

    def execute(self, args, *, env=None):
        self.calls.append(args)
        self.assertNotIn('.Config.Env', ' '.join(args))
        if args[:2] == ['docker', 'ps']: return self.fixture.identifier.encode()
        if args[:2] == ['docker', 'inspect']: return json.dumps(self.current).encode()
        if args[:3] == ['docker', 'volume', 'inspect']: return json.dumps(self.volume).encode()
        raise AssertionError('Capture must not mutate Docker, reload a service or run another container')

    def capture(self, **kwargs):
        return cohost_tls.capture(self.root, execute=self.execute, system_root=self.system,
            ca_file=self.material / 'ca.crt', **kwargs)

    def test_trusted_pairs_are_cached_privately_without_mutating_services_or_sources(self):
        with patch.object(cohost_tls.tls_activation, 'verify_live') as verify:
            result = self.capture()
            web = self.root / 'certificates' / result['generations']['web'] / 'web.key'
            before = web.stat().st_mtime_ns
            self.assertEqual(self.capture(), result)
            self.assertEqual(web.stat().st_mtime_ns, before)
            self.assertEqual(web.stat().st_mode & 0o777, 0o600)
            self.assertEqual(web.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(verify.call_count, 4)
            self.assertEqual(verify.call_args.args[:3], ('127.0.0.1', 443, ['turn-a.example.com']))
            self.assertEqual(verify.call_args.kwargs['ca_file'], self.material / 'ca.crt')
        self.assertNotIn('PRIVATE KEY', json.dumps(result))
        self.assertEqual((self.root / 'runtime/caddy/Caddyfile').read_bytes(), (self.controller.plan / 'Caddyfile').read_bytes())
        self.assertFalse((self.root / 'certificates/web').exists())

    def test_renewal_keeps_old_material_and_updates_only_the_completed_cache_set(self):
        with patch.object(cohost_tls.tls_activation, 'verify_live'):
            old = self.capture()
            self.write_source('renewed', 'chat.example.com')
            new = self.capture()
        self.assertNotEqual(old['generations']['web'], new['generations']['web'])
        self.assertEqual(old['generations']['turn'], new['generations']['turn'])
        self.assertTrue((self.root / 'certificates' / old['generations']['web'] / 'web.key').exists())
        self.assertEqual(managed_state.read(self.root / 'certificates.json'), new)

    def test_racing_or_invalid_pair_never_replaces_a_complete_cache_receipt(self):
        with patch.object(cohost_tls.tls_activation, 'verify_live'):
            original = self.capture()
            directory = self.source / 'chat.example.com'
            (directory / 'chat.example.com.key').write_bytes((self.material / 'turn.key').read_bytes())
            with self.assertRaisesRegex(RuntimeError, 'trusted current pair'): self.capture()
            self.assertEqual(managed_state.read(self.root / 'certificates.json'), original)
            self.write_source('short', 'chat.example.com')
            with self.assertRaises(RuntimeError): self.capture()
            self.assertEqual(managed_state.read(self.root / 'certificates.json'), original)

    def test_wrong_volume_or_foreign_configuration_is_rejected_before_key_capture(self):
        self.current['mounts'][0]['Name'] = 'foreign_data'
        with self.assertRaisesRegex(ValueError, 'data volume changed'): self.capture()
        self.current['mounts'][0]['Name'] = 'deploy_caddy_data'
        self.volume['options_empty'] = False
        with self.assertRaisesRegex(ValueError, 'Local owned'): self.capture()
        self.volume['options_empty'] = True
        (self.root / 'runtime/caddy/Caddyfile').write_text('foreign routes')
        with self.assertRaisesRegex(ValueError, 'Serving Caddy configuration'): self.capture()
        self.assertFalse((self.root / 'certificates.json').exists())

    def test_source_key_permissions_and_symlinks_are_not_adopted(self):
        key = self.source / 'chat.example.com/chat.example.com.key'
        key.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'owner-only'): self.capture()
        key.unlink(); key.symlink_to(self.material / 'web.key')
        with self.assertRaisesRegex(ValueError, 'owned or regular'): self.capture()
        self.assertFalse((self.root / 'certificates.json').exists())

    def test_failed_live_leaf_confirmation_can_retry_without_claiming_success(self):
        with patch.object(cohost_tls.tls_activation, 'verify_live', side_effect=TimeoutError('old leaf')):
            with self.assertRaises(RuntimeError): self.capture()
        self.assertFalse((self.root / 'certificates.json').exists())
        with patch.object(cohost_tls.tls_activation, 'verify_live'):
            self.capture()
        self.assertTrue((self.root / 'certificates.json').exists())

    def test_pending_maintenance_and_changed_host_stop_before_docker_inspection(self):
        managed_state.persist(self.root / 'configuration.json', {'schema': 1})
        with self.assertRaisesRegex(ValueError, 'maintenance'): self.capture()
        self.assertEqual(self.calls, [])
        (self.root / 'configuration.json').unlink()
        host = self.system / 'etc/ssh/ssh_host_ed25519_key.pub'
        host.write_text(self.fixture.inventory['core']['ssh_host_key'].replace('AAAAC3', 'AAAAD3'))
        with self.assertRaises(ValueError): self.capture()
        self.assertEqual(self.calls, [])


if __name__ == '__main__': unittest.main()
