"""Deliver a validated Android candidate using the existing pinned SSH identity."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import uuid
from android_release import load_manifest
from ssh_deploy import connection


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('candidate', type=Path)
    args = parser.parse_args()
    data = load_manifest(args.candidate/'latest.json')
    if os.environ.get('ANDROID_ACCEPTED_BUILD') != str(data['versionCode']):
        raise SystemExit('Physical Android acceptance for this build is required before publication')
    if os.environ.get('ANDROID_ACCEPTED_SHA256') != data['sha256']:
        raise SystemExit('Acceptance must match the exact APK checksum')
    ssh, target, root = connection()
    staging = root+'/runtime/android-candidate-'+uuid.uuid4().hex
    subprocess.run([*ssh, 'mkdir -m 700 '+shlex.quote(staging)], check=True)
    try:
        sources = [args.candidate/'voicechat.apk', args.candidate/'latest.json',
                   Path('infra/android_release.py'), Path('infra/client_config.py')]
        subprocess.run(['scp', '-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes',
                        *map(str, sources), target+':'+staging+'/'], check=True)
        command = ['python3', staging+'/android_release.py', 'publish', '--candidate', staging,
                   '--root', root+'/runtime/android-updates', '--origin', os.environ['PUBLIC_URL']]
        subprocess.run([*ssh, shlex.join(command)], check=True)
        # Verify the exact promoted manifest through HTTPS as well as its APK.
        import urllib.request
        from android_release import NoRedirect
        with urllib.request.build_opener(NoRedirect).open(os.environ['PUBLIC_URL']+'/updates/android/latest.json', timeout=15) as response:
            if response.status != 200 or json.loads(response.read(65537)) != data:
                raise RuntimeError('Public latest.json differs after promotion')
    finally:
        # Only these generated files and our unique staging directory are removed.
        command = ['rm', '-f', *[staging+'/'+name for name in ('voicechat.apk', 'latest.json', 'android_release.py', 'client_config.py')]]
        subprocess.run([*ssh, shlex.join(command)+' && rm -rf '+shlex.quote(staging+'/__pycache__')+' && rmdir '+shlex.quote(staging)], check=True)


if __name__ == '__main__': main()
