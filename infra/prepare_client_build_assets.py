"""Stage exact public build inputs through GitHub API, preserving upstream checks."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urljoin, urlsplit

ROOT = Path(__file__).resolve().parents[1]
RANGE_SIZE = 4 * 1024 * 1024


def valid(path, asset):
    if not path.is_file() or path.stat().st_size != asset['size']:
        return False
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() == asset['sha256']




def run_download(command, **kwargs):
    for attempt in range(3):
        output = kwargs.get('stdout')
        if output is not None:
            output.seek(0)
            output.truncate()
        try:
            return subprocess.run(command, **kwargs)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            status = re.search(rb'HTTP (\d{3})', error.stderr or b'')
            if attempt == 2 or (status and int(status[1]) not in (408, 429, 500, 502, 503, 504)):
                raise
            time.sleep(attempt + 1)


def download_range(asset, start, end, directory):
    response = run_download(
        ['gh', 'api', '--include', '-H', 'Accept: application/octet-stream',
         '-H', f'Range: bytes={start}-{end}',
         f"repos/{asset['repo']}/releases/assets/{asset['id']}"],
        capture_output=True, check=True, timeout=90).stdout
    header, separator, body = response.partition(b'\r\n\r\n')
    if not separator:
        header, separator, body = response.partition(b'\n\n')
    lines = header.decode('ascii').splitlines()
    ranges = [line.split(':', 1)[1].strip() for line in lines[1:]
              if line.lower().startswith('content-range:')]
    if (not separator or not lines or not re.match(r'^HTTP/\S+ 206(?: |$)', lines[0])
            or ranges != [f"bytes {start}-{end}/{asset['size']}"]
            or len(body) != end - start + 1):
        raise ValueError('Invalid build asset range response')
    part = directory / str(start)
    part.write_bytes(body)
    return part


def download(asset, output):
    if asset['size'] <= RANGE_SIZE:
        run_download(['gh', 'api', '-H', 'Accept: application/octet-stream',
                        f"repos/{asset['repo']}/releases/assets/{asset['id']}"],
                       stdout=output, check=True, timeout=180)
        return
    # Release-CDN streams can stall; parallel bounded ranges use the same asset.
    # Each range is checked, then fetch() verifies the whole upstream SHA again.
    with tempfile.TemporaryDirectory(dir=Path(output.name).parent) as temporary:
        directory = Path(temporary)
        offsets = range(0, asset['size'], RANGE_SIZE)
        with ThreadPoolExecutor(max_workers=6) as pool:
            parts = list(pool.map(lambda start: download_range(
                asset, start, min(start + RANGE_SIZE, asset['size']) - 1, directory), offsets))
        for part in parts:
            with part.open('rb') as stream:
                shutil.copyfileobj(stream, output)


def fetch(asset, cache):
    if (asset['repo'] not in ('gradle/gradle-distributions', 'simolus3/sqlite3.dart')
            or type(asset['id']) is not int or asset['id'] <= 0
            or not re.fullmatch(r'[a-zA-Z0-9_.-]+', asset['name'])
            or not re.fullmatch(r'[a-f0-9]{64}', asset['sha256'])
            or type(asset['size']) is not int or not 0 < asset['size'] <= 250_000_000):
        raise ValueError('Invalid pinned build asset')
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / (asset['sha256'] + '-' + asset['name'])
    if valid(target, asset):
        return target
    # gh handles API authentication and strips credentials on cross-host redirects.
    # Neither credentials nor package/profile directories belong in this cache.
    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as output:
        temporary = Path(output.name)
        try:
            download(asset, output)
            output.flush()
            if not valid(temporary, asset):
                raise ValueError('Build asset size or SHA-256 mismatch: ' + asset['name'])
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    return target


def stage(source, target, asset):
    if not valid(source, asset):
        raise ValueError('Cannot stage an unverified build asset')
    if valid(target, asset):
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            with source.open('rb') as stream:
                shutil.copyfileobj(stream, output)
            output.flush()
            if not valid(temporary, asset):
                raise ValueError('Staged build asset changed')
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)


def distribution_key(url):
    # Gradle PathAssembler hashes the complete distribution URI with base36 MD5.
    value = int.from_bytes(hashlib.md5(url.encode(), usedforsecurity=False).digest())
    key = ''
    while value:
        value, remainder = divmod(value, 36)
        key = '0123456789abcdefghijklmnopqrstuvwxyz'[remainder] + key
    return key or '0'


def prepare(client, cache, gradle_home, pins):
    if pins['schema'] != 1:
        raise ValueError('Unknown build asset manifest')
    assets = pins['assets']
    gradle, *sqlite = assets
    if (gradle['name'] != 'gradle-8.14.3-all.zip'
            or {a['name'] for a in sqlite} != {
                'libsqlite3.x64.linux.so', 'libsqlite3.arm.android.so',
                'libsqlite3.arm64.android.so', 'libsqlite3.x64.android.so'}
            or len(sqlite) != 4 or len({a['sha256'][:8] for a in sqlite}) != 4):
        raise ValueError('Unexpected build asset coverage')
    properties = (client / 'android/gradle/wrapper/gradle-wrapper.properties').read_text()
    for key, expected in (('distributionUrl', pins['gradle_distribution_url']),
                          ('distributionSha256Sum', gradle['sha256'])):
        matches = re.findall(r'^' + key + r'=(.+)$', properties, re.MULTILINE)
        if len(matches) != 1 or matches[0].replace('\\:', ':') != expected:
            raise ValueError('Gradle wrapper does not match pinned download')
    config = client / '.dart_tool/package_config.json'
    packages = json.loads(config.read_text())['packages']
    package, = [p for p in packages if p['name'] == 'sqlite3']
    uri = urlsplit(urljoin(config.resolve().as_uri(), package['rootUri']))
    if uri.scheme != 'file' or uri.netloc:
        raise ValueError('Expected a local pub package')
    hashes = (Path(unquote(uri.path)) / 'lib/src/hook/asset_hashes.dart').read_text()
    if len(re.findall(r"releaseTag\s*=\s*'" + re.escape(pins['sqlite3_release']) + "'", hashes)) != 1:
        raise ValueError('SQLite release does not match pub lock')
    for asset in sqlite:
        pattern = "'" + re.escape(asset['name']) + r"'\s*:\s*'" + asset['sha256'] + "'"
        if len(re.findall(pattern, hashes)) != 1:
            raise ValueError('SQLite upstream checksum does not match pin')
    # Validate all source inputs before downloading or touching generated outputs.
    for asset in assets:
        source = fetch(asset, cache)
        if asset is gradle:
            target = (gradle_home / 'wrapper/dists' / gradle['name'].removesuffix('.zip')
                      / distribution_key(pins['gradle_distribution_url']) / gradle['name'])
        else:
            target = (client / '.dart_tool/hooks_runner/shared/sqlite3/build'
                      / ('download-' + asset['sha256'][:8]) / 'libsqlite3.so')
        stage(source, target, asset)
    print('Verified and staged Gradle and four upstream SQLite build assets')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=Path.home()/'.cache/voicechat-client-build-assets')
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('This helper prepares the pinned Linux CI host and Android ABIs')
    prepare(ROOT/'apps/client', args.cache,
            Path(os.environ.get('GRADLE_USER_HOME', Path.home()/'.gradle')),
            json.loads((ROOT/'infra/client-build-assets.json').read_text()))


if __name__ == '__main__':
    main()
