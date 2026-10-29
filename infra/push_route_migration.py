"""Core-maintenance primitive for existing Synapse HTTP pushers.

The caller must hold the core deployment lock, stop all Synapse/control writers,
verify a consistent backup, and restart Synapse after commit (its pusher cache is
in memory). This has no standalone production CLI. Pass a PostgreSQL DB-API
connection; the operation owns its transaction. No user tokens are read.
"""
import json

import managed_state
import node_inventory
import topology

APP_ID = 'dev.voicechat.web'
PATH = '/_matrix/push/v1/notify'


def routes(origin, private_ip):
    return topology.origin(origin) + PATH, 'http://' + node_inventory.ipv4(private_ip, tunnel=True) + ':8090' + PATH


def entries(rows, old_url, new_url):
    result = []
    seen = set()
    for identifier, raw in rows:
        if type(identifier) is not int or identifier < 0 or identifier in seen:
            raise ValueError('Invalid or duplicate pusher ID')
        seen.add(identifier)
        if not isinstance(raw, str) or len(raw) > 16384:
            raise ValueError('Invalid pusher data')
        value = json.loads(raw, object_pairs_hook=topology.unique_object)
        if not isinstance(value, dict): raise ValueError('Invalid pusher data object')
        if value.get('url') != old_url: continue
        after = json.dumps({**value, 'url': new_url}, separators=(',', ':'), allow_nan=False)
        result.append({'id': identifier, 'before': raw, 'after': after})
    return result


def validate(value, old_url, new_url):
    topology.fields(value, ('schema', 'old_url', 'new_url', 'entries', 'phase'))
    if (type(value['schema']) is not int or value['schema'] != 1 or
            value['old_url'] != old_url or value['new_url'] != new_url or
            value['phase'] not in ('prepared', 'applied', 'reverting', 'reverted') or
            not isinstance(value['entries'], list)):
        raise ValueError('Pusher migration journal belongs to another transition')
    for item in value['entries']: topology.fields(item, ('id', 'before', 'after'))
    expected = entries([(item['id'], item['before']) for item in value['entries']], old_url, new_url)
    if expected != value['entries']: raise ValueError('Pusher journal does not describe an exact URL-only change')
    return value


def migrate(connection, directory, origin, private_ip, *, rollback=False):
    """Commit exact URL changes; a crash after DB commit resumes idempotently.

    Rollback touches only recorded IDs and exact recorded data. Deleted pushers
    stay deleted; re-registered or independently changed rows are never replaced.
    The journal is private, contains IDs and data only, and is not a DB backup.
    """
    old_url, new_url = routes(origin, private_ip)
    return _migrate(connection, directory, old_url, new_url, rollback=rollback)


def restore_public(connection, directory, origin, private_ip):
    """Reverse the current private route on a full rollback, including new rows.

    Use a fresh journal directory for this stopped-writer maintenance step.
    Subscriptions created while the candidate served must also reach the public
    endpoint after legacy recovery. Preserve their current metadata and all
    unrelated destinations; never restore an old database or row snapshot.
    """
    public, private = routes(origin, private_ip)
    return _migrate(connection, directory, private, public)


def _migrate(connection, directory, old_url, new_url, *, rollback=False):
    with managed_state.locked(directory) as directory:
        path = directory / 'push-route.json'
        journal = validate(managed_state.read(path), old_url, new_url) if path.exists() or path.is_symlink() else None
        if rollback and journal is None: raise ValueError('No recorded pusher migration to reverse')
        if journal and journal['phase'] in ('reverting', 'reverted') and not rollback:
            raise ValueError('A reverted migration cannot be reused for another rollout')
        # PostgreSQL rolls the entire operation back on any conflict. The disk
        # intent is durable before the first UPDATE, including on a fresh run.
        with connection:
            with connection.cursor() as cursor:
                cursor.execute("SET LOCAL lock_timeout = '5s'")
                cursor.execute("SET LOCAL statement_timeout = '30s'")
                cursor.execute('LOCK TABLE pushers IN ACCESS EXCLUSIVE MODE')
                if journal is None:
                    cursor.execute('SELECT id, data FROM pushers WHERE app_id = %s AND kind = %s ORDER BY id', (APP_ID, 'http'))
                    journal = {'schema': 1, 'old_url': old_url, 'new_url': new_url,
                               'entries': entries(cursor.fetchall(), old_url, new_url), 'phase': 'prepared'}
                    managed_state.persist(path, journal)
                if rollback:
                    journal = {**journal, 'phase': 'reverting'}
                    managed_state.persist(path, journal)
                for item in journal['entries']:
                    cursor.execute('SELECT app_id, kind, data FROM pushers WHERE id = %s', (item['id'],))
                    row = cursor.fetchone()
                    if row is None: continue  # Never recreate a removed subscription.
                    source, target = (item['after'], item['before']) if rollback else (item['before'], item['after'])
                    if row[:2] != (APP_ID, 'http') or row[2] not in (source, target):
                        raise ValueError('Recorded pusher changed independently; refusing to overwrite it')
                    if row[2] != target:
                        cursor.execute('UPDATE pushers SET data = %s WHERE id = %s', (target, item['id']))
        managed_state.persist(path, {**journal, 'phase': 'reverted' if rollback else 'applied'})
    return len(journal['entries'])
