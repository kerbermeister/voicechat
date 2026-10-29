from copy import deepcopy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import edge_deploy
import role_release
import topology
from test_node_inventory import fixture


class EdgeReadinessTests(unittest.TestCase):
    def setUp(self):
        public = topology.load(ROOT / 'infra/single-vps.example.json')
        inventory = fixture()
        inventory['edges'] = [{'id': 'a', 'host': 'core', 'shared_tls': {
            'network': 'voicechat-shared-ingress', 'subnet': '172.29.0.0/29',
            'legacy_ip': '172.29.0.2', 'ingress_ip': '172.29.0.3'}}]
        manifest = role_release.make(public, inventory, 'edge', 'a' * 40,
            'ghcr.io/fixture/web@sha256:' + '1' * 64, 'a')
        self.record = edge_deploy.record_for(public, inventory, manifest)
        self.value = {'schema': 1, 'service_id': 'voicechat', 'edge_id': 'a',
                      'matrix': True, 'control': True, 'age_ms': 5}

    def check(self, record=None, **kwargs):
        record = record or self.record
        with patch.object(edge_deploy, 'certificate', return_value=b'verified-pair') as certificate, patch.object(
                edge_deploy.tls_activation, 'verify_live') as verify, patch.object(
                edge_deploy.socket, 'create_connection') as connect, patch.object(
                edge_deploy.ssl, 'create_default_context') as context, patch.object(
                edge_deploy.http.client, 'HTTPResponse') as response:
            response.return_value.status = 200
            response.return_value.read.return_value = json.dumps(self.value).encode()
            edge_deploy.healthy(Path('/prepared-edge'), record, **kwargs)
            return certificate, verify, connect, context

    def test_default_uses_public_endpoint_and_warm_uses_only_loopback_with_both_trusted_pairs(self):
        for options, address, port in (({}, self.record['address'], 443), ({'warm_port': 19443}, '127.0.0.1', 19443)):
            with self.subTest(options=options):
                certificate, verify, connect, context = self.check(**options)
                self.assertEqual(certificate.call_count, 2)
                self.assertEqual(verify.call_count, 2)
                self.assertEqual([call.args[:2] for call in verify.call_args_list], [(address, port)] * 2)
                self.assertEqual({call.args[-1] for call in certificate.call_args_list}, {'web', 'turn'})
                connect.assert_called_once_with((address, port), timeout=5)
                context.assert_called_once_with()
                context.return_value.wrap_socket.assert_called_once()
                self.assertEqual(context.return_value.wrap_socket.call_args.kwargs['server_hostname'], 'chat.example.com')

    def test_wrong_service_stale_or_incomplete_upstream_readiness_fails_on_both_paths(self):
        original = deepcopy(self.value)
        for change in ({'service_id': 'foreign'}, {'edge_id': 'b'}, {'matrix': False},
                       {'control': False}, {'age_ms': 2001}, {'schema': True}):
            self.value = {**original, **change}
            for options in ({}, {'warm_port': 19443}):
                with self.subTest(change=change, options=options), self.assertRaises(ValueError): self.check(**options)

    def test_warm_port_is_bounded_and_cannot_bypass_a_dedicated_edge_check(self):
        with patch.object(edge_deploy, 'certificate') as certificate:
            for port in (True, 443, 65536, '19443'):
                with self.subTest(port=port), self.assertRaises(ValueError):
                    edge_deploy.healthy(Path('/prepared-edge'), self.record, warm_port=port)
            dedicated = deepcopy(self.record)
            dedicated['manifest']['files'].pop('infra/compose.shared-front.json')
            with self.assertRaises(ValueError): edge_deploy.healthy(Path('/prepared-edge'), dedicated, warm_port=19443)
            certificate.assert_not_called()


if __name__ == '__main__': unittest.main()
