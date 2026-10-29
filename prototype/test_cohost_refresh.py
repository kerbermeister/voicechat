from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import cohost_tls
import managed_state
import shared_ingress
import test_shared_cutover


class CohostRefreshTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_shared_cutover.SharedPortCutoverTests(); self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root, self.edge, self.system = self.fixture.root, self.fixture.edge, self.fixture.system
        self.generations = {'web': 'a' * 64, 'turn': 'b' * 64}
        self.calls = []; self.missing_turn = False; self.fail_turn = False

    def source(self, root, **kwargs):
        pointer = managed_state.read(root / 'current.json')
        target = shared_ingress.read_plan(root, root / 'plans' / pointer['plan'], system_root=self.system)[0]
        return target, root / 'unused-certificate-source', 'deploy_caddy_data'

    def execute(self, args, *, env=None):
        if args[:2] == ['docker', 'ps'] and any('project=voicechat-edge-a' in arg for arg in args):
            turn = args[-1].endswith('=turn')
            return b'' if turn and self.missing_turn else (b'2' if turn else b'1') * 64
        return self.fixture.execute(args, env=env)

    def activate(self, root, public, edge, service, chain, key, **kwargs):
        for directory in (self.root, self.root / 'front', self.edge):
            with self.assertRaises(BlockingIOError):
                with managed_state.locked(directory): pass
        self.assertEqual(root, self.edge / 'runtime/tls')
        self.assertEqual(edge, 'a')
        self.assertEqual(kwargs['address'], '127.0.0.1')
        self.assertEqual(kwargs['port'], 19443)
        self.assertEqual(chain, self.root / 'certificates' / self.generations[service] / (service + '.crt'))
        self.assertEqual(key, chain.with_suffix('.key'))
        self.calls.append(service)
        if self.fail_turn and service == 'turn': raise RuntimeError('Fixture TLS reload failure')
        return {'generation': self.generations[service]}

    def refresh(self, *, locked=False):
        with patch.object(cohost_tls, '_source', side_effect=self.source), \
                patch.object(cohost_tls, '_capture_locked', return_value={'generations': self.generations}) as capture, \
                patch.object(cohost_tls.tls_activation, 'activate', side_effect=self.activate):
            self.capture = capture
            operation = cohost_tls._refresh_locked if locked else cohost_tls.refresh
            return operation(self.root, execute=self.execute, system_root=self.system)

    def test_both_legacy_warm_and_shared_public_modes_verify_the_owned_loopback(self):
        expected = {'edge_id': 'a', 'generations': self.generations}
        self.assertEqual(self.refresh(), expected)
        self.assertEqual(self.calls, ['web', 'turn'])
        self.fixture.activate()
        self.assertEqual(self.refresh(), expected)
        self.assertEqual(self.calls, ['web', 'turn', 'web', 'turn'])

    def test_full_migration_reuses_parent_ingress_lock(self):
        with managed_state.locked(self.root):
            with self.assertRaises(BlockingIOError): self.refresh()
            self.assertEqual(self.calls, [])
            self.refresh(locked=True)
        self.assertEqual(self.calls, ['web', 'turn'])

    def test_wrong_frontend_phase_or_public_binding_fails_before_capture_or_reload(self):
        state = self.root / 'front/warm.json'; original = managed_state.read(state)
        managed_state.persist(state, {**original, 'phase': 'public'})
        with self.assertRaisesRegex(ValueError, 'phase differs'): self.refresh()
        self.capture.assert_not_called(); self.assertEqual(self.calls, [])
        managed_state.persist(state, original)
        self.fixture.front.container['ports']['8443/tcp'][0]['HostIp'] = '0.0.0.0'
        with self.assertRaisesRegex(ValueError, 'ports or networks changed'): self.refresh()
        self.capture.assert_not_called(); self.assertEqual(self.calls, [])

    def test_changed_edge_or_front_configuration_is_rejected_before_key_capture(self):
        state = self.edge / 'state.json'; original = managed_state.read(state)
        managed_state.persist(state, {**original, 'current': None})
        with self.assertRaisesRegex(ValueError, 'committed edge'): self.refresh()
        self.capture.assert_not_called(); self.assertEqual(self.calls, [])
        managed_state.persist(state, original)
        path = self.fixture.front_plan / 'haproxy.cfg'; path.write_text(path.read_text() + '\n# changed\n')
        with self.assertRaisesRegex(ValueError, 'checksum changed'): self.refresh()
        self.capture.assert_not_called(); self.assertEqual(self.calls, [])

    def test_missing_service_and_reload_failure_never_report_both_generations_ready(self):
        self.missing_turn = True
        with self.assertRaisesRegex(ValueError, 'One running owned'): self.refresh()
        self.assertEqual(self.calls, ['web'])
        self.missing_turn = False; self.fail_turn = True
        with self.assertRaisesRegex(RuntimeError, 'TLS reload'): self.refresh()
        self.fail_turn = False
        self.assertEqual(self.refresh()['generations'], self.generations)
        # Existing per-service activation receipts handle repeated identical pairs
        # without signals; this bridge must still retry the failed service.
        self.assertEqual(self.calls, ['web','web','turn','web','turn'])


if __name__ == '__main__': unittest.main()
