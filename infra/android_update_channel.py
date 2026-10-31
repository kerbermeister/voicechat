"""Locate APK channels from the managed baseline and verify the serving edge."""
import argparse
import json
import os
from pathlib import Path
import subprocess

import android_release
import edge_deploy
import entry_journal
import managed_journal
import managed_state
import node_inventory
import role_deploy
import role_release


def plan(root, origin):
    with managed_state.locked(root / 'coordinator'):
        _, baseline, _ = managed_journal.current(root)
        if baseline['public']['canonical_origin'] != origin:
            raise ValueError('Update origin differs from the managed installation')
        path = root / 'rollout.json'
        if path.exists():
            state = managed_state.read(path)
            if state['phase'] not in ('complete', 'rolled-back'):
                raise ValueError('Finish the managed operation before publishing updates')
        if (root / 'entry-lifecycle/current.json').exists():
            entry = entry_journal.load(root / 'entry-lifecycle')
            if entry['position'] != len(entry['steps']):
                raise ValueError('Finish the entry lifecycle before publishing updates')
        edges = []
        for edge in baseline['public']['edges']:
            identifier = edge['id']
            manifest = baseline['edges'][identifier]
            assignment = next(item for item in baseline['inventory']['edges'] if item['id'] == identifier)
            edges.append({'id': identifier, 'origin': edge['origin'],
                          'node': 'core' if assignment.get('host') == 'core' else 'edge-' + identifier,
                          'root': str(root / 'edges' / identifier),
                          'manifest': role_release.json_digest(manifest),
                          'owner': {key: manifest[key] for key in
                                    ('schema', 'service_id', 'role', 'edge_id', 'identity')}})
        return {'public': baseline['public'], 'inventory': baseline['inventory'], 'edges': edges}


def channel(target, *, execute=subprocess.check_output):
    root = Path(target['root'])
    if root.resolve() != root or root == Path('/'):
        raise ValueError('Canonical edge root required')
    if managed_state.read(root / 'role.json') != target['owner'] or target['owner']['role'] != 'edge':
        raise ValueError('Update channel belongs to another edge')
    state = edge_deploy.read_state(root, target['id'])
    if (state['pending'] is not None or state['current'] is None or
            role_release.json_digest(state['current']['manifest']) != target['manifest']):
        raise ValueError('Edge changed or is in maintenance; check the channel again')
    role_deploy.require_rollout_owner(root)
    path = root / 'runtime/android-updates'
    if (path.resolve() != path or not path.is_dir() or path.stat().st_uid != os.geteuid() or
            path.stat().st_mode & 0o022):
        raise ValueError('Existing protected edge APK directory required')
    # Verify the actual serving container, not just a rendered Compose file.
    ids = execute(['docker', 'ps', '-q', '--filter', 'label=com.docker.compose.project=voicechat-edge-' + target['id'],
                   '--filter', 'label=com.docker.compose.service=web']).decode().split()
    if len(ids) != 1:
        raise ValueError('Exactly one serving edge web container required')
    container = json.loads(execute(['docker', 'inspect', ids[0]]))[0]
    if (not container['State']['Running'] or not any(
            mount.get('Type') == 'bind' and Path(mount.get('Source', '')).resolve() == path and
            mount.get('Destination') == '/updates/android' and mount.get('RW') is False
            for mount in container['Mounts'])):
        raise ValueError('Serving edge must mount its APK channel read-only')
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('plan', 'check', 'publish'))
    parser.add_argument('--root', type=Path)
    parser.add_argument('--origin')
    parser.add_argument('--target', type=Path)
    parser.add_argument('--candidate', type=Path)
    args = parser.parse_args()
    if args.action == 'plan':
        result = plan(args.root, args.origin)
    else:
        target = json.loads(args.target.read_text())
        with managed_state.locked(Path(target['root'])):
            path = channel(target)
            if args.action == 'publish':
                data = android_release.load_manifest(args.candidate / 'latest.json')
                if (os.environ.get('ANDROID_ACCEPTED_BUILD') != str(data['versionCode']) or
                        os.environ.get('ANDROID_ACCEPTED_SHA256') != data['sha256']):
                    raise ValueError('Physical acceptance must identify the exact APK before promotion')
                android_release.publish(args.candidate, path, target['origin'])
            result = {'edge': target['id'], 'root': str(path), 'serving_mount_verified': True}
    print(json.dumps(result))


if __name__ == '__main__':
    main()
