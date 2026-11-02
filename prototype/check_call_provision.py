"""Compare CallStore management RPC counts with a trusted local Git revision.

Temporary SQLite, fake clock and SFU; this measures RPC calls, not wire/CPU/media.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from call_control import CallStore


def measure(store_type):
    now, rooms, operations = [1000.], set(), []
    def media(method, body):
        operations.append(method)
        if method == 'CreateRoom': rooms.add(body['name'])
        elif method == 'DeleteRoom': rooms.discard(body['room'])
        elif method == 'ListRooms':
            return {'rooms': [{'name': name} for name in rooms & set(body['names'])]}
        else: raise AssertionError(method)
    with tempfile.TemporaryDirectory() as folder:
        store = store_type(Path(folder) / 'calls.sqlite', media, lambda: now[0])
        def admit(group, peer, lease=None):
            return store.admission(f'!qa{group}:local', 'call', False,
                {'user_id': f'@qa{group}_{peer}:local', 'device_id': 'D'},
                'synthetic-curve', 'synthetic-ed', lease=lease)
        for group in range(10):
            for peer in range(10):
                try: admit(group, peer)
                except ValueError as error:
                    assert str(error) == 'generation_settling'
                else: raise AssertionError('Join should settle')
        now[0] += 1
        grants = {(group, peer): admit(group, peer) for group in range(10) for peer in range(10)}
        operations.clear()
        for _ in range(20):
            now[0] += 3
            for (group, peer), grant in grants.items():
                renewed = admit(group, peer, grant['lease_id'])
                assert renewed['generation'] == grant['generation']
                assert len(renewed['roster']) == 10
            if hasattr(store, 'reconcile'):
                store.reconcile()
        return dict(Counter(operations))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='app-v1.19.2+50')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = subprocess.check_output(['git', 'show', args.baseline + ':prototype/call_control.py'],
                                     cwd=root, text=True)
    namespace = {}
    exec(compile(source, '<trusted Git CallStore>', 'exec'), namespace)
    before = measure(namespace['CallStore'])
    after = measure(CallStore)
    assert before == {'CreateRoom': 200}, before
    assert after == {'ListRooms': 20}, after
    print(json.dumps({
        'baseline': args.baseline, 'groups': 10, 'participants_per_group': 10,
        'heartbeat_rounds': 20, 'interval_seconds': 3,
        'before': before, 'after': after,
        'candidate_call_control_sha256': hashlib.sha256((root / 'prototype/call_control.py').read_bytes()).hexdigest(),
        'scope': 'management RPC counts on temporary SQLite/fake SFU, not wire/CPU/media',
        'generations_and_roster_unchanged': True,
    }, indent=2))


if __name__ == '__main__':
    main()
