"""Validate, package and atomically publish the manually requested Android release."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.request

REPO = Path(__file__).resolve().parents[1]
PACKAGE = 'dev.voicechat.voicechat_probe'
MAX_APK = 300 * 1024 * 1024


def sha256(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def version(repo=REPO):
    match = re.search(r'^version: ((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))\+([1-9]\d*)$',
                      (repo/'apps/client/pubspec.yaml').read_text(), re.M)
    if not match or int(match[2]) > 2100000000:
        raise ValueError('Invalid pubspec version')
    name, build = match[1], int(match[2])
    dart = (repo/'apps/client/lib/app_version.dart').read_text()
    if f"const appVersion = '{name}';" not in dart or f'const appBuild = {build};' not in dart:
        raise ValueError('app_version.dart differs from pubspec')
    history = (repo/'docs/app-changelog.md').read_text()
    section = re.search(r'^## '+re.escape(name)+r' \(сборка '+str(build)+r'\)[^\n]*\n(.*?)(?=^## |\Z)', history, re.M | re.S)
    if not section:
        raise ValueError('Changelog entry missing')
    notes = re.search(r'^### Что нового\n(.*?)(?=^### |\Z)', section[1], re.M | re.S)
    if not notes or not 1 <= len(notes[1].strip()) <= 4000:
        raise ValueError('Release notes missing or oversized')
    return name, build, notes[1].strip()


def validate_manifest(data):
    required = {'schema', 'applicationId', 'versionName', 'versionCode', 'minSdk', 'apkPath', 'sizeBytes', 'sha256', 'notes'}
    if not isinstance(data, dict) or set(data) != required:
        raise ValueError('Invalid manifest fields')
    for key in ('schema', 'versionCode', 'minSdk', 'sizeBytes'):
        if type(data[key]) is not int:
            raise ValueError('Invalid integer: '+key)
    if (data['schema'] != 1 or data['applicationId'] != PACKAGE or
        not 1 <= data['versionCode'] <= 2100000000 or not 1 <= data['minSdk'] <= 1000 or
        not 1 <= data['sizeBytes'] <= MAX_APK or
        not isinstance(data['versionName'], str) or not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', data['versionName']) or
        not isinstance(data['sha256'], str) or not re.fullmatch(r'[0-9a-f]{64}', data['sha256']) or
        not isinstance(data['notes'], str) or not 1 <= len(data['notes'].strip()) <= 4000 or
        data['apkPath'] != f"/updates/android/{data['versionCode']}/voicechat.apk"):
        raise ValueError('Invalid manifest values')
    return data


def load_manifest(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate manifest field')
            result[key] = value
        return result
    raw = Path(path).read_bytes()
    if len(raw) > 65536:
        raise ValueError('Oversized manifest')
    return validate_manifest(json.loads(raw, object_pairs_hook=unique))


def package(apk, tools, certificate, output, repo=REPO):
    name, build, notes = version(repo)
    certificate = certificate.lower()
    if not re.fullmatch(r'[a-f0-9]{64}', certificate):
        raise ValueError('Expected signing certificate SHA-256 is required')
    signed = subprocess.check_output([str(tools/'apksigner'), 'verify', '--verbose', '--print-certs', str(apk)], text=True)
    certs = re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([a-f0-9]+)$', signed, re.M)
    if certs != [certificate] or 'CN=Android Debug' in signed:
        raise ValueError('Unexpected signing certificate or debug key')
    badging = subprocess.check_output([str(tools/'aapt'), 'dump', 'badging', str(apk)], text=True)
    identity = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging, re.M)
    minimum = re.search(r"^sdkVersion:'(\d+)'", badging, re.M)
    abi = re.search(r'^native-code:(.*)$', badging, re.M)
    if (not identity or identity.groups() != (PACKAGE, str(build), name) or
        not minimum or 'application-debuggable' in badging or not abi or
        not all(f"'{a}'" in abi[1] for a in ('arm64-v8a', 'armeabi-v7a', 'x86_64'))):
        raise ValueError('APK identity, version, ABI or release mode mismatch')
    data = validate_manifest(dict(schema=1, applicationId=PACKAGE, versionName=name, versionCode=build,
        minSdk=int(minimum[1]), apkPath=f'/updates/android/{build}/voicechat.apk',
        sizeBytes=apk.stat().st_size, sha256=sha256(apk), notes=notes))
    if output.exists():
        raise ValueError('Output directory already exists')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.android-package-', dir=output.parent) as temporary:
        staging = Path(temporary)/'candidate'
        staging.mkdir()
        shutil.copyfile(apk, staging/'voicechat.apk')
        (staging/'latest.json').write_text(json.dumps(data, ensure_ascii=False)+'\n')
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
        dirty = bool(subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=normal'], cwd=repo, text=True))
        (staging/'release.json').write_text(json.dumps(dict(commit=commit, sourceDirty=dirty, expectedTag=f'app-v{name}+{build}',
            certificateSha256=certificate, apkSha256=data['sha256']), indent=2)+'\n')
        (staging/'verification.txt').write_text(signed)
        os.rename(staging, output)
    return data


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Redirects are forbidden for updates')


def verify_public(origin, data):
    from client_config import client_config
    origin = client_config(origin)['MATRIX_URL']
    if not origin.startswith('https://'):
        raise ValueError('Production updates require HTTPS')
    digest, size = hashlib.sha256(), 0
    request = urllib.request.Request(origin+data['apkPath'], headers={'Accept-Encoding': 'identity'})
    with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
        if response.status != 200 or response.headers.get_content_type() != 'application/vnd.android.package-archive':
            raise ValueError('Incorrect public APK response')
        while chunk := response.read(65536):
            size += len(chunk)
            if size > data['sizeBytes']:
                raise ValueError('Public APK too large')
            digest.update(chunk)
    if size != data['sizeBytes'] or digest.hexdigest() != data['sha256']:
        raise ValueError('Public APK does not match candidate')


def atomic_json(path, data):
    fd, temporary = tempfile.mkstemp(prefix='.manifest-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            json.dump(data, output, ensure_ascii=False)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def publish(candidate, root, origin, verify=verify_public):
    data = load_manifest(candidate/'latest.json')
    apk = candidate/'voicechat.apk'
    if apk.stat().st_size != data['sizeBytes'] or sha256(apk) != data['sha256']:
        raise ValueError('Candidate checksum mismatch')
    if not root.is_dir():
        raise ValueError('Run the full infrastructure deployment before publishing APKs')
    with (root/'.publish.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        releases = [load_manifest(p/'manifest.json') for p in root.iterdir() if p.is_dir() and p.name.isdecimal()]
        existing = next((r for r in releases if r['versionCode'] == data['versionCode']), None)
        if existing is not None:
            if existing != data:
                raise ValueError('Published build is immutable')
        elif releases:
            newest = max(releases, key=lambda r: r['versionCode'])
            if (data['versionCode'] <= newest['versionCode'] or
                tuple(map(int, data['versionName'].split('.'))) <= tuple(map(int, newest['versionName'].split('.')))):
                raise ValueError('Version and build must increase, including after withdrawal')
        destination = root/str(data['versionCode'])
        if existing is None:
            with tempfile.TemporaryDirectory(prefix='.upload-', dir=root) as temporary:
                staging = Path(temporary)/str(data['versionCode'])
                staging.mkdir(mode=0o755)
                shutil.copyfile(apk, staging/'voicechat.apk')
                os.chmod(staging/'voicechat.apk', 0o644)
                atomic_json(staging/'manifest.json', data)
                os.rename(staging, destination)
        if sha256(destination/'voicechat.apk') != data['sha256']:
            raise ValueError('Stored APK is corrupted')
        verify(origin, data)
        latest = root/'latest.json'
        if latest.exists():
            old = load_manifest(latest)
            if old == data: return
            if old['versionCode'] > data['versionCode']:
                raise ValueError('Use explicit withdraw to select an older release')
            atomic_json(root/'previous.json', old)
        atomic_json(latest, data)


def withdraw(root, origin):
    with (root/'.publish.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not (root/'previous.json').exists():
            os.replace(root/'latest.json', root/'withdrawn.json')
            return
        previous = load_manifest(root/'previous.json')
        verify_public(origin, previous)
        atomic_json(root/'latest.json', previous)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('check-version')
    pack = commands.add_parser('package')
    pack.add_argument('--apk', required=True, type=Path)
    pack.add_argument('--tools', required=True, type=Path)
    pack.add_argument('--certificate', required=True)
    pack.add_argument('--output', required=True, type=Path)
    pub = commands.add_parser('publish')
    pub.add_argument('--candidate', required=True, type=Path)
    for sub in (pub, commands.add_parser('withdraw')):
        sub.add_argument('--root', required=True, type=Path)
        sub.add_argument('--origin', required=True)
    args = parser.parse_args()
    if args.command == 'check-version': print('%s+%s' % version()[:2])
    elif args.command == 'package': package(args.apk, args.tools, args.certificate, args.output)
    elif args.command == 'publish': publish(args.candidate, args.root, args.origin)
    else: withdraw(args.root, args.origin)


if __name__ == '__main__': main()
