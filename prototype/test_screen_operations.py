"""Backup metadata не возрождает capture; диагностика read-only и без секретов."""
import json
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest
from uuid import uuid4
from call_control import CallStore
from screen_control import ScreenStore
from screen_transitions import ScreenTransitions
from screen_status import status

class ScreenOperationsTests(unittest.TestCase):
    def test_sqlite_backup_restore_annuls_leases_and_keeps_previous_call_data(self):
        with tempfile.TemporaryDirectory() as directory:
            original,restored=(Path(directory)/name for name in ('original.sqlite','restored.sqlite'))
            CallStore(original,lambda *_:None)
            store=ScreenStore(original)
            with store.db() as db:
                db.execute("INSERT INTO calls VALUES(1,'!voice:x','voice',0,'vc-existing',0)")
            a={'user_id':'@a:x','device_id':'A'};b={'user_id':'@b:x','device_id':'B'}
            keys={'@a:x/A':('curve-a','ed-a'),'@b:x/B':('curve-b','ed-b')}
            request={'room_id':'!screen:x','call_session':'session','transport':'direct'}
            bound=store.bind(a,{**request,'peer':b},keys)
            store.bind(b,{**request,'peer':a},keys)
            with store.db() as db:
                revision=db.execute('SELECT revision FROM screen_sessions').fetchone()[0]
            ScreenTransitions(store,lambda *_:None).command('claim',a,bound['binding_id'],bound['lease_id'],keys,str(uuid4()),revision)
            with store.db() as source, closing(sqlite3.connect(restored)) as target: source.backup(target)
            recovered=ScreenStore(restored)
            recovered.recover()
            deleted=[]
            ScreenTransitions(recovered,lambda method,body:deleted.append((method,body))).recover()
            self.assertTrue(deleted)
            before=restored.read_bytes()
            report=status(restored)
            self.assertEqual(report['schema'],2)
            self.assertEqual(report['sessions'],{'ended':1})
            self.assertEqual(report['retired_rooms'],0)
            self.assertNotIn('identity',json.dumps(report))
            self.assertEqual(restored.read_bytes(),before)
            with recovered.db() as db:
                self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0],'ok')
                self.assertEqual(db.execute('SELECT generation FROM calls').fetchone()[0],'vc-existing')
                self.assertEqual(db.execute('SELECT COUNT(*) FROM screen_participants').fetchone()[0],0)
