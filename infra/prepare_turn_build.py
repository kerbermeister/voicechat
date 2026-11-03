"""Prepare only pinned public coturn inputs for the isolated image build."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
from urllib.request import urlopen


def prepare(context):
    source = Path(__file__).parent
    manifest = json.loads((source / 'turn-source.json').read_text())
    revision = manifest['source_revision']
    if (not re.fullmatch(r'[0-9a-f]{40}', revision) or
            manifest['source_archive_url'] != 'https://codeload.github.com/coturn/coturn/tar.gz/' + revision or
            not re.fullmatch(r'coturn/coturn@sha256:[0-9a-f]{64}', manifest['base_image'])):
        raise ValueError('Pinned official coturn source and base image required')
    context.mkdir(parents=True, exist_ok=True)
    archive = context / 'source.tar.gz'
    if (not archive.is_file() or archive.stat().st_size > 5_000_000 or
            hashlib.sha256(archive.read_bytes()).hexdigest() != manifest['source_sha256']):
        with urlopen(manifest['source_archive_url'], timeout=60) as response:
            data = response.read(5_000_001)
        if len(data) > 5_000_000 or hashlib.sha256(data).hexdigest() != manifest['source_sha256']:
            raise ValueError('Coturn archive checksum mismatch')
        archive.write_bytes(data)
    patch = source / 'turn-udp-eperm.patch'
    if hashlib.sha256(patch.read_bytes()).hexdigest() != manifest['patch_sha256']:
        raise ValueError('Coturn patch checksum mismatch')
    shutil.copyfile(patch, context / 'udp-eperm.patch')
    (context / 'checksums.txt').write_text(
        manifest['source_sha256'] + '  source.tar.gz\n' + manifest['patch_sha256'] + '  udp-eperm.patch\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--context', type=Path, required=True)
    parser.add_argument('--github-output', type=Path)
    args = parser.parse_args()
    manifest = prepare(args.context)
    if args.github_output:
        with args.github_output.open('a') as output:
            output.write('base_image=' + manifest['base_image'] + '\n')
    print(json.dumps({'base_image': manifest['base_image'], 'source_sha256': manifest['source_sha256'],
                      'patch_sha256': manifest['patch_sha256']}))


if __name__ == '__main__':
    main()
