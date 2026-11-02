"""Isolated lifecycle assertions. No production services or account credentials."""
import concurrent.futures
import tempfile
import unittest
from pathlib import Path
from stream_sessions import StreamSessions, StreamLimits, StreamError


class StreamSessionsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'streams.sqlite'
        self.now = 1000.
        self.blocked = set()
        self.core = StreamSessions(self.path, lambda owner, user: user not in self.blocked,
                                   clock=lambda: self.now)
        self.addCleanup(self.core.close)
        self.owner = ('alice', 'phone')
        self.viewer = ('bob', 'phone')

    def start(self, **settings):
        return self.core.start(self.owner, title='PRIVATE TITLE', **settings)['id']

    def error(self, code, operation, *args, **kwargs):
        with self.assertRaises(StreamError) as error:
            operation(*args, **kwargs)
        self.assertEqual(str(error.exception), code)

    def test_settings_and_config(self):
        for value in (True, 0, -1, '10800', 10801):
            self.error('invalid_duration', self.start, duration=value)
        for value in (True, 0, -1, 1.5):
            with self.assertRaises(ValueError):
                StreamLimits(max_duration=value)
        self.error('invalid_settings', self.core.start, self.owner, title=' ')
        self.error('invalid_audience', self.start, audience=[])
        self.error('invalid_identity', self.core.discover, ('bob',))

    def test_deadline_and_changed_configuration(self):
        identifier = self.start()
        self.assertEqual(self.core.info(identifier, self.owner)['ends_at'], 11800)
        self.core.limits = StreamLimits(max_duration=5)
        self.now += 6
        self.assertEqual(self.core.info(identifier, self.owner)['state'], 'live')
        self.now = 11800
        self.error('stream_unavailable', self.core.info, identifier, self.owner)

    def test_shorter_duration(self):
        identifier = self.start(duration=10)
        self.now += 10
        self.assertEqual(self.core.discover(self.owner), [])

    def test_single_owner_including_other_device(self):
        self.start()
        self.error('stream_already_active', self.core.start, ('alice', 'laptop'), title='other')

    def test_private_discovery_and_direct_requests(self):
        identifier = self.start(audience=['bob'])
        self.assertEqual(len(self.core.discover(self.viewer)), 1)
        self.assertEqual(self.core.discover(('eve', 'phone')), [])
        self.error('stream_unavailable', self.core.join, identifier, ('eve', 'phone'))

    def test_concurrent_limit_and_owner_separate(self):
        identifier = self.start()
        def join(index):
            try:
                self.core.join(identifier, (str(index), 'phone'))
                return True
            except StreamError:
                return False
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            self.assertEqual(sum(pool.map(join, range(20))), 10)
        self.assertEqual(self.core.info(identifier, self.owner)['viewers'], 10)
        self.error('owner_cannot_watch', self.core.join, identifier, ('alice', 'other'))

    def test_device_and_expiry(self):
        identifier = self.start()
        self.core.join(identifier, self.viewer)
        self.core.join(identifier, self.viewer)
        self.error('stream_on_other_device', self.core.join, identifier, ('bob', 'other'))
        self.now += 60
        self.core.join(identifier, ('bob', 'other'))
        self.assertEqual(self.core.info(identifier, self.owner)['viewers'], 1)
        self.core.leave(identifier, self.viewer)
        self.assertEqual(self.core.info(identifier, self.owner)['viewers'], 1)

    def test_role_filtered_roster_and_membership(self):
        identifier = self.start()
        self.core.join(identifier, self.viewer)
        self.assertNotIn('viewer_users', self.core.info(identifier, self.viewer))
        self.assertEqual(self.core.info(identifier, self.owner)['viewer_users'], ['bob'])
        self.error('stream_join_required', self.core.history, identifier, ('eve', 'x'))
        self.error('stream_owner_required', self.core.transition, identifier, self.viewer, 'stop', 1)

    def test_pause_does_not_expire_at_sixty_seconds(self):
        identifier = self.start()
        self.core.transition(identifier, self.owner, 'pause', 1)
        self.now += 61
        self.assertEqual(self.core.info(identifier, self.owner)['state'], 'paused')
        self.error('invalid_transition', self.core.transition, identifier, self.owner, 'recover', 2)
        result = self.core.transition(identifier, self.owner, 'resume', 2)
        self.assertEqual(result['state'], 'live')
        self.assertEqual(result['ends_at'], 11800)

    def test_reconnect_timeout_not_extended_by_repeat(self):
        identifier = self.start()
        self.core.transition(identifier, self.owner, 'disconnect', 1)
        self.now += 59
        self.error('invalid_transition', self.core.transition, identifier, self.owner, 'disconnect', 2)
        self.now += 1
        self.error('stream_unavailable', self.core.info, identifier, self.owner)

    def test_recover_and_stale_resume_after_stop(self):
        identifier = self.start()
        self.core.transition(identifier, self.owner, 'disconnect', 1)
        self.now += 3
        self.core.transition(identifier, self.owner, 'recover', 2)
        self.error('stream_revision_conflict', self.core.transition, identifier, self.owner, 'pause', 1)
        self.core.transition(identifier, self.owner, 'stop', 3)
        self.error('stream_unavailable', self.core.transition, identifier, self.owner, 'resume', 3)

    def test_deadline_also_ends_pause(self):
        identifier = self.start(duration=20)
        self.core.transition(identifier, self.owner, 'pause', 1)
        self.now += 20
        self.error('stream_unavailable', self.core.transition, identifier, self.owner, 'resume', 2)

    def test_chat_late_join_snapshot_and_retry(self):
        identifier = self.start()
        self.assertEqual(self.core.send(identifier, self.owner, '1', b'cipher one'), 1)
        self.assertEqual(self.core.send(identifier, self.owner, '1', b'cipher one'), 1)
        self.error('message_id_conflict', self.core.send, identifier, self.owner, '1', b'changed')
        self.core.join(identifier, self.viewer)
        first = self.core.history(identifier, self.viewer)
        self.now += 1
        self.core.send(identifier, self.viewer, '2', b'cipher two')
        self.assertEqual(len(self.core.history(identifier, self.viewer, head=first['head'])['messages']), 1)
        self.assertEqual(self.core.history(identifier, self.viewer, after=first['head'])['messages'][0]['sequence'], 2)
        self.assertEqual(len(self.core.history(identifier, self.viewer)['messages']), 2)
        self.error('comment_rate_limited', self.core.send, identifier, self.owner, '3', b'next')

    def test_comments_disabled_for_owner_too(self):
        identifier = self.start(comments=False)
        self.core.join(identifier, self.viewer)
        for actor in (self.owner, self.viewer):
            self.error('comments_disabled', self.core.send, identifier, actor, 'id', b'encrypted')

    def test_block_removes_viewer_and_history_access(self):
        identifier = self.start()
        self.core.join(identifier, self.viewer)
        self.blocked.add('bob')
        self.assertEqual(self.core.info(identifier, self.owner)['viewers'], 0)
        self.error('stream_unavailable', self.core.history, identifier, self.viewer)

    def test_cleanup_is_durable_without_private_content(self):
        identifier = self.start()
        self.core.send(identifier, self.owner, 'id', b'PRIVATE CIPHER')
        generation = self.core.pending_cleanup()[0]
        self.error('stream_still_active', self.core.acknowledge_cleanup, generation)
        self.core.transition(identifier, self.owner, 'stop', 1)
        self.assertNotIn(b'PRIVATE TITLE', self.path.read_bytes())
        self.assertNotIn(b'PRIVATE CIPHER', self.path.read_bytes())
        self.assertEqual(self.core.pending_cleanup(), [generation])
        self.core.acknowledge_cleanup(generation)
        self.assertEqual(self.core.pending_cleanup(), [])

    def test_restart_never_restores_content_or_sessions(self):
        identifier = self.start()
        second = StreamSessions(self.path, lambda a, b: True, clock=lambda: self.now)
        try:
            self.assertEqual(second.discover(self.owner), [])
            self.assertEqual(len(second.pending_cleanup()), 1)
            self.error('stream_unavailable', second.info, identifier, self.owner)
        finally:
            second.close()

    def test_history_copy_and_bounds(self):
        identifier = self.start()
        self.core.send(identifier, self.owner, 'id', b'encrypted')
        result = self.core.history(identifier, self.owner)
        result['messages'][0]['ciphertext'] = b'changed'
        self.assertEqual(self.core.history(identifier, self.owner)['messages'][0]['ciphertext'], b'encrypted')
        for args in ({'after': -1}, {'limit': True}, {'head': 'x'}):
            self.error('invalid_cursor', self.core.history, identifier, self.owner, **args)


class StreamRetryAndResourceTests(unittest.TestCase):
    setUp = StreamSessionsTests.setUp
    start = StreamSessionsTests.start
    error = StreamSessionsTests.error

    def test_start_retry_and_settings_conflict(self):
        identifier = self.start(request_id='attempt')
        self.assertEqual(self.start(request_id='attempt'), identifier)
        self.error('stream_request_conflict', self.core.start, self.owner,
                   title='changed', request_id='attempt')
        self.error('stream_already_active', self.start, request_id='different')

    def test_global_capacity_and_release(self):
        self.core.limits = StreamLimits(streams=1)
        identifier = self.start()
        self.error('stream_capacity', self.core.start, ('other', 'phone'), title='title')
        self.core.transition(identifier, self.owner, 'stop', 1)
        self.core.start(('other', 'phone'), title='title')

    def test_rate_budget_survives_viewer_churn_and_pause(self):
        identifier = self.start()
        self.core.join(identifier, self.viewer)
        self.core.send(identifier, self.viewer, 'one', b'encrypted')
        self.core.leave(identifier, self.viewer)
        self.core.join(identifier, ('new', 'phone'))
        self.error('comment_rate_limited', self.core.send, identifier, ('new', 'phone'), 'two', b'encrypted')
        self.core.transition(identifier, self.owner, 'pause', 1)
        self.now += 1
        self.core.send(identifier, self.owner, 'two', b'encrypted')
        self.assertEqual(len(self.core.history(identifier, self.owner)['messages']), 2)

    def test_invalid_message_never_enters_history(self):
        identifier = self.start()
        for message in (b'', b'x' * 8193, 'plaintext', None):
            self.error('invalid_message', self.core.send, identifier, self.owner, 'id', message)
        self.assertEqual(self.core.history(identifier, self.owner)['messages'], [])

    def test_old_device_cannot_read_after_lease_expiry_and_rejoin(self):
        identifier = self.start()
        self.core.join(identifier, self.viewer)
        self.now += 60
        self.core.join(identifier, ('bob', 'other'))
        self.error('stream_join_required', self.core.history, identifier, self.viewer)

    def test_finish_drops_content_references(self):
        identifier = self.start(audience=['bob'])
        self.core.send(identifier, self.owner, 'id', b'encrypted')
        session = self.core.sessions[identifier]
        self.core.transition(identifier, self.owner, 'stop', 1)
        self.assertEqual(session.title, '')
        self.assertEqual(session.audience, frozenset())
        self.assertEqual(session.messages, [])
        self.assertEqual(session.message_ids, {})

    def test_stop_resume_race_is_terminal(self):
        identifier = self.start()
        self.core.transition(identifier, self.owner, 'pause', 1)
        def action(name):
            try:
                return self.core.transition(identifier, self.owner, name, 2)
            except StreamError as error:
                return str(error)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(action, ['stop', 'resume']))
        if identifier in self.core.sessions:
            self.core.transition(identifier, self.owner, 'stop', 3)
        self.assertNotIn(identifier, self.core.sessions)

    def test_start_retry_after_stop_never_creates_new_stream(self):
        identifier = self.start(request_id='attempt')
        self.core.transition(identifier, self.owner, 'stop', 1)
        self.error('stream_unavailable', self.start, request_id='attempt')
        self.assertEqual(self.core.discover(self.owner), [])

    def test_surrogate_settings_are_rejected(self):
        self.error('invalid_settings', self.core.start, self.owner, title='\ud800')


if __name__ == '__main__':
    unittest.main()


class StreamMigrationTests(unittest.TestCase):
    def test_old_cleanup_only_database_migrates_without_losing_retirement(self):
        import sqlite3
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'cleanup.sqlite'
            with sqlite3.connect(path) as db:
                db.execute('CREATE TABLE stream_cleanup (generation TEXT PRIMARY KEY)')
                db.execute("INSERT INTO stream_cleanup VALUES('retire-me')")
            core = StreamSessions(path, lambda a, b: True)
            try:
                self.assertEqual(core.pending_cleanup(), ['retire-me'])
                self.assertEqual(core.db.execute('SELECT version FROM stream_schema').fetchone(), (1,))
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            finally:
                core.close()

    def test_future_schema_rejected_without_mutation(self):
        import sqlite3
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'cleanup.sqlite'
            with sqlite3.connect(path) as db:
                db.execute('CREATE TABLE stream_schema (singleton INTEGER PRIMARY KEY, version INTEGER)')
                db.execute('INSERT INTO stream_schema VALUES(1,2)')
            with self.assertRaisesRegex(ValueError, 'unsupported_stream_schema'):
                StreamSessions(path, lambda a, b: True)
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute('SELECT version FROM stream_schema').fetchone(), (2,))
                self.assertIsNone(db.execute("SELECT name FROM sqlite_master WHERE name='stream_cleanup'").fetchone())
