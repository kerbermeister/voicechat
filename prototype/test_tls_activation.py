import json
from pathlib import Path
import socket
import ssl
import threading
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "infra"))
from unittest.mock import patch

import managed_state
import tls_activation
from test_tls_runtime import TLSRuntimeTests


class TLSActivationTests(TLSRuntimeTests):
    def setUp(self):
        super().setUp()
        self.root = self.root.resolve()
        self.container = 'a' * 64
        self.image = 'ghcr.io/fixture/web@sha256:' + 'b' * 64
        self.signals = []
        self.process = {'id': self.container, 'started': 'fixture-start', 'restarts': 0}

    def inspect_result(self):
        return {**self.process, 'image': self.image, 'running': True,
                'labels': {'com.docker.compose.project': 'voicechat-edge-b',
                           'com.docker.compose.service': 'web'},
                'mounts': [{'Destination': '/tls', 'Source': str(self.root / 'web'),
                            'Type': 'bind', 'RW': False}]}

    def docker(self, *args):
        if args[0] == 'inspect': return json.dumps(self.inspect_result()).encode()
        self.signals.append(args)
        return b''

    def activate(self, stem='old'):
        return tls_activation.activate(self.root, self.public, 'b', 'web', self.source / (stem + '.crt'),
            self.source / (stem + '.key'), container=self.container, image=self.image,
            address='127.0.0.1', ca_file=self.source / 'ca.crt', minimum_validity_days=1)

    def test_rotation_holds_writer_lock_through_handshake_and_records_exact_process(self):
        def handshake(address, port, names, certificate, **kwargs):
            self.assertEqual(names, ['web.routes.test'])
            self.assertIn(b'BEGIN CERTIFICATE', certificate)
            with self.assertRaises(BlockingIOError): self.publish('new')
        with patch.object(tls_activation, 'docker', side_effect=self.docker), \
                patch.object(tls_activation, 'verify_live', side_effect=handshake):
            old = self.activate()
            self.assertEqual(self.activate(), old)
            new = self.activate('new')
            rollback = self.activate()
        self.assertEqual(new['previous'], old['generation'])
        self.assertEqual(rollback['generation'], old['generation'])
        self.assertFalse(new['reload_required'])
        state = managed_state.read(self.root / 'web.activation.json')
        self.assertEqual(state['phase'], 'verified')
        self.assertEqual(state['container'], self.process)
        self.assertEqual(self.signals, [('kill', '--signal', 'SIGUSR1', self.container)] * 3)

    def test_failed_signal_or_handshake_never_claims_activation_and_can_retry_or_rollback(self):
        with patch.object(tls_activation, 'docker', side_effect=self.docker), \
                patch.object(tls_activation, 'verify_live') as verify:
            old = self.activate()
            verify.side_effect = TimeoutError('old certificate still served')
            with self.assertRaises(TimeoutError): self.activate('new')
            self.assertEqual(managed_state.read(self.root / 'web.activation.json')['phase'], 'pending')
            verify.side_effect = None
            result = self.activate()
            self.assertEqual(result['generation'], old['generation'])
            def failure(*args):
                if args[0] == 'kill': raise RuntimeError('signal failed')
                return self.docker(*args)
            with patch.object(tls_activation, 'docker', side_effect=failure):
                with self.assertRaises(RuntimeError): self.activate('new')
            self.assertEqual(managed_state.read(self.root / 'web.activation.json')['phase'], 'pending')
            self.activate('new')
            self.assertEqual(managed_state.read(self.root / 'web.activation.json')['phase'], 'verified')

    def test_foreign_container_or_mount_rejected_before_publication(self):
        valid = self.inspect_result()
        for update in ({'image': 'mutable:tag'}, {'running': False}, {'labels': {}},
                       {'mounts': []}, {'mounts': [{**valid['mounts'][0], 'RW': True}]},
                       {'mounts': [{**valid['mounts'][0], 'Source': '/foreign/tls'}]}):
            with self.subTest(update=update), patch.object(tls_activation, 'docker',
                    return_value=json.dumps({**valid, **update}).encode()):
                with self.assertRaises(ValueError): self.activate()
                self.assertFalse((self.root / 'web.json').exists())

    def test_restart_during_handshake_leaves_pending_receipt(self):
        def restarted(*args, **kwargs): self.process['restarts'] += 1
        with patch.object(tls_activation, 'docker', side_effect=self.docker), \
                patch.object(tls_activation, 'verify_live', side_effect=restarted):
            with self.assertRaisesRegex(RuntimeError, 'restarted'): self.activate()
        self.assertEqual(managed_state.read(self.root / 'web.activation.json')['phase'], 'pending')

    def test_real_tls_hostname_ca_and_exact_certificate_handshake(self):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.source / 'old.crt', self.source / 'old.key')
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(3)
        listener.settimeout(2)
        errors = []
        def serve():
            try:
                for _ in range(2):
                    connection, _ = listener.accept()
                    with context.wrap_socket(connection, server_side=True): pass
            except Exception as error: errors.append(error)
        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        try:
            args = ('127.0.0.1', listener.getsockname()[1], ['web.routes.test'])
            tls_activation.verify_live(*args, (self.source / 'old.crt').read_bytes(), ca_file=self.source / 'ca.crt')
            # Trusted and same hostname is insufficient: the exact renewed leaf
            # must be visible before activation can be acknowledged.
            with patch.object(tls_activation.time, 'monotonic', side_effect=[0, 0, 16, 16]):
                with self.assertRaises(TimeoutError):
                    tls_activation.verify_live(*args, (self.source / 'new.crt').read_bytes(), ca_file=self.source / 'ca.crt')
        finally:
            thread.join(timeout=3)
            listener.close()
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
