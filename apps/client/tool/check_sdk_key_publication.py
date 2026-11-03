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
from urllib.parse import unquote, urlparse
import uuid

from call_network_lab import ROOT, require_local_docker
from check_route_livekit import token
from check_route_turn import reserve_range


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device', default='macos')
    parser.add_argument('--android-emulator', action='store_true')
    parser.add_argument('--adb', type=Path)
    parser.add_argument('--case', choices=('both', 'baseline', 'pinned'), default='both')
    parser.add_argument('--require-frame-encryption', action='store_true')
    parser.add_argument('--repeat-receiver-key', action='store_true', help='Repeat the same receiver key every 9s, 20 times; baseline native case only')
    parser.add_argument('--web-root', type=Path, help='Serve a built synthetic browser probe instead of running native tests')
    parser.add_argument('--web-port', type=int, default=7395)
    parser.add_argument('--failures', action='store_true', help='Exercise native capture/cryptor rollback')
    args = parser.parse_args()
    if args.repeat_receiver_key and (args.case != 'baseline' or args.failures or args.web_root):
        parser.error('Receiver-key repetition requires --case baseline and the native publication probe')
    if args.device != 'macos':
        if not args.android_emulator or args.adb is None or args.web_root:
            parser.error('Non-Mac native probes require the disposable Android emulator and --adb')
        def adb(*command):
            return subprocess.check_output([str(args.adb.resolve()), '-s', args.device, *command], text=True).strip()
        if adb('shell', 'getprop', 'ro.kernel.qemu') != '1' or adb('emu', 'avd', 'name').splitlines()[0] != 'VoiceChat_KeyEpoch35':
            parser.error('Only the account-free VoiceChat_KeyEpoch35 emulator is supported')
    elif args.android_emulator:
        parser.error('Select the Android emulator with --device')
    require_local_docker()
    image = re.search(r'^FROM (livekit/livekit-server@sha256:\w+)',
                      (ROOT / 'infra/control.Dockerfile').read_text())[1]
    name = 'voicechat-sdk-key-' + uuid.uuid4().hex[:12]
    first, held = reserve_range()
    api_key, secret = 'local-probe', secrets.token_hex(32)
    target = ROOT / 'apps/client/integration_test' / (
        'native_key_startup_failure_test.dart' if args.failures
        else 'native_group_key_publication_test.dart')
    package_config = ROOT / 'apps/client/.dart_tool/package_config.json'
    package = next(p for p in json.loads(package_config.read_text())['packages']
                   if p['name'] == 'livekit_client')
    sdk = (package_config.parent / unquote(urlparse(package['rootUri']).path)).resolve()
    log = ROOT / '.prototype' / (name + '.private.log')
    log.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=name) as temporary:
        folder = Path(temporary)
        folder.chmod(0o700)
        config = folder / 'livekit.json'
        config.write_text(json.dumps({
            'port': 7880, 'keys': {api_key: secret},
            'rtc': {'port_range_start': first, 'port_range_end': first + 7,
                    'use_external_ip': False,
                    'node_ip': '10.0.2.2' if args.android_emulator else '127.0.0.1'},
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
            client_address = address.replace('127.0.0.1:', '10.0.2.2:') if args.android_emulator else address
            defines = folder / 'client.json'
            defines.write_text(json.dumps({
                'HARDWARE_CALL_TEST': True, 'GROUP_TEST_URL': 'ws://' + client_address,
                'GROUP_TEST_CASE': args.case,
                'GROUP_TEST_LOCAL_SDK_PATCH': (sdk / 'VOICECHAT_PATCH.md').is_file(),
                'GROUP_TEST_REQUIRE_FRAME_ENCRYPTION': args.require_frame_encryption,
                'GROUP_TEST_REPEAT_RECEIVER_KEY': args.repeat_receiver_key,
                'GROUP_TEST_ALICE': token('alice', api_key, secret),
                'GROUP_TEST_BOB': token('bob', api_key, secret),
                'GROUP_TEST_OBSERVER': token('observer', api_key, secret),
            }))
            defines.chmod(0o600)
            if args.web_root:
                from serve_key_epoch_fixture import fixture_server
                if not 1024 <= args.web_port <= 65535 or not (args.web_root / 'main.dart.js').is_file():
                    raise ValueError('A built fixture and unprivileged port are required')
                with fixture_server(args.web_root, args.web_port, {
                    'url': 'ws://' + address,
                    **{identity: token(identity, api_key, secret)
                       for identity in ('alice', 'bob', 'observer')},
                }) as server:
                    print(f'http://127.0.0.1:{args.web_port}/index.html (synthetic SDK/SFU probe)', flush=True)
                    server.serve_forever()
                return

            env = {**os.environ, 'LANG': 'en_US.UTF-8',
                   'LC_ALL': 'en_US.UTF-8', 'LC_CTYPE': 'en_US.UTF-8'}
            print('Local SDK/SFU private log: ' + str(log), flush=True)
            timeout = (900 if args.android_emulator else 600) if args.repeat_receiver_key else (600 if args.android_emulator else 360)
            with log.open('w') as output:
                log.chmod(0o600)
                result = subprocess.run([
                    str(args.flutter.resolve()), 'test', '-d', args.device,
                    '--dart-define-from-file=' + str(defines),
                    'integration_test/' + target.name,
                ], cwd=ROOT / 'apps/client', env=env, stdout=output,
                    stderr=subprocess.STDOUT, timeout=timeout)
            text = log.read_text()
            if result.returncode or 'All tests passed!' not in text:
                raise RuntimeError('SDK assertions failed; inspect private log ' + str(log))
            marker = 'SDK_KEY_FAILURE_PROOF' if args.failures else 'SDK_KEY_PUBLICATION_PROOF'
            proofs = [json.loads(value) for value in re.findall(
                marker + r' (\{[^\n]+\})', text)]
            expected = {'both': [False, True], 'baseline': [False], 'pinned': [True]}
            if args.failures:
                assert len(proofs) == 12
            else:
                assert [proof['pinned_provider'] for proof in proofs] == expected[args.case]
                if args.repeat_receiver_key:
                    assert len(proofs) == 1 and proofs[0]['repeated_receiver_key_installs'] == 20
                    assert all(after > before + 5 for before, after in proofs[0]['frames_before_after_repeated_install'])
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps({
                'pinned_sfu': image, 'loopback_only': True,
                'platform': 'Android emulator API35' if args.android_emulator else 'native macOS',
                'local_camera': not args.android_emulator, 'emulated_camera': args.android_emulator,
                'case': 'failure rollback' if args.failures else args.case,
                'local_sdk_patch': (sdk / 'VOICECHAT_PATCH.md').is_file(),
                'sdk_e2ee_manager_sha256': hashlib.sha256(
                    (sdk / 'lib/src/e2ee/e2ee_manager.dart').read_bytes()).hexdigest(),
                'require_frame_encryption': args.require_frame_encryption,
                'repeat_receiver_key': args.repeat_receiver_key,
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
