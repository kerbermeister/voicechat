"""Real loopback HTTP, authenticated Matrix doubles, isolated stream state."""
import io
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch
import token_server
from stream_http import StreamService, stream_limits
from stream_sessions import StreamLimits
from contacts import ContactError


class Friends:
    def __init__(self):
        self.denied = set()

    def accepted(self, owner, user):
        return owner != user and user not in self.denied


class StreamHTTPTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.now = 1000.
        self.friends = Friends()
        self.revoked = set()
        self.blocked = set()
        self.deleted = []
        self.service = StreamService(Path(self.directory.name) / 'streams.sqlite', self.friends,
            lambda owner, user: user not in self.blocked,
            lambda user, device: (user, device) not in self.revoked,
            lambda method, body: self.deleted.append(body['room']),
            enabled=True, clock=lambda: self.now)
        self.addCleanup(self.service.core.close)
        self.addCleanup(patch.stopall)
        patch.object(token_server, '_streams', self.service).start()
        def matrix(handler, path, body=None):
            auth = handler.headers.get('Authorization', '')
            if auth not in ('Bearer alice', 'Bearer bob', 'Bearer eve'):
                raise ContactError('unauthorized')
            user = auth.split()[1]
            if path == 'account/whoami':
                return {'user_id': '@' + user + ':local', 'device_id': 'phone'}
            if path.startswith('devices/'):
                return {'device_id': 'phone'}
            if path == 'keys/query':
                return {'device_keys': {'@' + user + ':local': {'phone': {
                    'user_id': '@' + user + ':local', 'device_id': 'phone',
                    'keys': {'curve25519:phone': 'A' * 43, 'ed25519:phone': 'B' * 43}}}}}
            raise AssertionError(path)
        patch.object(token_server.Handler, 'matrix', matrix).start()
        self.server = token_server.ControlServer(('127.0.0.1', 0), token_server.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, operation=None, actor='alice', raw=None, **body):
        if raw is None and operation is not None:
            raw = json.dumps(dict(protocol_version=1, operation=operation, **body)).encode()
        req = urllib.request.Request(f'http://127.0.0.1:{self.server.server_port}/streams',
            raw, {'Authorization': 'Bearer ' + actor, 'Content-Type': 'application/json'})
        try:
            response = urllib.request.urlopen(req, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            self.assertEqual(response.headers['Cache-Control'], 'no-store')
            return response.status, json.load(response)

    def start(self, **extra):
        data = dict(request_id='attempt', title='private', description='', audience=['@bob:local'],
                    comments=True, duration=100)
        data.update(extra)
        status, body = self.request('start', **data)
        self.assertEqual(status, 200, body)
        return body['id']

    def test_auth_and_disabled_capabilities(self):
        self.assertEqual(self.request(actor='fake')[0], 401)
        self.service.enabled = False
        status, body = self.request()
        self.assertEqual(status, 200)
        self.assertFalse(body['enabled'])
        self.assertFalse(body['media_enabled'])
        self.assertEqual(self.request('discover')[0], 503)

    def test_private_stream_and_history(self):
        identifier = self.start()
        self.assertEqual(self.request('discover', actor='eve')[1]['streams'], [])
        self.assertEqual(self.request('info', actor='eve', stream_id=identifier)[0], 404)
        self.assertEqual(self.request('join', actor='bob', stream_id=identifier)[0], 200)
        self.assertEqual(self.request('comment', stream_id=identifier, message_id='one', ciphertext='YQ==')[0], 200)
        self.assertEqual(self.request('history', actor='bob', stream_id=identifier,
                         after=0, head=None, limit=100)[1]['head'], 1)

    def test_expired_or_revoked_owner_is_retired_by_tick(self):
        identifier = self.start()
        self.revoked.add(('@alice:local', 'phone'))
        self.now += 2.1
        self.service.tick()
        self.assertEqual(self.request('info', actor='bob', stream_id=identifier)[0], 404)
        self.assertEqual(len(self.deleted), 1)
        self.assertEqual(self.service.core.pending_cleanup(), [])

    def test_block_and_revoked_viewer(self):
        identifier = self.start()
        self.request('join', actor='bob', stream_id=identifier)
        self.revoked.add(('@bob:local', 'phone'))
        self.now += 2.1
        self.assertEqual(self.request('info', actor='bob', stream_id=identifier)[0], 403)
        self.service.tick()
        self.assertEqual(self.request('info', stream_id=identifier)[1]['viewers'], 0)
        self.blocked.add('@bob:local')
        self.assertEqual(self.request('info', actor='bob', stream_id=identifier)[0], 403)

    def test_pause_survives_sixty_seconds_and_deadline_does_not(self):
        identifier = self.start()
        self.assertEqual(self.request('pause', stream_id=identifier, revision=1)[0], 200)
        self.now += 61
        self.service.tick()
        self.assertEqual(self.request('info', stream_id=identifier)[1]['state'], 'paused')
        self.now += 39
        self.service.tick()
        self.assertEqual(self.request('resume', stream_id=identifier, revision=3)[0], 404)
        self.assertEqual(len(self.deleted), 2)

    def test_missing_heartbeat_ends_stream_without_client(self):
        self.start()
        self.now += 16
        self.service.tick()
        self.assertEqual(self.request('discover')[1]['streams'][0]['state'], 'reconnecting')
        self.now += 44
        self.service.tick()
        self.assertEqual(self.request('discover')[1]['streams'], [])
        self.assertEqual(len(self.deleted), 1)

    def test_comment_disabled_and_validation(self):
        identifier = self.start(comments=False)
        self.assertEqual(self.request('comment', stream_id=identifier, message_id='one', ciphertext='YQ==')[0], 403)
        self.assertEqual(self.request(raw=b'{"operation":"discover","protocol_version":1,"role":"owner"}')[0], 400)
        self.assertEqual(self.request(raw=b'[]')[0], 400)

    def test_device_keys_must_exist(self):
        with patch.object(token_server.Handler, 'matrix', return_value={'user_id': '@a:local', 'device_id': 'phone'}):
            self.assertEqual(self.request('discover')[0], 403)


class StreamConfigurationTests(unittest.TestCase):
    def test_server_property(self):
        self.assertEqual(stream_limits({}).max_duration, 10800)
        self.assertEqual(stream_limits({'STREAM_MAX_DURATION_SECONDS': '42'}).max_duration, 42)
        for value in ('0', '-1', '3h', '', '١٢', '1.5', None):
            with self.assertRaises(ValueError):
                stream_limits({'STREAM_MAX_DURATION_SECONDS': value})


class StreamMediaTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.now = 1000.
        self.calls = []
        self.friends = Friends()
        self.core_service = StreamService(Path(self.directory.name) / 'cleanup.sqlite', self.friends,
            lambda a, b: True, lambda a, b: True,
            lambda method, body: self.calls.append((method, body)), enabled=True,
            media_enabled=True, signer=lambda payload: payload, clock=lambda: self.now)
        self.addCleanup(self.core_service.core.close)
        self.owner, self.viewer = ('@a:local', 'A'), ('@b:local', 'B')
        self.core = self.core_service.core
        self.identifier = self.core.start(self.owner, title='test')['id']
        self.core_service.tick()

    def command(self, actor, operation, **body):
        return self.core_service.media_command(actor,
            {'stream_id': self.identifier, 'operation': operation, **body}, lambda *args: {})

    def test_roster_rotation_revokes_old_room_before_creating_new(self):
        first = self.core.info(self.identifier, self.owner)
        self.core.join(self.identifier, self.viewer)
        self.core_service.tick()
        second = self.core.info(self.identifier, self.owner)
        self.assertNotEqual(first['generation'], second['generation'])
        self.assertEqual(second['key_epoch'], first['key_epoch'] + 1)
        self.assertEqual(self.calls[-2][0], 'DeleteRoom')
        self.assertEqual(self.calls[-1][0], 'CreateRoom')
        self.assertEqual(self.calls[-1][1]['maxParticipants'], 11)

    def test_grants_and_owner_only_key_distribution(self):
        self.core.join(self.identifier, self.viewer)
        self.core_service.tick()
        epoch = self.core.info(self.identifier, self.owner)['key_epoch']
        grant = self.command(self.owner, 'grant', epoch=epoch)['token']['video']
        self.assertTrue(grant['canPublish'])
        self.assertFalse(grant['canPublishData'])
        self.assertEqual(grant['canPublishSources'], ['camera', 'microphone'])
        with self.assertRaisesRegex(Exception, 'stream_key_pending'):
            self.command(self.viewer, 'grant', epoch=epoch)
        envelope = {'algorithm': 'm.olm.v1.curve25519-aes-sha2', 'sender_key': 'curve', 'ciphertext': {}}
        self.command(self.owner, 'key_put', epoch=epoch, user=self.viewer[0], device=self.viewer[1], part=0, parts=1, envelope=envelope)
        grant = self.command(self.viewer, 'grant', epoch=epoch)['token']['video']
        self.assertFalse(grant['canPublish'])
        self.assertTrue(grant['canSubscribe'])
        self.assertEqual(self.command(self.viewer, 'key_get')['envelopes'], [envelope])
        with self.assertRaisesRegex(Exception, 'stream_owner_required'):
            self.command(self.viewer, 'key_put', epoch=epoch, user=self.owner[0], device=self.owner[1], part=0, parts=1, envelope=envelope)
        self.friends.denied.add(self.viewer[0])
        self.core_service.tick()
        with self.assertRaisesRegex(Exception, 'stream_unavailable'):
            self.command(self.viewer, 'key_get')
        self.assertNotEqual(epoch, self.core.info(self.identifier, self.owner)['key_epoch'])

    def test_partial_key_bundle_cannot_grant_and_out_of_order_upload_is_ordered(self):
        self.core.join(self.identifier, self.viewer)
        self.core_service.tick()
        epoch = self.core.info(self.identifier, self.owner)['key_epoch']
        envelopes = [{'algorithm': 'm.olm.v1.curve25519-aes-sha2',
                      'sender_key': str(i), 'ciphertext': {}} for i in range(2)]
        for part in (1, 0):
            self.command(self.owner, 'key_put', epoch=epoch,
                         user=self.viewer[0], device=self.viewer[1],
                         part=part, parts=2, envelope=envelopes[part])
            if part == 1:
                for operation in ('key_get', 'grant'):
                    with self.assertRaisesRegex(Exception, 'stream_key_pending'):
                        self.command(self.viewer, operation, epoch=epoch)
        self.assertEqual(self.command(self.viewer, 'key_get')['envelopes'], envelopes)
        self.assertFalse(self.command(self.viewer, 'grant', epoch=epoch)['token']['video']['canPublish'])

    def test_paused_owner_cannot_publish_and_old_room_is_deleted(self):
        state = self.core.info(self.identifier, self.owner)
        self.core.transition(self.identifier, self.owner, 'pause', state['revision'])
        self.core.rotate(self.identifier, keys=False)
        self.core_service.tick()
        self.assertEqual(self.calls[-1][0], 'DeleteRoom')
        self.assertEqual(self.core.info(self.identifier, self.owner)['key_epoch'], state['key_epoch'])
        with self.assertRaisesRegex(Exception, 'stream_paused'):
            self.command(self.owner, 'grant', epoch=state['key_epoch'])

    def test_key_envelope_immutable_for_epoch_and_stale_epoch_rejected(self):
        self.core.join(self.identifier, self.viewer)
        self.core_service.tick()
        epoch = self.core.info(self.identifier, self.owner)['key_epoch']
        envelope = {'algorithm': 'm.olm.v1.curve25519-aes-sha2', 'sender_key': 'curve', 'ciphertext': {}}
        args = dict(epoch=epoch, user=self.viewer[0], device=self.viewer[1], part=0, parts=1, envelope=envelope)
        self.command(self.owner, 'key_put', **args)
        self.command(self.owner, 'key_put', **args)
        with self.assertRaisesRegex(Exception, 'stream_key_conflict'):
            self.command(self.owner, 'key_put', **{**args, 'envelope': {**envelope, 'sender_key': 'changed'}})
        with self.assertRaisesRegex(Exception, 'stream_revision_conflict'):
            self.command(self.owner, 'grant', epoch=epoch - 1)
