"""Verify/package an arm64 macOS candidate; never publish or modify a profile."""
import argparse
import base64
import hashlib
import json
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)
MACH_MAGICS = {bytes.fromhex(value) for value in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True, stderr=subprocess.STDOUT).strip()


def sha256(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', value):
        raise ValueError('Invalid numeric version')
    return tuple(int(part) for part in value.split('.')) + (0,) * (3 - len(value.split('.')))


def validate_info(info, release=False):
    if info.get('CFBundleIdentifier') != 'dev.voicechat.client':
        raise ValueError('Unexpected bundle identifier')
    if not re.fullmatch(r'[1-9][0-9]*', str(info.get('CFBundleVersion', ''))):
        raise ValueError('Build must be a positive integer')
    version(info.get('CFBundleShortVersionString'))
    if version(info.get('LSMinimumSystemVersion')) != (12, 0, 0):
        raise ValueError('Review minimum macOS before changing the compatibility contract')
    for name in ('SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates', 'SUEnableSystemProfiling'):
        if info.get(name) is not False:
            raise ValueError('Automatic updates/telemetry must be explicitly disabled')
    if info.get('SURequireSignedFeed') is not True:
        raise ValueError('Signed appcast is required')
    if release:
        feed = urlsplit(info.get('SUFeedURL', ''))
        if (feed.scheme != 'https' or not feed.hostname or feed.username or feed.password
                or feed.query or feed.fragment or feed.path != '/updates/macos/appcast.xml'):
            raise ValueError('Invalid production feed URL')
        if len(base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)) != 32:
            raise ValueError('Invalid Sparkle public key')


def verify_app(app, release=False, team=None):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    validate_info(info, release)
    found = 0
    for path in app.rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as source:
            magic = source.read(4)
        if magic not in MACH_MAGICS:
            continue
        found += 1
        if 'arm64' not in run('lipo', '-archs', path).split():
            raise ValueError(f'Missing arm64: {path.relative_to(app)}')
        load = run('xcrun', 'vtool', '-arch', 'arm64', '-show-build', path)
        minimum = re.findall(r'\bminos\s+([0-9.]+)', load)
        if not minimum:
            load = run('otool', '-arch', 'arm64', '-l', path)
            minimum = re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)', load)
        if not minimum or any(version(item) > (12, 0, 0) for item in minimum):
            raise ValueError(f'Unknown or incompatible minimum macOS: {path.relative_to(app)}')
    if not found:
        raise ValueError('No native binaries found')
    run('codesign', '--verify', '--deep', '--strict', app)
    if release:
        if not team or not re.fullmatch(r'[A-Z0-9]{10}', team):
            raise ValueError('Expected Developer ID team is required')
        details = run('codesign', '-d', '--verbose=4', app)
        if f'TeamIdentifier={team}' not in details or 'Authority=Developer ID Application:' not in details or 'runtime' not in details:
            raise ValueError('Expected Developer ID signature and hardened runtime')
    return info


def create_feed(info, archive, signature, notes, previous=None):
    """Keep older compatible releases; increasing the OS floor must not strand them."""
    if previous:
        if len(previous) > 2 * 1024 * 1024 or b'<!DOCTYPE' in previous.upper() or b'<!ENTITY' in previous.upper():
            raise ValueError('Invalid previous feed')
        root = ET.fromstring(previous)
    else:
        root = ET.Element('rss', version='2.0')
        channel = ET.SubElement(root, 'channel')
        ET.SubElement(channel, 'title').text = 'VoiceChat macOS'
        ET.SubElement(channel, 'link').text = info['SUFeedURL']
        ET.SubElement(channel, 'description').text = 'Ручные обновления VoiceChat для macOS'
    channel = root.find('channel')
    if root.tag != 'rss' or channel is None:
        raise ValueError('Invalid appcast structure')
    build = info['CFBundleVersion']
    for enclosure in channel.findall('item/enclosure'):
        old = enclosure.get(f'{{{SPARKLE}}}version', '')
        if not old.isascii() or not old.isdigit() or int(old) >= int(build):
            raise ValueError('New build must exceed every published build')
    item = ET.Element('item')
    ET.SubElement(item, 'title').text = f"VoiceChat {info['CFBundleShortVersionString']} ({build})"
    ET.SubElement(item, 'description').text = notes
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = info['LSMinimumSystemVersion']
    prefix = info['SUFeedURL'].removesuffix('appcast.xml')
    ET.SubElement(item, 'enclosure', {
        'url': f'{prefix}{build}/VoiceChat.zip', 'length': str(archive.stat().st_size),
        'type': 'application/octet-stream', f'{{{SPARKLE}}}version': build,
        f'{{{SPARKLE}}}shortVersionString': info['CFBundleShortVersionString'],
        f'{{{SPARKLE}}}edSignature': signature,
    })
    channel.insert(3, item)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def package(args):
    info = verify_app(args.app, args.release, args.team)
    commit = run('git', '-C', ROOT, 'rev-parse', 'HEAD')
    dirty = bool(run('git', '-C', ROOT, 'status', '--porcelain', '--untracked-files=normal'))
    if args.release and dirty:
        raise ValueError('Release requires a clean revision')
    if args.output.exists():
        raise ValueError('Output already exists; use a new candidate directory')
    if args.release and not all((args.notary_profile, args.sparkle_bin, args.sparkle_key, args.notes)):
        raise ValueError('Release needs notarization profile, Sparkle tools/key and release notes')
    args.output.mkdir(parents=True)
    # Work on a copy: stapling must not mutate the input .app or invalidate a build cache.
    with tempfile.TemporaryDirectory(prefix='voicechat-package-') as temporary:
        stage = Path(temporary)
        app = stage / 'VoiceChat.app'
        run('ditto', args.app, app)
        if args.release:
            notarize = stage / 'notarize.zip'
            run('ditto', '-c', '-k', '--keepParent', app, notarize)
            run('xcrun', 'notarytool', 'submit', notarize, '--keychain-profile', args.notary_profile, '--wait')
            run('xcrun', 'stapler', 'staple', app)
            run('xcrun', 'stapler', 'validate', app)
            run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
            notarize.unlink()
        archive = args.output / 'VoiceChat.zip'
        run('ditto', '-c', '-k', '--keepParent', app, archive)
        (stage / 'Applications').symlink_to('/Applications')
        dmg = args.output / 'VoiceChat.dmg'
        run('hdiutil', 'create', '-volname', 'VoiceChat', '-srcfolder', stage, '-ov', '-format', 'UDZO', dmg)
        if args.release:
            run('xcrun', 'notarytool', 'submit', dmg, '--keychain-profile', args.notary_profile, '--wait')
            run('xcrun', 'stapler', 'staple', dmg)
            run('xcrun', 'stapler', 'validate', dmg)
    previous = args.previous_feed.read_bytes() if args.previous_feed else None
    if args.release:
        # Validate before invoking Sparkle: malformed-key errors can echo private input.
        secret = base64.b64decode(args.sparkle_key.read_text().strip(), validate=True)
        if len(secret) not in (32, 96):
            raise ValueError('Unsupported Sparkle private key format')
        signer = args.sparkle_bin / 'sign_update'
        if previous:
            run(signer, '--ed-key-file', args.sparkle_key, '--verify', args.previous_feed)
        signature = run(signer, '--ed-key-file', args.sparkle_key, '-p', archive)
        # Verify against the public key embedded in this app, not just the signing key.
        run('swift', ROOT / 'infra/verify_macos_signature.swift', info['SUPublicEDKey'], signature, archive)
        feed = args.output / 'appcast.xml'
        feed.write_bytes(create_feed(info, archive, signature, args.notes.read_text(), previous))
        run(signer, '--ed-key-file', args.sparkle_key, feed)
        run(signer, '--ed-key-file', args.sparkle_key, '--verify', feed)
    manifest = {'commit': commit, 'sourceDirty': dirty, 'distributable': args.release,
                'build': info['CFBundleVersion'], 'version': info['CFBundleShortVersionString'],
                'minimumOS': info['LSMinimumSystemVersion'], 'architecture': 'arm64',
                'feedURL': info.get('SUFeedURL'),
                'previousFeedSha256': hashlib.sha256(previous).hexdigest() if previous else None,
                'files': {p.name: sha256(p) for p in args.output.iterdir() if p.is_file()}}
    (args.output / 'release.json').write_text(json.dumps(manifest, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--release', action='store_true')
    parser.add_argument('--team')
    parser.add_argument('--notary-profile')
    parser.add_argument('--sparkle-bin', type=Path)
    parser.add_argument('--sparkle-key', type=Path)
    parser.add_argument('--notes', type=Path)
    parser.add_argument('--previous-feed', type=Path)
    args = parser.parse_args()
    try:
        package(args)
    except subprocess.CalledProcessError as error:
        # Tool output may contain signing credentials; report only the executable/status.
        raise SystemExit(f'{Path(error.cmd[0]).name} failed ({error.returncode}); candidate is incomplete') from None


if __name__ == '__main__':
    main()
