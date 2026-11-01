import json
import unittest
from stream_protocol import parse_command, dispatch
from stream_sessions import StreamError
import test_stream_sessions as fixtures


class StreamProtocolTests(unittest.TestCase):
    def reject(self, raw):
        with self.assertRaises(StreamError):
            parse_command(raw)

    def test_invalid_json_and_unknown_fields(self):
        for raw in (b'', b'x' * 32769, b'[]', b'null', b'\xff',
                    b'{"protocol_version":1,"protocol_version":1,"operation":"discover"}',
                    b'{"protocol_version":true,"operation":"discover"}',
                    b'{"protocol_version":1,"operation":"discover","owner":"alice"}',
                    b'{"protocol_version":1,"operation":[]}',
                    b'{"protocol_version":1,"operation":"discover","x":NaN}'):
            with self.subTest(raw=raw[:80]):
                self.reject(raw)

    def test_base64_and_bounds(self):
        for value in ('', '***', 'YQ', 'YR==', 'a' * 12000, 42):
            raw = json.dumps(dict(protocol_version=1, operation='comment',
                stream_id='stream', message_id='id', ciphertext=value)).encode()
            self.reject(raw)
        body = parse_command(b'{"protocol_version":1,"operation":"comment","stream_id":"s","message_id":"i","ciphertext":"YQ=="}')
        self.assertEqual(body['ciphertext'], b'a')

    def test_no_grant_or_transport_actions_from_client(self):
        for op in ('grant', 'recover', 'disconnect', 'publish'):
            self.reject(json.dumps(dict(protocol_version=1, operation=op)).encode())

    def test_revision_bounds(self):
        for revision in (0, -1, True, 9007199254740992, '1'):
            self.reject(json.dumps(dict(protocol_version=1, operation='resume', stream_id='s', revision=revision)).encode())


class StreamDispatchTests(unittest.TestCase):
    setUp = fixtures.StreamSessionsTests.setUp

    def request(self, actor, operation, **body):
        return dispatch(self.core, actor, json.dumps(dict(protocol_version=1, operation=operation, **body)).encode())

    def test_complete_metadata_and_chat_roundtrip(self):
        settings = dict(request_id='attempt', title='live', description='', audience=['bob'],
                        comments=True, duration=100)
        stream = self.request(self.owner, 'start', **settings)
        identifier = stream['id']
        self.assertEqual(self.request(self.owner, 'start', **settings)['id'], identifier)
        self.request(self.viewer, 'join', stream_id=identifier)
        self.request(self.owner, 'comment', stream_id=identifier, message_id='one', ciphertext='YQ==')
        history = self.request(self.viewer, 'history', stream_id=identifier, after=0, head=None, limit=100)
        self.assertEqual(history['messages'][0]['ciphertext'], 'YQ==')
        self.request(self.owner, 'pause', stream_id=identifier, revision=1)
        self.now += 61
        self.request(self.viewer, 'join', stream_id=identifier)
        self.assertEqual(self.request(self.viewer, 'history', stream_id=identifier, after=0, head=None, limit=100)['head'], 1)
        self.request(self.owner, 'resume', stream_id=identifier, revision=2)
        self.request(self.owner, 'stop', stream_id=identifier, revision=3)
        self.assertEqual(self.request(self.viewer, 'discover')['streams'], [])
