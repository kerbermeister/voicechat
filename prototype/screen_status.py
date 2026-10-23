"""Read-only счётчики для оператора; без identity, JWT, lease и медиаключей."""
import argparse
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import time


def status(path, now=None):
    now=time.time() if now is None else now
    with closing(sqlite3.connect(Path(path).resolve().as_uri()+'?mode=ro',uri=True)) as db:
        if not db.execute("SELECT 1 FROM sqlite_master WHERE name='screen_schema'").fetchone():
            return {'state':'uninitialized'}
        states=dict(db.execute('SELECT state,COUNT(*) FROM screen_sessions GROUP BY state'))
        pending,oldest=db.execute("SELECT COUNT(*),MIN(created_at) FROM screen_commands WHERE status='pending'").fetchone()
        return {'schema':db.execute('SELECT version FROM screen_schema').fetchone()[0],
                'sessions':states,'retired_rooms':db.execute('SELECT COUNT(*) FROM screen_retired').fetchone()[0],
                'pending_commands':pending,'oldest_pending_seconds':None if oldest is None else max(0,int(now-oldest/1000))}


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--database',type=Path,default=Path(__file__).resolve().parents[1]/'.prototype/calls/calls.sqlite')
    try:
        print(json.dumps(status(parser.parse_args().database)))
    except (OSError,sqlite3.Error):
        raise SystemExit('Screen metadata unavailable; check control initialization and volume permissions') from None
