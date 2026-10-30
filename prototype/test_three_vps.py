"""Guard the isolation of the opt-in local three-role proof."""
from pathlib import Path
import tempfile
import unittest

from check_three_vps import configuration


class ThreeVpsFixtureTests(unittest.TestCase):
    def test_only_edges_publish_loopback_and_core_has_disposable_volumes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            value = configuration(root, 'voicechat-routes-test')
            self.assertEqual(value['name'], 'voicechat-routes-test')
            self.assertEqual(value['volumes'], {'postgres': {}, 'synapse': {}})
            for name, service in value['services'].items():
                with self.subTest(name=name):
                    self.assertIn('@sha256:', service['image'])
                    self.assertNotIn('container_name', service)
                    self.assertNotIn('network_mode', service)
                    self.assertNotIn('privileged', service)
                    self.assertNotIn('env_file', service)
                    if name.startswith('edge-'):
                        self.assertEqual(service['ports'], ['127.0.0.1::80'])
                        self.assertEqual(service['volumes'], ['./' + name + '.Caddyfile:/etc/caddy/Caddyfile:ro', './catalog:/catalog:ro'])
                    else:
                        self.assertNotIn('ports', service)
                    for mount in service.get('volumes', []):
                        self.assertNotIn('.prototype', mount)
                        self.assertNotIn('runtime', mount)
            proxy = (root / 'Caddyfile').read_text()
            self.assertIn('respond @private 404', proxy)
            self.assertIn('admin off', proxy)

    def test_each_stand_gets_new_synthetic_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = configuration(root, 'voicechat-routes-one')
            second = configuration(root, 'voicechat-routes-two')
            self.assertNotEqual(
                first['services']['postgres']['environment']['POSTGRES_PASSWORD'],
                second['services']['postgres']['environment']['POSTGRES_PASSWORD'])


if __name__ == '__main__':
    unittest.main()
