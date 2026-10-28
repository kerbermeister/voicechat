from pathlib import Path
import json
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import shared_ingress
import topology
from test_node_inventory import fixture


class SharedIngressTests(unittest.TestCase):
    def test_staging_is_idempotent_owned_and_never_activates_runtime_or_a_boot_unit(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            root, system = directory / 'shared', directory / 'host'
            system.mkdir()
            repo, edge = directory / 'repo', directory / 'edge'
            public = topology.load(ROOT / 'infra/single-vps.example.json')
            inventory = fixture(); inventory['edges'] = [{'id': 'a', 'host': 'core'}]
            business = '{$DOMAIN} {\n reverse_proxy frontend:80\n}\n'
            def stage(**kwargs):
                return shared_ingress.stage(root, repo, edge, public, inventory, 'a', business, system_root=system, **kwargs)
            plan = stage()
            self.assertEqual(stage(), plan)
            record = json.loads((plan / 'plan.json').read_text())
            self.assertEqual(record['target']['mode'], 'legacy')
            self.assertFalse((root / 'runtime').exists())
            self.assertFalse(repo.exists())
            self.assertFalse(edge.exists())
            self.assertFalse((system / 'etc').exists())
            self.assertTrue((system / 'opt/voicechat/operators' / record['target']['operator']['operator_sha256']).is_dir())
            with self.assertRaisesRegex(ValueError, 'profile required'): stage(mode='shared')
            inventory['edges'][0]['shared_tls'] = {'network': 'voicechat-shared-ingress',
                'subnet': '172.29.0.0/29', 'legacy_ip': '172.29.0.2', 'ingress_ip': '172.29.0.3'}
            target = stage(mode='shared')
            self.assertNotEqual(target, plan)
            self.assertTrue(plan.exists())
            (target / 'Caddyfile').write_text('tampered')
            with self.assertRaisesRegex(ValueError, 'plan changed'): stage(mode='shared')

    def test_legacy_keeps_current_voicechat_route_and_clears_stale_http3(self):
        public = topology.load(ROOT / 'infra/single-vps.example.json')
        business = '{$DOMAIN} {\n reverse_proxy frontend:80\n}\n'
        value = shared_ingress.legacy_config(business, public)
        self.assertTrue(value.startswith(business))
        self.assertIn('reverse_proxy voicechat-web:80', value)
        self.assertIn('header >Alt-Svc clear', value)
        self.assertNotIn('proxy_protocol', value)
        for invalid in ('', '\0', 'x' * 65537, public['matrix_server_name'] + ' { respond 200 }'):
            with self.assertRaises(ValueError): shared_ingress.legacy_config(invalid, public)

    def test_override_replaces_leaf_mount_without_changing_persistent_caddy_volumes(self):
        legacy = shared_ingress.compose_override('/var/lib/voicechat-shared/config')
        self.assertIn('"443:443"', legacy)
        self.assertIn('ports: !override', legacy)
        self.assertIn('volumes: !override', legacy)
        self.assertIn('target: /etc/caddy\n', legacy)
        self.assertIn('create_host_path: false', legacy)
        self.assertIn('caddy_data:/data', legacy)
        self.assertIn('caddy_config:/config', legacy)
        shared = shared_ingress.compose_override('/var/lib/voicechat-shared/config', shared={
            'network': 'voicechat-shared-ingress', 'subnet': '172.29.0.0/29',
            'legacy_ip': '172.29.0.2', 'ingress_ip': '172.29.0.3'})
        self.assertNotIn('"443:443"', shared)
        self.assertIn('"80:80"', shared)
        self.assertIn('external: true', shared)
        self.assertIn('ipv4_address: 172.29.0.2', shared)

    def test_environment_references_both_configs_without_shell_or_env_injection(self):
        self.assertEqual(shared_ingress.compose_environment('/opt/avito-helper', '/var/lib/voicechat-shared/compose.yaml'),
            'COMPOSE_FILE=/opt/avito-helper/deploy/docker-compose.yml:/var/lib/voicechat-shared/compose.yaml\n')
        for invalid in (None, 12, 'relative', '/opt/../etc', '/opt//duplicate', '/opt/path with space', '/opt/a\nOTHER=1', '/opt/$(id)'):
            with self.assertRaises(ValueError): shared_ingress.compose_override(invalid)


if __name__ == '__main__': unittest.main()
