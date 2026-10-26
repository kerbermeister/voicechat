"""Promote an accepted, signed candidate on the update host (no build or deploy)."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def publish(candidate, root, origin, accepted_build, accepted_sha):
    manifest = json.loads((candidate / 'release.json').read_text())
    build = manifest['build']
    if not isinstance(build, str) or not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('Invalid build')
    if (manifest.get('distributable') is not True or manifest.get('sourceDirty') is not False
            or manifest.get('architecture') != 'arm64'):
        raise ValueError('A clean, signed release candidate is required')
    files = manifest['files']
    if set(files) != {'VoiceChat.zip', 'VoiceChat.dmg', 'appcast.xml'}:
        raise ValueError('Unexpected candidate files')
    if accepted_build != build or accepted_sha != files['VoiceChat.zip']:
        raise ValueError('Acceptance must identify the exact build and archive checksum')
    if manifest['feedURL'] != origin.rstrip('/') + '/updates/macos/appcast.xml':
        raise ValueError('Candidate belongs to another update origin')
    for name, expected in files.items():
        path = candidate / name
        if path.is_symlink() or digest(path) != expected:
            raise ValueError('Candidate checksum mismatch')
    feed = (candidate / 'appcast.xml').read_bytes()
    if len(feed) > 2 * 1024 * 1024 or b'<!DOCTYPE' in feed.upper() or b'<!ENTITY' in feed.upper():
        raise ValueError('Invalid feed')
    entries = ET.fromstring(feed).findall('channel/item/enclosure')
    matching = [item for item in entries if item.get(f'{{{SPARKLE}}}version') == build]
    if (len(matching) != 1 or matching[0].get('url') != origin.rstrip('/') + f'/updates/macos/{build}/VoiceChat.zip'
            or matching[0].get('length') != str((candidate / 'VoiceChat.zip').stat().st_size)
            or not matching[0].get(f'{{{SPARKLE}}}edSignature')):
        raise ValueError('Feed does not identify the accepted archive')
    root.mkdir(parents=True, exist_ok=True)
    with (root / '.publish.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = root / 'appcast.xml'
        current_hash = digest(current) if current.exists() else None
        # Safe retry after a successful promotion, with immutable artifacts rechecked.
        retry = current_hash == files['appcast.xml']
        if not retry and current_hash != manifest.get('previousFeedSha256'):
            raise ValueError('Feed changed since candidate preparation; rebuild the signed feed')
        destination = root / build
        published_builds = [int(path.name) for path in root.iterdir()
                            if path.is_dir() and re.fullmatch(r'[1-9][0-9]*', path.name)]
        if not destination.exists() and published_builds and int(build) <= max(published_builds):
            raise ValueError('Build must exceed every previously published build, including revoked releases')
        if destination.exists():
            for name in ('VoiceChat.zip', 'VoiceChat.dmg'):
                if digest(destination / name) != files[name]:
                    raise ValueError('Published build numbers are immutable')
        else:
            with tempfile.TemporaryDirectory(prefix='.candidate-', dir=root) as temporary:
                stage = Path(temporary) / build
                stage.mkdir(mode=0o755)
                for name in ('VoiceChat.zip', 'VoiceChat.dmg'):
                    shutil.copyfile(candidate / name, stage / name)
                    (stage / name).chmod(0o644)
                    with (stage / name).open('rb') as artifact:
                        os.fsync(artifact.fileno())
                    if digest(stage / name) != files[name]:
                        raise ValueError('Staged archive changed during copy')
                os.rename(stage, destination)
        if retry:
            return
        # The feed becomes visible only after both archives exist at their final URLs.
        fd, temporary = tempfile.mkstemp(prefix='.appcast-', dir=root)
        try:
            with os.fdopen(fd, 'wb') as output:
                output.write(feed)
                output.flush()
                os.fsync(output.fileno())
                os.fchmod(output.fileno(), 0o644)
            os.replace(temporary, current)
            directory = os.open(root, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            Path(temporary).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--origin', required=True)
    args = parser.parse_args()
    publish(args.candidate, args.root, args.origin,
            os.environ.get('MACOS_ACCEPTED_BUILD'), os.environ.get('MACOS_ACCEPTED_SHA256'))


if __name__ == '__main__':
    main()
