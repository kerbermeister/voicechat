"""Проверки атомарной миграции и границы JSON, без сети и пользовательских данных."""
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
from call_control import CallStore
from screen_control import ScreenStore
from screen_protocol import parse_request, ScreenRequestError


class ScreenSchemaTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'calls.sqlite'

    def test_additive_migration_preserves_calls_and_terminal_state_on_restart(self):
        CallStore(self.path, lambda *_: None)
        with sqlite3.connect(self.path) as db:
            db.execute("INSERT INTO calls VALUES(1,'!room:x','session',0,'vc-old',0)")
        store = ScreenStore(self.path)
        with store.db() as db:
            db.execute("INSERT INTO screen_bindings VALUES('b','!room:x','s','group','ended',0,1)")
            db.execute("INSERT INTO screen_sessions(binding_id,state) VALUES('b','ended')")
        ScreenStore(self.path)
        with store.db() as db:
            self.assertEqual(db.execute('SELECT generation FROM calls').fetchone()[0], 'vc-old')
            self.assertEqual(db.execute('SELECT state FROM screen_sessions').fetchone()[0], 'ended')
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("UPDATE screen_bindings SET state='open',ended_at=NULL")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("UPDATE screen_sessions SET state='idle'")
            old_schema = db.execute("SELECT type,name,sql FROM sqlite_master WHERE name LIKE 'screen_%' ORDER BY name").fetchall()
        fresh = ScreenStore(self.path.with_name('fresh.sqlite'))
        with fresh.db() as db:
            fresh_schema = db.execute("SELECT type,name,sql FROM sqlite_master WHERE name LIKE 'screen_%' ORDER BY name").fetchall()
        self.assertEqual([tuple(r) for r in old_schema], [tuple(r) for r in fresh_schema])

    def test_failed_migration_rolls_back_all_new_tables(self):
        sql = Path(__file__).with_name('screen_schema.sql').read_text()
        with patch('screen_control.Path.read_text', return_value=sql.replace('COMMIT;', 'INVALID SQL;\nCOMMIT;')):
            with self.assertRaises(sqlite3.OperationalError):
                ScreenStore(self.path)
        with sqlite3.connect(self.path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'screen_%'").fetchone()[0], 0)
        ScreenStore(self.path)

    def test_schema_constraints_bind_owner_to_live_participant_and_reject_negative_revision(self):
        store = ScreenStore(self.path)
        with store.db() as db:
            db.execute("INSERT INTO screen_bindings VALUES('b','!r:x','s','direct','open',0,NULL)")
            for sql in [
                "INSERT INTO screen_sessions(binding_id,revision) VALUES('b',-1)",
                "INSERT INTO screen_sessions(binding_id,state) VALUES('b','active')",
                "INSERT INTO screen_sessions(binding_id,state,owner_identity,owner_lease_id,generation) VALUES('b','active','outsider','lease','screen-x')",
            ]:
                with self.subTest(sql=sql), self.assertRaises(sqlite3.IntegrityError):
                    db.execute(sql)

    def test_unknown_schema_version_is_not_downgraded(self):
        with sqlite3.connect(self.path) as db:
            db.execute('CREATE TABLE screen_schema(singleton INTEGER PRIMARY KEY,version INTEGER)')
            db.execute('INSERT INTO screen_schema VALUES(1,3)')
        with self.assertRaisesRegex(ValueError, 'unsupported_screen_schema'):
            ScreenStore(self.path)


class ScreenProtocolTests(unittest.TestCase):
    def test_all_wire_examples_are_accepted(self):
        examples = json.loads(Path(__file__).with_name('screen_protocol_fixtures.json').read_text())
        for operation, body in examples['requests'].items():
            with self.subTest(operation=operation):
                self.assertEqual(parse_request(operation.split('_')[0], json.dumps(body).encode()), body)

    def test_malformed_and_ambiguous_json_cannot_reach_business_logic(self):
        valid = {'protocol_version': 1, 'lease_id': 'a'*64,
                 'request_id': '11111111-1111-4111-8111-111111111111', 'expected_revision': 0}
        invalid = [b'', b' '*8193, b'\xff', b'[]', b'{"protocol_version":1,"protocol_version":2}',
                   json.dumps({**valid, 'expected_revision': True}).encode(),
                   json.dumps({**valid, 'expected_revision': 9007199254740992}).encode(),
                   json.dumps({**valid, 'protocol_version': True}).encode(),
                   json.dumps({**valid, 'actor_identity': 'spoofed'}).encode()]
        for raw in invalid:
            with self.subTest(raw=raw[:80]), self.assertRaisesRegex(ScreenRequestError, 'invalid_request'):
                parse_request('claim', raw)

    def test_transport_specific_bind_fields_are_not_interchangeable(self):
        base = {'protocol_version':1, 'room_id':'!r:x', 'call_session':'call-id-with-dashes'}
        for body in [dict(base, transport='group', peer={}), dict(base, transport='direct', call_lease_id='a'*64)]:
            with self.assertRaises(ScreenRequestError):
                parse_request('bind', json.dumps(body).encode())


if __name__ == '__main__':
    unittest.main()
