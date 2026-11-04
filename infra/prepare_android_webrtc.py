"""Prepare the checksum-pinned native SDK as a local Maven repository."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlsplit
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent.parent
MAX_AAR_BYTES = 300 * 1024 * 1024


def prepare(manifest, cache):
    version = manifest['release_artifact_version']
    artifact = manifest['artifacts']['android']
    expected = artifact['sha256']
    size = artifact['size_bytes']
    if not isinstance(version, str) or not re.fullmatch(r'[0-9][0-9A-Za-z.-]{0,63}', version):
        raise ValueError('Invalid native SDK version')
    if not isinstance(expected, str) or not re.fullmatch(r'[a-f0-9]{64}', expected):
        raise ValueError('Invalid native SDK checksum')
    if type(size) is not int or not 1 <= size <= MAX_AAR_BYTES:
        raise ValueError('Invalid native SDK size')
    url = urlsplit(artifact['url'])
    if (url.scheme != 'https' or url.netloc != 'github.com' or url.query or url.fragment
            or url.path != f'/kerbermeister/voicechat/releases/download/webrtc-sdk-{version}/libwebrtc.aar'):
        raise ValueError('Unexpected native SDK release origin')
    repository = cache / expected / 'maven'
    directory = repository / 'io/github/webrtc-sdk/android' / version
    directory.mkdir(parents=True, exist_ok=True)
    aar = directory / f'android-{version}.aar'
    if aar.is_symlink():
        raise ValueError('Native SDK archive cannot be a symlink')
    if aar.exists():
        with aar.open('rb') as existing:
            valid = aar.stat().st_size == size and hashlib.file_digest(existing, 'sha256').hexdigest() == expected
        if not valid:
            raise ValueError('Cached native SDK does not match its reviewed checksum')
    else:
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=directory, delete=False) as target:
                temporary = Path(target.name)
                digest = hashlib.sha256()
                received = 0
                with urlopen(artifact['url'], timeout=60) as response:
                    while chunk := response.read(1024 * 1024):
                        received += len(chunk)
                        if received > size:
                            raise ValueError('Native SDK response exceeds the pinned size')
                        digest.update(chunk)
                        target.write(chunk)
                if received != size or digest.hexdigest() != expected:
                    raise ValueError('Downloaded native SDK does not match its reviewed checksum')
                target.flush()
                os.fsync(target.fileno())
            temporary.replace(aar)
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()
    # Exact coordinates replace both plugin dependencies without a second SDK copy.
    pom = directory / f'android-{version}.pom'
    if pom.is_symlink():
        raise ValueError('Native SDK metadata cannot be a symlink')
    metadata = f'''<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.github.webrtc-sdk</groupId>
  <artifactId>android</artifactId>
  <version>{version}</version>
  <packaging>aar</packaging>
</project>
'''
    if pom.exists():
        if pom.read_text() != metadata:
            raise ValueError('Cached native SDK metadata does not match its coordinates')
    else:
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', dir=directory, delete=False) as target:
                temporary = Path(target.name)
                target.write(metadata)
                target.flush()
                os.fsync(target.fileno())
            temporary.replace(pom)
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()
    return repository


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=ROOT / 'infra/webrtc-sdk.json')
    parser.add_argument('--cache', type=Path, default=ROOT / '.prototype/webrtc-sdk')
    args = parser.parse_args()
    print(prepare(json.loads(args.manifest.read_text()), args.cache).resolve())


if __name__ == '__main__':
    main()
