import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
from topology import load, validate, client_defines, unique_object, read_json

EXAMPLE = Path(__file__).resolve().parents[1] / 'infra/three-vps.example.json'


class TopologyTests(unittest.TestCase):
    def test_config_files_are_bounded_utf8_and_reject_duplicate_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)/'config.json'
            for content in (b' '*65537, b'{"schema":1,"schema":1}', b'"\xff"', '{}'.encode('utf-16')):
                path.write_bytes(content)
                with self.assertRaises(ValueError): read_json(path)
            path.write_bytes(b'{}')
            self.assertEqual(read_json(path), {})
    def test_single_entry_uses_the_same_public_contract(self):
        public = load(EXAMPLE.with_name('single-vps.example.json'))
        self.assertEqual(len(public['edges']), 1)
        self.assertEqual(json.loads(client_defines(public)['ROUTE_CONFIG']), public)
        with self.assertRaises(ValueError): validate({**public, 'edges':[]})

    def test_roundtrip_and_no_physical_hosts_or_secrets_in_client(self):
        value = load(EXAMPLE)
        defines = client_defines(value)
        self.assertEqual(json.loads(defines['ROUTE_CONFIG']), value)
        self.assertEqual(defines['MATRIX_URL'], value['canonical_origin'])
        self.assertEqual(defines['TOKEN_URL'], value['canonical_origin'] + '/api')
        self.assertEqual(set(defines), {'MATRIX_URL', 'TOKEN_URL', 'LIVEKIT_URL', 'ROUTE_CONFIG'})
        # Replacing a host is deliberately absent from the public topology.
        for forbidden in ('address', 'password', 'secret', 'host_key'):
            bad = copy.deepcopy(value); bad['edges'][1][forbidden] = 'unexpected'
            with self.assertRaises(ValueError): validate(bad)

    def test_invalid_contracts_fail_closed(self):
        base = load(EXAMPLE)
        mutations = [
            lambda v: v.update(schema=True), lambda v: v.update(schema=2),
            lambda v: v.update(service_id=''), lambda v: v.update(edges=[]),
            lambda v: v['edges'][1].update(id='b'),
            lambda v: v['edges'][1].update(origin=v['edges'][0]['origin']),
            lambda v: v['edges'][1].update(turn_host=v['edges'][0]['turn_host']),
            lambda v: v['edges'][0].update(origin='http://localhost:8000'),
            lambda v: v['edges'][0].update(origin='https://user:password@example.com'),
            lambda v: v['edges'][0].update(origin='https://example.com?'),
            lambda v: v['edges'][0].update(origin='https://example.com/path'),
            lambda v: v.update(web_origins=[]),
            lambda v: v.update(matrix_server_name='some\nserver'),
        ]
        for mutate in mutations:
            value = copy.deepcopy(base); mutate(value)
            with self.subTest(value=value), self.assertRaises(ValueError): validate(value)
        with self.assertRaises(ValueError):
            json.loads('{"schema":1,"schema":2}', object_pairs_hook=unique_object)
