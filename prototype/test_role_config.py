from copy import deepcopy
import json
import os
from pathlib import Path
import ipaddress
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import configure
from edge_turn import configuration as turn_configuration
from render_roles import NETWORK_FILES, bundle, write_bundle
import role_config
from topology import load
from test_node_inventory import fixture


class RoleConfigTests(unittest.TestCase):
    def setUp(self):
        self.public = load(ROOT / 'infra/three-vps.example.json')
        self.inventory = fixture()

    def test_core_and_one_edge_share_machine_but_not_runtime_or_data(self):
        public = load(ROOT / 'infra/single-vps.example.json')
        inventory = {**self.inventory, 'edges':[{'id':'a','host':'core'}]}
        core = role_config.core(public, inventory)
        edge, files = role_config.edge(public, inventory, 'a')
        self.assertEqual(core['name'], 'voicechat')
        self.assertEqual(edge['name'], 'voicechat-edge-a')
        self.assertEqual(set(edge['volumes']), {'turn-config'})
        self.assertEqual(json.loads(files['node.json'])['public_ip'], inventory['core']['public_ip'])
        self.assertIn('10.88.0.1:8088', files['Caddyfile'])
        self.assertNotIn('stand.env', json.dumps(edge))
        self.assertEqual(set(core['services']) & set(edge['services']), {'configure'})
        # Both are independent bundles; matching service names never share a project.
        for role in ('core', 'edge'):
            contents, _ = bundle(public, inventory, role, 'a' if role == 'edge' else None)
            self.assertIn('infra/compose.' + role + '.json', contents)

    def test_edge_has_only_role_secrets_and_no_business_data(self):
        compose, _ = role_config.edge(self.public, self.inventory, 'c')
        self.assertEqual(set(compose['services']), {'configure', 'ingress', 'web', 'route-health', 'turn'})
        self.assertEqual(set(compose['volumes']), {'turn-config'})
        serialized = json.dumps(compose)
        for forbidden in ('stand.env', 'POSTGRES_PASSWORD', 'LIVEKIT_SECRET', 'POLICY_SECRET', 'REGISTRATION_SECRET',
                          'MACAROON_SECRET', 'offline-key', 'synapse:/', 'control:/'):
            self.assertNotIn(forbidden, serialized)
        self.assertIn('./runtime/turn-secret', serialized)
        self.assertEqual(compose['services']['web']['depends_on'], ['route-health'])
        self.assertEqual(compose['services']['turn']['user'], '10001:10001')
        addresses = [service['networks']['default']['ipv4_address'] for service in compose['services'].values()]
        self.assertEqual(len(addresses), len(set(addresses)))
        for name, service in compose['services'].items():
            self.assertEqual(service['logging'], role_config.LOGGING)
            self.assertTrue(service['read_only'])
            for mount in service['volumes']:
                if isinstance(mount, dict):
                    self.assertTrue(mount['read_only'])
                    self.assertFalse(mount['bind']['create_host_path'])
        for subnet in ('0.0.0.0/28', '192.0.2.0/28', '10.88.0.0/28', '10.241.0.0/24'):
            with self.assertRaises(ValueError): role_config.edge(self.public, self.inventory, 'c', subnet)

    def test_core_uses_existing_services_identity_and_volume_namespace(self):
        public = deepcopy(self.public)
        public['web_origins'].reverse()
        compose = role_config.core(public, self.inventory)
        self.assertEqual(compose['name'], 'voicechat')
        self.assertEqual(set(compose['services']), {'configure', 'postgres', 'synapse', 'control'})
        for name, service in compose['services'].items():
            self.assertEqual(service['extends'], {'file':'compose.yaml', 'service':name})
            self.assertEqual(service['sysctls']['net.ipv4.ip_local_reserved_ports'], '50300-50400')
        self.assertEqual(set(compose['volumes']), {'postgres','synapse','control','media-config','turn-config'})
        control = compose['services']['control']
        self.assertEqual(control['environment']['VOICECHAT_ORIGINS'].split(',')[0], public['canonical_origin'])
        self.assertEqual(control['environment']['VOICECHAT_PUSH_GATEWAY_URL'],
                         'http://10.88.0.1:8090/_matrix/push/v1/notify')
        self.assertEqual(compose['services']['configure']['environment']['VOICECHAT_PUSH_GATEWAY_IP'], '10.88.0.1')
        self.assertEqual(control['ports'], ['10.88.0.1:8090:8090', '10.88.0.1:7880:7880'])
        self.assertNotIn('MATRIX_SERVER_NAME', compose['services']['configure']['environment'])

    def test_core_configuration_keeps_secrets_and_rejects_identity_change_before_writes(self):
        env = {'LOCAL_STAND':'0', 'MATRIX_SERVER_NAME':self.public['matrix_server_name'],
               'PUBLIC_URL':self.public['canonical_origin'], 'PUBLIC_IP':'192.0.2.10',
               'SMTP_HOST':'smtp.example.com', 'SMTP_PORT':'587',
               'VOICECHAT_ROUTE_CONFIG':json.dumps(self.public), 'VOICECHAT_PUSH_GATEWAY_IP':'10.88.0.1',
               **{key:'test-only' for key in ('POLICY_SECRET','POSTGRES_PASSWORD','REGISTRATION_SECRET',
                                             'MACAROON_SECRET','LIVEKIT_SECRET','TURN_SECRET')}}
        with patch.dict(os.environ, env, clear=True), patch.object(Path, 'exists', return_value=False), \
             patch.object(configure, 'configure_policy'), patch.object(configure, 'write') as write:
            configure.main()
            outputs = {args[0][0]:args[0][1] for args in write.call_args_list}
            synapse = json.loads(outputs['/matrix/homeserver.yaml'])
            self.assertEqual(synapse['ip_range_whitelist'], ['10.88.0.1/32'])
            self.assertNotIn('ip_range_blacklist', synapse)
            self.assertEqual(synapse['turn_shared_secret'], 'test-only')
            self.assertEqual(synapse['signing_key_path'], '/data/voicechat.signing.key')
            self.assertEqual(len(synapse['turn_uris']), 6)
            self.assertIn('turns:turn-c.example.com:443?transport=tcp', synapse['turn_uris'])
            self.assertNotIn('/turn/turnserver.conf', outputs)
            write.reset_mock()
            for gateway in ('', '127.0.0.1', '169.254.169.254', '192.0.2.10', '10.88.0.0/24', '10.88.0.1\n'):
                os.environ['VOICECHAT_PUSH_GATEWAY_IP'] = gateway
                with self.subTest(gateway=gateway), self.assertRaises(ValueError): configure.main()
                write.assert_not_called()
            os.environ['VOICECHAT_PUSH_GATEWAY_IP'] = '10.88.0.1'
            os.environ['MATRIX_SERVER_NAME'] = 'different.example.com'
            with self.assertRaises(ValueError): configure.main()
            write.assert_not_called()

    def test_turn_limits_and_private_peer_denials_and_secret_validation(self):
        text = turn_configuration('a'*64, '192.0.2.11', '10.241.0.4', 'chat.example.com')
        self.assertIn('external-ip=192.0.2.11/10.241.0.4', text)
        self.assertIn('tls-listening-port=5349', text)
        self.assertIn('denied-peer-ip=169.254.0.0-169.254.255.255', text)
        self.assertIn('user-quota=16', text)
        self.assertNotIn('allow-loopback-peers', text)
        self.assertNotIn('no-tls', text)
        for line in text.splitlines():
            if line.startswith('denied-peer-ip='):
                for address in line.split('=',1)[1].split('-'): ipaddress.ip_address(address)
        rotating = turn_configuration('a'*64 + '\n' + 'b'*64, '192.0.2.11', '10.241.0.4', 'chat.example.com')
        self.assertEqual(rotating.count('static-auth-secret='), 2)
        for secret in ('', 'a'*63, 'a'*64+'\nno-auth', 'a'*64+'\n'+'a'*64,
                       '\n'.join(letter*64 for letter in ('a','b','c'))):
            with self.assertRaises(ValueError): turn_configuration(secret, '192.0.2.11', '10.241.0.4', 'chat.example.com')

    def test_bundles_are_self_contained_without_generated_credentials(self):
        for role in ('core', 'edge'):
            with tempfile.TemporaryDirectory() as temporary:
                files, runtime = bundle(self.public, self.inventory, role, 'b' if role == 'edge' else None)
                self.assertTrue({'infra/' + name for name in NETWORK_FILES} <= files.keys())
                if role == 'core':
                    self.assertNotIn('${BIND}', files['infra/compose.yaml'])
                    self.assertIn('192.0.2.10:7981:7981/tcp', files['infra/compose.yaml'])
                    self.assertIn('192.0.2.10:50300-50400:50300-50400/udp', files['infra/compose.yaml'])
                    self.assertIn('${BIND}:7981', (ROOT / 'infra/compose.yaml').read_text())
                root = Path(temporary) / role
                write_bundle(root, files, runtime)
                self.assertFalse((root / 'infra/runtime/stand.env').exists())
                self.assertFalse((root / 'infra/runtime/turn-secret').exists())
                self.assertEqual(root.stat().st_mode & 0o777, 0o700)
                self.assertEqual((root / 'infra/configure.py').stat().st_mode & 0o777, 0o644)
                with self.assertRaises(FileExistsError): write_bundle(root, files, runtime)


if __name__ == '__main__': unittest.main()
