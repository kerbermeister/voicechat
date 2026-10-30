"""Exercise pinned lego command in a network-disabled container with a fake token."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import acme
from test_acme import inputs


def main():
    public, inventory, config = inputs()
    containers = []
    observed_network_failure = False
    with tempfile.TemporaryDirectory(prefix='voicechat-acme-offline-') as temporary:
        root = Path(temporary)
        token = root / 'token'
        token.touch(mode=0o600)
        token.write_text('00000000-0000-0000-0000-000000000000')

        def offline_run(command, **kwargs):
            nonlocal observed_network_failure
            command = list(command)
            if command[1] == 'create':
                containers.append(command[command.index('--name') + 1])
                command[2:2] = ['--network', 'none', '--pull', 'never']
            elif command[1] == 'start':
                info = subprocess.run(['docker', 'inspect', '--format', '{{.HostConfig.NetworkMode}}', containers[-1]],
                                      check=True, capture_output=True, text=True)
                assert info.stdout.strip() == 'none'
            result = subprocess.run(command, **{**kwargs, 'timeout': 60})
            if command[1] == 'start':
                diagnostics = result.stdout + result.stderr
                assert token.read_bytes() not in diagnostics, 'Credential exposed in diagnostics'
                assert b'flag provided but not defined' not in diagnostics
                observed_network_failure = result.returncode != 0 and any(value in diagnostics.lower()
                    for value in (b'network is unreachable', b'connection refused', b'no such host', b'i/o timeout'))
            return result

        try:
            try:
                acme.execute(root / 'state', public, inventory, config, 'b', 'web', token,
                             accept_tos=True, run=offline_run)
            except ValueError as error:
                assert str(error).startswith('ACME issuance failed'), str(error)
            else:
                raise AssertionError('Issuance must fail without network')
            assert observed_network_failure, 'Expected network refusal after CLI parsing'
            assert not (root / 'state/inflight.json').exists()
            assert not (root / 'state/verified').exists()
            assert not list((root / 'state').glob('.credential-*'))
            for name in containers:
                assert subprocess.run(['docker', 'inspect', name], capture_output=True).returncode != 0
            print('Pinned lego CLI parsed; network refused; credential/container cleanup passed. No issuance or DNS API calls.')
        finally:
            for name in containers:
                subprocess.run(['docker', 'rm', '--force', name], capture_output=True, timeout=30)


if __name__ == '__main__': main()
