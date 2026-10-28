from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
from topology import load
from edge_config import edge_proxy, shared_legacy_proxy, sni_proxy


class EdgeConfigTests(unittest.TestCase):
    def test_shared_legacy_preserves_business_and_only_maintains_voicechat_certificates(self):
        public = load(Path(__file__).resolve().parents[1] / 'infra/single-vps.example.json')
        business = '{$DOMAIN} {\n reverse_proxy frontend:80\n}\n'
        rendered = shared_legacy_proxy(business, public, 'a', '172.29.0.3')
        self.assertIn(business, rendered)
        self.assertIn('strict_sni_host on', rendered)
        self.assertIn('allow 172.29.0.3/32', rendered)
        self.assertIn('fallback_policy reject', rendered)
        self.assertIn('disable_tlsalpn_challenge', rendered)
        self.assertIn('respond 421', rendered)
        self.assertNotIn('voicechat-web', rendered)
        self.assertNotIn('auto_https off', rendered)
        for invalid in ('', '{\n admin off\n}\n' + business, public['matrix_server_name'] + ' { respond 200 }', '\0', 'x' * 65537):
            with self.assertRaises(ValueError): shared_legacy_proxy(invalid, public, 'a', '172.29.0.3')
        with self.assertRaises(ValueError): shared_legacy_proxy(business, public, 'a', '8.8.8.8')
        with self.assertRaises(ValueError): shared_legacy_proxy(business, public, 'unknown', '172.29.0.3')

    def test_origin_and_forwarded_boundaries_keep_existing_private_policy(self):
        topology = load(Path(__file__).resolve().parents[1] / 'infra/three-vps.example.json')
        config = edge_proxy(topology, 'b', '10.88.0.1', '172.30.0.2')
        self.assertIn('allow 172.30.0.2/32', config)
        self.assertNotIn('trusted_proxies static private_ranges', config)
        self.assertIn('respond @private 404', config)
        self.assertIn('/api/internal/*', config)
        self.assertIn('respond @foreign_origin 403', config)
        self.assertIn('header_up -Forwarded', config)
        self.assertIn('header_up X-Forwarded-For {remote_host}', config)
        self.assertNotIn('synapse:8008', config)
        self.assertNotIn('control:8090', config)
        self.assertIn('10.88.0.1:8088', config)
        self.assertIn('Cross-Origin-Embedder-Policy require-corp', config)
        self.assertIn('header Cache-Control "no-cache"', config)

    def test_invalid_names_and_addresses_cannot_inject_proxy_directives(self):
        for name in ('web.test\nbackend evil', 'user@web.test', '*.example.com'):
            with self.assertRaises(ValueError): sni_proxy([name], 'turn.test')
        with self.assertRaises(ValueError): sni_proxy(['same.test'], 'same.test')
        topology = load(Path(__file__).resolve().parents[1] / 'infra/three-vps.example.json')
        with self.assertRaises(ValueError): edge_proxy(topology, 'b', 'host:8080', '172.30.0.2')
        with self.assertRaises(ValueError): edge_proxy(topology, 'unknown', '10.88.0.1', '172.30.0.2')
        with self.assertRaises(ValueError): edge_proxy(topology, 'b', '192.0.2.1', '172.30.0.2')

    def test_shared_legacy_fallback_is_explicit_private_and_preserves_dedicated_rejection(self):
        dedicated = sni_proxy(['web.test'], 'turn.test')
        self.assertIn('reject if client_hello !web_name !turn_name', dedicated)
        self.assertNotIn('legacy_tls', dedicated)
        shared = sni_proxy(['web.test'], 'turn.test', legacy_ip='172.29.0.2')
        self.assertIn('default_backend legacy_tls', shared)
        self.assertIn('server legacy 172.29.0.2:443 check send-proxy-v2', shared)
        for value in ('8.8.8.8', '127.0.0.1', '172.29.0.2\nbackend other'):
            with self.assertRaises(ValueError): sni_proxy(['web.test'], 'turn.test', legacy_ip=value)

    def test_changed_public_template_cannot_silently_skip_security_boundary(self):
        topology = load(Path(__file__).resolve().parents[1] / 'infra/three-vps.example.json')
        source = (Path(__file__).resolve().parents[1] / 'infra/Caddyfile').read_text()
        changed = source.replace('    respond @private 404', '    respond @private 403')
        with patch.object(Path, 'read_text', return_value=changed):
            with self.assertRaisesRegex(ValueError, 'boundary changed'):
                edge_proxy(topology, 'b', '10.88.0.1', '172.30.0.2')
