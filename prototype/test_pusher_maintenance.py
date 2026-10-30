from copy import deepcopy
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import core_deploy
import managed_state
import test_core_deploy


class PusherMaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_core_deploy.CoreDeployTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.deploy(self.fixture.old)
        self.root = self.fixture.root
        self.record = core_deploy.read_state(self.root)['current']
        self.identity = self.fixture.data_identity.copy()
        self.calls = []
        self.private = None
        self.writer_active = False
        self.replace_after = False
        self.postgres = {'id': '1' * 64, 'image': self.record['manifest']['images']['postgres'],
            'image_id': 'sha256:' + 'a' * 64,
            'labels': {'com.docker.compose.project': 'voicechat', 'com.docker.compose.service': 'postgres'},
            'mounts': [{'Destination': '/var/lib/postgresql/data', 'Type': 'volume', 'RW': True,
                        'Name': 'voicechat_postgres'}],
            'state': {'Running': True, 'Health': {'Status': 'healthy'}}, 'networks': {'voicechat_default': {}}}

    def execute(self, args, *, env=None, input=None):
        self.calls.append(args)
        if args[:2] == ['docker', 'ps']:
            return ('1' * 64 if args[-1].endswith('=postgres') else '2' * 64).encode()
        if args[:2] == ['docker', 'inspect']:
            return json.dumps(self.postgres if args[-1] == '1' * 64 else self.writer_active).encode()
        if args[:3] == ['docker', 'image', 'inspect']: return ('sha256:' + 'a' * 64).encode()
        if args[:3] == ['docker', 'volume', 'ls']:
            return args[-1].removeprefix('name=^').removesuffix('$').encode()
        if args[:2] == ['docker', 'run']:
            if '--interactive' in args:
                with self.assertRaises(BlockingIOError):
                    with managed_state.locked(self.root): pass
                self.private = input
                if self.replace_after: self.fixture.data_identity['postgres_system_identifier'] = '987654321'
                return b'{"updated":1}'
            if any('/data/homeserver.yaml' in arg for arg in args):
                return b'{"password":"synthetic-private-never-argv"}'
            if 'pg_controldata' in args:
                return ('Database system identifier: ' + self.fixture.data_identity['postgres_system_identifier'] + '\n').encode()
            return json.dumps({'server_name': self.fixture.public['matrix_server_name'],
                               'sha256': self.fixture.data_identity['signing_sha256']}).encode()
        return self.fixture.execute(args, env=env)

    def migrate(self, **kwargs):
        return core_deploy.migrate_push_routes(self.root, self.record, 'a' * 64,
            self.identity, execute=self.execute, **kwargs)

    def test_private_database_credential_uses_stdin_and_the_role_lock_covers_sql(self):
        before = (self.root / 'state.json').read_bytes()
        self.assertEqual(self.migrate(), 1)
        self.assertEqual(self.private, b'{"password":"synthetic-private-never-argv"}')
        self.assertNotIn('synthetic-private-never-argv', json.dumps(self.calls))
        driver = next(args for args in self.calls if '--interactive' in args)
        self.assertEqual(driver[driver.index('--network') + 1], 'voicechat_default')
        self.assertIn('--read-only', driver)
        self.assertIn('ALL', driver)
        self.assertEqual((self.root / 'state.json').read_bytes(), before)
        self.assertFalse(any('stop' in args or 'up' in args or 'pg_restore' in args for args in self.calls))

    def test_forward_and_current_row_reverse_have_distinct_private_journals(self):
        self.migrate()
        self.migrate(reverse=True)
        drivers = [args for args in self.calls if '--interactive' in args]
        self.assertEqual([args[-1] for args in drivers], ['forward', 'reverse'])
        mounts = [next(value for value in args if value.endswith(':/journal')) for args in drivers]
        self.assertNotEqual(*mounts)
        self.assertTrue(mounts[0].endswith('/forward:/journal'))
        self.assertTrue(mounts[1].endswith('/reverse:/journal'))

    def test_active_writer_prevents_secret_read_and_any_migration(self):
        self.writer_active = True
        with self.assertRaisesRegex(ValueError, 'Stop all Synapse/control'): self.migrate()
        self.assertIsNone(self.private)
        self.assertFalse((self.root / 'runtime/adoption-push').exists())

    def test_foreign_postgres_image_mount_and_network_fail_before_credential_read(self):
        original = deepcopy(self.postgres)
        for update in ({'image': 'mutable:tag'}, {'image_id': 'sha256:' + 'b' * 64},
                       {'networks': {'foreign': {}}}, {'mounts': []}):
            with self.subTest(update=update):
                self.postgres = {**original, **update}
                with self.assertRaisesRegex(ValueError, 'PostgreSQL image, data mount'): self.migrate()
                self.assertIsNone(self.private)

    def test_changed_data_identity_never_claims_migration_success(self):
        self.replace_after = True
        with self.assertRaisesRegex(ValueError, 'identity changed during'): self.migrate()
        self.assertEqual(core_deploy.read_state(self.root)['data_identity'], self.identity)

    def test_pending_backup_and_invalid_attempt_are_not_bypassed(self):
        managed_state.persist(self.root / 'runtime/backup.json', {'schema': 1})
        with self.assertRaisesRegex(ValueError, 'pending core backup'): self.migrate()
        self.assertEqual(self.calls, [])
        with self.assertRaisesRegex(ValueError, 'unique migration attempt'):
            core_deploy.migrate_push_routes(self.root, self.record, '../other', self.identity,
                                           execute=self.execute)
        self.assertEqual(self.calls, [])


if __name__ == '__main__': unittest.main()
