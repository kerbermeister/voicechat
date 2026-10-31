"""Publish one accepted APK to every current edge over existing pinned SSH."""
from contextlib import contextmanager
import io
import json
import re
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile

import host_connection
import node_inventory
from release_delivery import POLICIES
from ssh_deploy import connection

ROOT = Path(__file__).resolve().parents[1]


@contextmanager
def staged(ssh, candidate=None, target=None):
    directory = subprocess.check_output([*ssh, 'umask 077; mktemp -d /tmp/voicechat-android.XXXXXXXXXX'], timeout=30).decode().strip()
    if not re.fullmatch(r'/tmp/voicechat-android\.[A-Za-z0-9]{10}', directory):
        raise ValueError('Unexpected private staging directory')
    try:
        with tempfile.TemporaryFile() as archive:
            with tarfile.open(fileobj=archive, mode='w') as tar:
                paths = subprocess.check_output(['git', 'ls-files', '-z', 'infra'], cwd=ROOT).decode().split('\0')
                paths = set(filter(None, paths)) | {'infra/android_update_channel.py', 'infra/android_update_delivery.py'}
                paths |= {'prototype/' + name for name in POLICIES}
                for name in sorted(paths):
                    path = ROOT / name
                    if path.is_symlink() or not path.is_file():
                        raise ValueError('Only regular public deployment sources may be staged')
                    tar.add(path, arcname=name, recursive=False)
                if candidate is not None:
                    for name in ('voicechat.apk', 'latest.json'):
                        path = candidate / name
                        if path.is_symlink(): raise ValueError('Regular candidate files required')
                        tar.add(path, arcname='candidate/' + name)
                if target is not None:
                    raw = json.dumps(target).encode()
                    info = tarfile.TarInfo('target.json'); info.size = len(raw); info.mode = 0o600
                    tar.addfile(info, io.BytesIO(raw))
            archive.seek(0)
            subprocess.run([*ssh, shlex.join(['tar', '-xf', '-', '-C', directory])], stdin=archive, check=True, timeout=600)
        yield directory
    finally:
        subprocess.run([*ssh, shlex.join(['rm', '-rf', '--', directory])], check=True, timeout=30)


def invoke(ssh, directory, action, *args):
    command = ['python3', '-B', directory + '/infra/android_update_channel.py', action, *args]
    response = subprocess.check_output([*ssh, shlex.join(command)], timeout=600)
    if len(response) > 65536: raise ValueError('Oversized update channel response')
    return json.loads(response)


def deliver(candidate=None, *, check=False, config=None):
    ssh, _, root = connection()
    origin = os.environ['PUBLIC_URL']
    with staged(ssh) as directory:
        plan = invoke(ssh, directory, 'plan', '--root', root, '--origin', origin)
    inventory = node_inventory.validate(plan['inventory'], plan['public'])
    if config is None:
        config = json.loads((candidate / 'client-config.json').read_text())
    from route_catalog import verify
    from android_release import NoRedirect
    import urllib.request
    with urllib.request.build_opener(NoRedirect).open(origin + '/.well-known/voicechat/routes.json', timeout=20) as response:
        catalog = verify(response.read(65537), config['ROUTE_CATALOG_KEY'], json.loads(config['ROUTE_CONFIG']))
    if catalog.topology != plan['public']:
        raise ValueError('Published signed routes differ from the current managed baseline')

    @contextmanager
    def edge_connection(target):
        if target['node'] == 'core':
            yield ssh
        else:
            with host_connection.connection(inventory, target['node'], Path.home() / '.ssh/id_ed25519') as command:
                yield command
    # Every edge must be ready before the first channel pointer is changed.
    results = []
    for target in plan['edges']:
        with edge_connection(target) as command, staged(command, target=target) as directory:
            results.append(invoke(command, directory, 'check', '--target', directory + '/target.json'))
    if not check:
        for target in plan['edges']:
            with edge_connection(target) as command, staged(command, candidate, target) as directory:
                # These acceptance identifiers are public metadata, never keys or tokens.
                prefix = ['env', 'ANDROID_ACCEPTED_BUILD=' + os.environ['ANDROID_ACCEPTED_BUILD'],
                          'ANDROID_ACCEPTED_SHA256=' + os.environ['ANDROID_ACCEPTED_SHA256']]
                arguments = [*prefix, 'python3', '-B', directory + '/infra/android_update_channel.py', 'publish',
                             '--target', directory + '/target.json', '--candidate', directory + '/candidate']
                subprocess.run([*command, shlex.join(arguments)], check=True, timeout=600)
                from android_release import NoRedirect, load_manifest
                import urllib.request
                with urllib.request.build_opener(NoRedirect).open(target['origin'] + '/updates/android/latest.json', timeout=20) as response:
                    if response.status != 200 or json.loads(response.read(65537)) != load_manifest(candidate / 'latest.json'):
                        raise ValueError('Published edge manifest differs from the accepted candidate')
    return results
