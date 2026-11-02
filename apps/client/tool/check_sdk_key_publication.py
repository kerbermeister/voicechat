"""Probe SDK camera/key publication against an isolated loopback SFU on macOS."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
import time
from urllib.request import urlopen
import uuid

from call_network_lab import ROOT, require_local_docker
from check_route_livekit import token
from check_route_turn import reserve_range


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', choices=('both', 'baseline', 'pinned'), default='both')
    parser.add_argument('--require-frame-encryption', action='store_true')
    args = parser.parse_args()
    require_local_docker()
    image = re.search(r'^FROM (livekit/livekit-server@sha256:\w+)',
                      (ROOT / 'infra/control.Dockerfile').read_text())[1]
    name = 'voicechat-sdk-key-' + uuid.uuid4().hex[:12]
    first, held = reserve_range()
    api_key, secret = 'local-probe', secrets.token_hex(32)
    target = ROOT / 'apps/client/integration_test/native_group_key_publication_test.dart'
    log = ROOT / '.prototype' / (name + '.private.log')
    log.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=name) as temporary:
        folder = Path(temporary)
        folder.chmod(0o700)
        config = folder / 'livekit.json'
        config.write_text(json.dumps({
            'port': 7880, 'keys': {api_key: secret},
            'rtc': {'port_range_start': first, 'port_range_end': first + 7,
                    'use_external_ip': False, 'node_ip': '127.0.0.1'},
        }))
        config.chmod(0o600)
        created = False
        try:
            for item in held:
                item.close()
            subprocess.run([
                'docker', 'run', '--detach', '--name', name,
                '--publish', '127.0.0.1::7880/tcp',
                *[argument for port in range(first, first + 8)
                  for argument in ('--publish', f'127.0.0.1:{port}:{port}/udp')],
                '--volume', str(config) + ':/etc/sfu.json:ro',
                '--memory', '384m', '--cpus', '1', '--env', 'GOMAXPROCS=2',
                image, '--config', '/etc/sfu.json',
            ], check=True, capture_output=True, timeout=30)
            created = True
            address = subprocess.check_output(
                ['docker', 'port', name, '7880/tcp'], text=True).strip()
            if not address.startswith('127.0.0.1:'):
                raise ValueError('Loopback SFU required')
            for attempt in range(50):
                try:
                    with urlopen('http://' + address, timeout=1) as response:
                        assert response.status == 200
                    break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError('Local SFU not ready')
            defines = folder / 'client.json'
            defines.write_text(json.dumps({
                'HARDWARE_CALL_TEST': True, 'GROUP_TEST_URL': 'ws://' + address,
                'GROUP_TEST_CASE': args.case,
                'GROUP_TEST_REQUIRE_FRAME_ENCRYPTION': args.require_frame_encryption,
                'GROUP_TEST_ALICE': token('alice', api_key, secret),
                'GROUP_TEST_BOB': token('bob', api_key, secret),
                'GROUP_TEST_OBSERVER': token('observer', api_key, secret),
            }))
            defines.chmod(0o600)
            env = {**os.environ, 'LANG': 'en_US.UTF-8',
                   'LC_ALL': 'en_US.UTF-8', 'LC_CTYPE': 'en_US.UTF-8'}
            print('Local SDK/SFU private log: ' + str(log), flush=True)
            with log.open('w') as output:
                log.chmod(0o600)
                result = subprocess.run([
                    str(args.flutter.resolve()), 'test', '-d', 'macos',
                    '--dart-define-from-file=' + str(defines),
                    'integration_test/native_group_key_publication_test.dart',
                ], cwd=ROOT / 'apps/client', env=env, stdout=output,
                    stderr=subprocess.STDOUT, timeout=360)
            text = log.read_text()
            if result.returncode or 'All tests passed!' not in text:
                raise RuntimeError('SDK assertions failed; inspect private log ' + str(log))
            proofs = [json.loads(value) for value in re.findall(
                r'SDK_KEY_PUBLICATION_PROOF (\{[^\n]+\})', text)]
            expected = {'both': [False, True], 'baseline': [False], 'pinned': [True]}
            assert [proof['pinned_provider'] for proof in proofs] == expected[args.case]
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps({
                'pinned_sfu': image, 'loopback_only': True,
                'platform': 'native macOS', 'local_camera': True,
                'case': args.case,
                'require_frame_encryption': args.require_frame_encryption,
                'production_modified': False,
                'fixture_sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                'private_log_sha256': hashlib.sha256(log.read_bytes()).hexdigest(),
                'runs': proofs,
            }, indent=2) + '\n')
        finally:
            for item in held:
                item.close()
            removed = subprocess.run(['docker', 'rm', '--force', name],
                                     capture_output=True, timeout=15)
            if created and removed.returncode:
                raise RuntimeError('Owned SFU container cleanup failed')
    print('PASS: real SDK/SFU publication probe; inspect safety/negative-control fields')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # SDK/network exceptions can carry the synthetic JWT URL.
        raise SystemExit('Local SDK publication probe failed: ' + type(error).__name__) from None
