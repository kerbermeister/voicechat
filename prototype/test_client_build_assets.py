import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
import prepare_client_build_assets as assets


class ClientBuildAssetsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        sleeper = patch.object(assets.time, 'sleep')
        sleeper.start()
        self.addCleanup(sleeper.stop)
        self.cache = self.root / 'cache'
        self.payload = b'Official fixture bytes'
        self.asset = {'repo': 'simolus3/sqlite3.dart', 'id': 123,
                      'name': 'libsqlite3.x64.linux.so', 'size': len(self.payload),
                      'sha256': hashlib.sha256(self.payload).hexdigest()}

    def download(self, args, *, stdout, check, timeout):
        self.assertEqual(args[:4], ['gh', 'api', '-H', 'Accept: application/octet-stream'])
        self.assertTrue(check)
        self.assertEqual(timeout, 180)
        stdout.write(self.payload)
        return subprocess.CompletedProcess(args, 0)

    def test_verified_cache_reused_and_tampered_cache_replaced(self):
        with patch.object(assets.subprocess, 'run', side_effect=self.download) as transport:
            result = assets.fetch(self.asset, self.cache)
            self.assertEqual(result.read_bytes(), self.payload)
            self.assertEqual(assets.fetch(self.asset, self.cache), result)
            self.assertEqual(transport.call_count, 1)
            result.write_bytes(b'Tampered')
            assets.fetch(self.asset, self.cache)
            self.assertEqual(transport.call_count, 2)
            self.assertEqual(result.read_bytes(), self.payload)

    def test_wrong_download_hash_or_size_never_published(self):
        for content in (b'x' * len(self.payload), b'Gateway timeout'):
            with self.subTest(payload=content):
                def wrong(args, *, stdout, **kwargs):
                    stdout.write(content)
                with patch.object(assets.subprocess, 'run', side_effect=wrong):
                    with self.assertRaisesRegex(ValueError, 'size or SHA-256'):
                        assets.fetch(self.asset, self.cache)
                self.assertEqual(list(self.cache.iterdir()), [])

    def test_large_asset_requires_correct_ranges_and_whole_sha(self):
        def transport(args, **kwargs):
            interval = next(a for a in args if a.startswith('Range: bytes='))
            start, end = map(int, interval.split('=')[1].split('-'))
            body = self.payload[start:end+1]
            header = f"HTTP/2.0 206 Partial Content\nContent-Range: bytes {start}-{end}/{len(self.payload)}\r\n\r\n"
            return subprocess.CompletedProcess(args, 0, stdout=header.encode()+body)
        with patch.object(assets, 'RANGE_SIZE', 4):
            with patch.object(assets.subprocess, 'run', side_effect=transport):
                output = assets.fetch(self.asset, self.cache)
                self.assertEqual(output.read_bytes(), self.payload)
            output.unlink()
            def corrupted(args, **kwargs):
                response = transport(args, **kwargs)
                return subprocess.CompletedProcess(args, 0, stdout=response.stdout[:-1]+b'!')
            with patch.object(assets.subprocess, 'run', side_effect=corrupted):
                with self.assertRaisesRegex(ValueError, 'size or SHA-256'):
                    assets.fetch(self.asset, self.cache)
            self.assertEqual(list(self.cache.iterdir()), [])

    def test_ignored_incorrect_or_truncated_range_is_rejected(self):
        responses = [b'HTTP/2.0 200 OK\r\n\r\nwhole file',
                     b'HTTP/2.0 206 Partial Content\nContent-Range: bytes 1-2/20\r\n\r\nxx',
                     b'HTTP/2.0 206 Partial Content\nContent-Range: bytes 0-1/22\r\n\r\nx']
        for response in responses:
            with self.subTest(response=response), patch.object(
                    assets.subprocess, 'run', return_value=subprocess.CompletedProcess('gh',0,stdout=response)):
                with self.assertRaisesRegex(ValueError, 'range response'):
                    assets.download_range(self.asset, 0, 1, self.root)

    def test_failed_transport_removes_temporary_download(self):
        for error in (subprocess.CalledProcessError(1, 'gh'), subprocess.TimeoutExpired('gh', 180)):
            with self.subTest(error=type(error).__name__):
                with patch.object(assets.subprocess, 'run', side_effect=error):
                    with self.assertRaises(type(error)):
                        assets.fetch(self.asset, self.cache)
                self.assertEqual(list(self.cache.iterdir()), [])

    def test_retry_discards_partial_bytes_before_verified_download(self):
        calls = 0
        def interrupted(args, *, stdout, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 1:
                stdout.write(b'Partial gateway response')
                raise subprocess.CalledProcessError(1, args, stderr=b'HTTP 502')
            stdout.write(self.payload)
            return subprocess.CompletedProcess(args, 0)
        with patch.object(assets.subprocess, 'run', side_effect=interrupted):
            output = assets.fetch(self.asset, self.cache)
        self.assertEqual(calls, 2)
        self.assertEqual(output.read_bytes(), self.payload)

    def test_authentication_or_missing_asset_is_not_retried(self):
        for status in (401, 403, 404):
            error = subprocess.CalledProcessError(1, 'gh', stderr=f'HTTP {status}'.encode())
            with self.subTest(status=status), patch.object(assets.subprocess,'run',side_effect=error) as transport:
                with self.assertRaises(subprocess.CalledProcessError):
                    assets.fetch(self.asset, self.cache)
                self.assertEqual(transport.call_count, 1)

    def test_invalid_asset_cannot_select_another_host_or_path(self):
        for change in ({'repo': 'untrusted/repo'}, {'name': '../file'}, {'id': -1},
                       {'size': 300_000_000}, {'sha256': 'unchecked'}):
            with self.subTest(change=change), patch.object(assets.subprocess, 'run') as transport:
                with self.assertRaises(ValueError):
                    assets.fetch({**self.asset, **change}, self.cache)
                transport.assert_not_called()

    def test_staging_keeps_existing_output_on_invalid_source(self):
        source = self.root / 'source'
        target = self.root / 'output'
        source.write_bytes(b'Tampered')
        target.write_bytes(b'Existing output')
        with self.assertRaises(ValueError):
            assets.stage(source, target, self.asset)
        self.assertEqual(target.read_bytes(), b'Existing output')
        source.write_bytes(self.payload)
        assets.stage(source, target, self.asset)
        self.assertEqual(target.read_bytes(), self.payload)
        self.assertFalse(any(p.name.startswith('tmp') for p in self.root.iterdir()))

    def fixture(self):
        pins = json.loads((assets.ROOT / 'infra/client-build-assets.json').read_text())
        for asset in pins['assets']:
            asset.update(size=len(self.payload), sha256=self.asset['sha256'])
        # Real hooks use distinct content-derived directories per ABI.
        for index, asset in enumerate(pins['assets'][1:]):
            asset['sha256'] = str(index) + asset['sha256'][1:]
        client = self.root / 'client'
        wrapper = client / 'android/gradle/wrapper/gradle-wrapper.properties'
        wrapper.parent.mkdir(parents=True)
        wrapper.write_text('distributionUrl=' + pins['gradle_distribution_url'].replace(':', '\\:')
                           + '\ndistributionSha256Sum=' + pins['assets'][0]['sha256'] + '\n')
        package = self.root / 'pub-package'
        hashes = package / 'lib/src/hook/asset_hashes.dart'
        hashes.parent.mkdir(parents=True)
        hashes.write_text("const String? releaseTag = '" + pins['sqlite3_release'] + "';\n" +
                          '\n'.join("'" + a['name'] + "': '" + a['sha256'] + "',"
                                    for a in pins['assets'][1:]))
        config = client / '.dart_tool/package_config.json'
        config.parent.mkdir()
        config.write_text(json.dumps({'packages': [{'name': 'sqlite3', 'rootUri': package.as_uri()}]}))
        return pins, client, wrapper, hashes

    def test_all_verified_assets_reach_native_hook_and_wrapper_caches(self):
        pins, client, wrapper, hashes = self.fixture()
        contents = {}
        for asset in pins['assets']:
            data = asset['name'].encode()
            asset.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
            source = self.root / asset['name']
            source.write_bytes(data)
            contents[asset['name']] = source
        wrapper.write_text('distributionUrl=' + pins['gradle_distribution_url'] +
                           '\ndistributionSha256Sum=' + pins['assets'][0]['sha256'] + '\n')
        hashes.write_text("const String? releaseTag = '" + pins['sqlite3_release'] + "';\n" +
                          '\n'.join("'" + a['name'] + "': '" + a['sha256'] + "',"
                                    for a in pins['assets'][1:]))
        with patch.object(assets, 'fetch', side_effect=lambda asset, cache: contents[asset['name']]):
            assets.prepare(client, self.cache, self.root/'gradle', pins)
        archive = self.root/'gradle/wrapper/dists/gradle-8.14.3-all/10utluxaxniiv4wxiphsi49nj/gradle-8.14.3-all.zip'
        self.assertTrue(assets.valid(archive, pins['assets'][0]))
        for asset in pins['assets'][1:]:
            output = client/'.dart_tool/hooks_runner/shared/sqlite3/build'/('download-'+asset['sha256'][:8])/'libsqlite3.so'
            self.assertTrue(assets.valid(output, asset))

    def test_package_or_wrapper_drift_fails_before_download(self):
        pins, client, wrapper, hashes = self.fixture()
        for path in (wrapper, hashes):
            original = path.read_text()
            path.write_text('Different source/checksum')
            with self.subTest(path=path.name), patch.object(assets, 'fetch') as download:
                with self.assertRaises(ValueError):
                    assets.prepare(client, self.cache, self.root/'gradle', pins)
                download.assert_not_called()
            path.write_text(original)

    def test_gradle_cache_matches_real_wrapper_key(self):
        self.assertEqual(assets.distribution_key(
            'https://services.gradle.org/distributions/gradle-8.14.3-all.zip'),
            '10utluxaxniiv4wxiphsi49nj')
        pins = json.loads((assets.ROOT/'infra/client-build-assets.json').read_text())
        properties = (assets.ROOT/'apps/client/android/gradle/wrapper/gradle-wrapper.properties').read_text()
        self.assertIn('distributionSha256Sum=' + pins['assets'][0]['sha256'], properties)


if __name__ == '__main__':
    unittest.main()
