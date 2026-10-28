from copy import deepcopy
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import role_release
from render_roles import bundle, write_bundle
from test_node_inventory import fixture
from topology import load

IMAGE = 'ghcr.io/example/voicechat@sha256:' + '1' * 64


class RoleReleaseTests(unittest.TestCase):
    def setUp(self):
        self.public = load(ROOT / 'infra/three-vps.example.json')
        self.inventory = fixture()
        self.core = role_release.make(self.public, self.inventory, 'core', 'a' * 40, IMAGE)
        self.edge = role_release.make(self.public, self.inventory, 'edge', 'a' * 40, IMAGE, 'b')

    def test_complete_bundles_and_cross_role_compatibility(self):
        role_release.require_compatible(self.core, self.edge)
        with tempfile.TemporaryDirectory() as temporary:
            for manifest in (self.core, self.edge):
                root = Path(temporary) / manifest['role']
                files, runtime = bundle(self.public, self.inventory, manifest['role'], manifest['edge_id'])
                write_bundle(root, files, runtime)
                role_release.verify_bundle(root, manifest, self.public, self.inventory)
                self.assertFalse(any('runtime/' in name for name in manifest['files']))
                manifest_file = Path(temporary) / (manifest['role'] + '.json')
                manifest_file.write_text(json.dumps(manifest))
                self.assertEqual(role_release.load(manifest_file), manifest)

    def test_reject_partial_tampered_and_symlinked_bundle_even_with_changed_checksum(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'edge'
            files, runtime = bundle(self.public, self.inventory, 'edge', 'b')
            write_bundle(root, files, runtime)
            caddy = root / 'infra/Caddyfile'
            original = caddy.read_text()
            caddy.write_text(original + '\n# altered\n')
            for update_hash in (False, True):
                manifest = deepcopy(self.edge)
                if update_hash: manifest['files']['infra/Caddyfile'] = role_release.digest(caddy.read_bytes())
                with self.assertRaises(ValueError): role_release.verify_bundle(root, manifest, self.public, self.inventory)
            caddy.unlink()
            with self.assertRaises(ValueError): role_release.verify_bundle(root, self.edge, self.public, self.inventory)
            elsewhere = Path(temporary) / 'source'
            elsewhere.write_text(original)
            caddy.symlink_to(elsewhere)
            with self.assertRaises(ValueError): role_release.verify_bundle(root, self.edge, self.public, self.inventory)
            manifest = deepcopy(self.edge)
            del manifest['files']['infra/Caddyfile']
            with self.assertRaises(ValueError): role_release.verify_bundle(root, manifest, self.public, self.inventory)

    def test_web_only_reuses_every_non_web_input(self):
        target = deepcopy(self.edge)
        target['commit'] = 'b' * 40
        target['images']['web'] = IMAGE.replace('1' * 64, '2' * 64)
        role_release.require_web_only(self.edge, target)
        changes = [
            lambda v: v.update(node_sha256='3' * 64),
            lambda v: v.update(topology_sha256='3' * 64),
            lambda v: v.update(edge_id='c'),
            lambda v: v['images'].update(turn='coturn/coturn@sha256:' + '3' * 64),
            lambda v: v['files'].update({'infra/Caddyfile': '3' * 64}),
            lambda v: v['files'].update({'infra/edge_turn.py': '3' * 64}),
        ]
        for change in changes:
            changed = deepcopy(target); change(changed)
            with self.assertRaises(ValueError): role_release.require_web_only(self.edge, changed)
        for before in (None, self.core):
            with self.assertRaises(ValueError): role_release.require_web_only(before, target)

    def test_extra_importable_code_is_rejected_even_with_all_expected_hashes_intact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'edge'
            files, runtime = bundle(self.public, self.inventory, 'edge', 'b')
            write_bundle(root, files, runtime)
            for name in ('infra/subprocess.py', 'infra/__pycache__', 'unreviewed.py'):
                extra = root / name
                extra.write_text('unreviewed')
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'Unexpected'):
                    role_release.verify_bundle(root, self.edge, self.public, self.inventory)
                extra.unlink()
            # Secret/runtime material is not mistaken for executable source.
            (root / 'infra/runtime/turn-secret').write_text('synthetic')
            (root / 'release.json').write_text(json.dumps(self.edge))
            role_release.verify_bundle(root, self.edge, self.public, self.inventory)

    def test_unknown_contracts_bad_images_and_incomplete_manifests_fail_closed(self):
        changes = [
            lambda v: v.update(schema=True),
            lambda v: v.update(schema=2),
            lambda v: v['contracts'].update(core_storage=2),
            lambda v: v['contracts'].update(core_api=True),
            lambda v: v['contracts'].pop('role_config'),
            lambda v: v['images'].update(web='ghcr.io/example/voicechat:latest'),
            lambda v: v['images'].pop('turn'),
            lambda v: v['files'].pop('infra/node.json'),
            lambda v: v['files'].update({'../stand.env': '1' * 64}),
            lambda v: v['files'].update({'infra/runtime/stand.env': '1' * 64}),
            lambda v: v.update(commit='not-a-commit'),
        ]
        for change in changes:
            changed = deepcopy(self.edge); change(changed)
            with self.assertRaises(ValueError): role_release.validate(changed)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'manifest.json'
            path.write_text(json.dumps(self.edge)[:-1] + ', "schema": 1}')
            with self.assertRaises(ValueError): role_release.load(path)

    def test_staged_topology_is_compatible_but_other_installation_is_not(self):
        expanded = deepcopy(self.public)
        expanded['edges'].append({'id': 'd', 'origin': 'https://d.example.com', 'turn_host': 'turn-d.example.com'})
        inventory = deepcopy(self.inventory)
        inventory['edges'].append({**inventory['edges'][1], 'id': 'd', 'public_ip': '192.0.2.14',
            'tunnel_ip': '10.88.0.4', 'ssh_host_key': self.inventory['core']['ssh_host_key']})
        from test_node_inventory import key
        inventory['edges'][-1]['ssh_host_key'] = key(4)
        future_core = role_release.make(expanded, inventory, 'core', 'b' * 40, IMAGE)
        role_release.require_compatible(future_core, self.edge)
        for field, value in (('service_id', 'other'), ('identity', {
                'canonical_origin': 'https://other.example.com', 'matrix_server_name': 'other.example.com'})):
            changed = deepcopy(self.edge); changed[field] = value
            with self.assertRaises(ValueError): role_release.require_compatible(self.core, changed)

    def test_single_host_and_wrong_application_image(self):
        public = load(ROOT / 'infra/single-vps.example.json')
        inventory = {**self.inventory, 'edges': [{'id': 'a', 'host': 'core'}]}
        core = role_release.make(public, inventory, 'core', 'a' * 40, IMAGE)
        edge = role_release.make(public, inventory, 'edge', 'a' * 40, IMAGE, 'a')
        role_release.require_compatible(core, edge)
        self.assertNotIn('control', edge['images'])
        for image in ('local:latest', IMAGE + '\n', 'example.test/web@sha256:' + 'a' * 64):
            with self.assertRaises(ValueError): role_release.make(public, inventory, 'edge', 'a' * 40, image, 'a')


if __name__ == '__main__': unittest.main()
