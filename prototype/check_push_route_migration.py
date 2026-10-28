"""Real PostgreSQL transaction probe; run only in a disposable fixture database.

Use the pinned Synapse image's psycopg2 and normal libpq PG* environment variables.
PGDATABASE must start with voicechat_push_migration_fixture_. Existing pushers
cause CREATE TABLE to fail before any writes. The caller removes the database.
No user credentials, messages or production subscriptions are used.
"""
import json, time, tempfile, sys, os
from pathlib import Path
from unittest.mock import patch
import psycopg2
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
import push_route_migration as migration, managed_state

def main():
    if not os.environ.get('PGDATABASE', '').startswith('voicechat_push_migration_fixture_'):
        raise SystemExit('An explicitly named disposable PostgreSQL fixture database is required')
    for attempt in range(60):
        try:
            db = psycopg2.connect(connect_timeout=2)
            break
        except psycopg2.OperationalError:
            time.sleep(1)
    else:
        raise RuntimeError('Fixture database not ready')
    old, new = migration.routes('https://chat.example', '10.88.0.1')
    data = json.dumps({'url': old, 'format': 'event_id_only', 'extra': "preserve ' quotes"})
    with db:
        with db.cursor() as cur:
            cur.execute('CREATE TABLE pushers(id BIGINT PRIMARY KEY, app_id TEXT, kind TEXT, data TEXT, last_stream_ordering BIGINT, pushkey TEXT, enabled BOOLEAN)')
            for i, app, kind in [(1, migration.APP_ID, 'http'), (2, 'another.app', 'http'), (3, migration.APP_ID, 'email'), (5, migration.APP_ID, 'http'), (6, migration.APP_ID, 'http')]:
                cur.execute('INSERT INTO pushers VALUES (%s,%s,%s,%s,%s,%s,%s)', (i, app, kind, data, 900 + i, 'synthetic-' + str(i), True))

    def rows():
        with db:
            with db.cursor() as cur:
                cur.execute('SELECT * FROM pushers ORDER BY id')
                return cur.fetchall()

    def write(sql, params):
        with db:
            with db.cursor() as cur:
                cur.execute(sql, params)
    before = rows()
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp) / 'journal'
        original = managed_state.persist

        def crash_after_commit(path, value):
            if value.get('phase') == 'applied':
                raise OSError('Injected interruption after DB commit')
            original(path, value)
        with patch.object(managed_state, 'persist', side_effect=crash_after_commit):
            try:
                migration.migrate(db, directory, 'https://chat.example', '10.88.0.1')
            except OSError:
                pass
            else:
                raise AssertionError('Expected interruption')
        assert managed_state.read(directory / 'push-route.json')['phase'] == 'prepared'
        assert migration.migrate(db, directory, 'https://chat.example', '10.88.0.1') == 3
        after = rows()
        for previous, current in zip(before, after):
            assert previous[:3] == current[:3] and previous[4:] == current[4:]
            if previous[0] in (1, 5, 6):
                assert json.loads(current[3]) == {**json.loads(previous[3]), 'url': new}
            else:
                assert previous == current
        assert migration.migrate(db, directory, 'https://chat.example', '10.88.0.1') == 3 and rows() == after
        write('DELETE FROM pushers WHERE id=%s', (1,))
        write('UPDATE pushers SET data=%s WHERE id=%s', ('independent change', 6))
        conflicted = rows()
        try:
            migration.migrate(db, directory, 'https://chat.example', '10.88.0.1', rollback=True)
        except ValueError:
            pass
        else:
            raise AssertionError('Conflicting rollback must fail')
        assert rows() == conflicted, 'Earlier row update must roll back with later conflict'
        write('UPDATE pushers SET data=%s WHERE id=%s', (after[-1][3], 6))
        migration.migrate(db, directory, 'https://chat.example', '10.88.0.1', rollback=True)
        assert rows() == [row for row in before if row[0] != 1]
        migration.migrate(db, directory, 'https://chat.example', '10.88.0.1', rollback=True)
        assert rows() == [row for row in before if row[0] != 1]
        try:
            migration.migrate(db, directory, 'https://chat.example', '10.88.0.1')
        except ValueError:
            pass
        else:
            raise AssertionError('Reverted operation cannot silently reapply')
    print(json.dumps({'schema': 1, 'postgres_transaction_proof': True, 'url_only_change': True, 'foreign_pushers_unchanged': True, 'commit_crash_resumed': True, 'rollback_conflict_atomic': True, 'deleted_subscription_not_recreated': True, 'repeat_idempotent': True, 'limits': ['Synthetic PostgreSQL pusher table matching inspected Synapse columns; not a full production migration.', 'Caller must enforce stopped writers, verified backup and Synapse restart; core orchestration not yet wired.']}))
if __name__ == '__main__':
    main()
