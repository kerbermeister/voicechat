import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
import push_route_migration as migration


class PushRouteTests(unittest.TestCase):
    def setUp(self):
        self.old, self.new = migration.routes('https://chat.example', '10.88.0.1')

    def test_changes_only_exact_origin_preserving_all_payload_fields(self):
        raw = json.dumps({'url': self.old, 'format': 'event_id_only', 'extra': {'value': "a'b"}})
        rows = [(7, raw), (8, json.dumps({'url': self.old + '?other=1'})),
                (9, json.dumps({'url': self.new}))]
        result = migration.entries(rows, self.old, self.new)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['id'], 7)
        self.assertEqual(result[0]['before'], raw)
        self.assertEqual(json.loads(result[0]['after']), {**json.loads(raw), 'url': self.new})

    def test_invalid_data_and_duplicate_ids_fail_before_a_migration(self):
        for rows in ([(True, '{}')], [(1, '{}'), (1, '{}')], [(1, '[]')],
                     [(1, '{"url":"a","url":"b"}')], [(1, 'broken')]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                migration.entries(rows, self.old, self.new)

    def test_journal_rejects_other_destination_and_non_url_changes(self):
        items = migration.entries([(1, json.dumps({'url': self.old, 'format': 'event_id_only'}))], self.old, self.new)
        value = {'schema': 1, 'old_url': self.old, 'new_url': self.new, 'entries': items, 'phase': 'prepared'}
        self.assertEqual(migration.validate(value, self.old, self.new), value)
        with self.assertRaises(ValueError): migration.validate(value, self.old, 'http://10.88.0.2:8090' + migration.PATH)
        items[0]['after'] = json.dumps({'url': self.new, 'format': 'changed'})
        with self.assertRaises(ValueError): migration.validate(value, self.old, self.new)

    def test_destination_must_be_private_ipv4_and_origin_canonical(self):
        for origin, ip in [('http://chat.example', '10.88.0.1'), ('https://chat.example/path', '10.88.0.1'),
                           ('https://chat.example', '8.8.8.8'), ('https://chat.example', '127.0.0.1')]:
            with self.subTest(origin=origin, ip=ip), self.assertRaises(ValueError): migration.routes(origin, ip)


if __name__ == '__main__': unittest.main()
