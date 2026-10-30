"""Verify network boot units with Debian systemd's parser, without a host daemon.

This checks unit ordering and fail-closed missing state, not an actual VM boot.
The disposable container has no network, capabilities, host ports or writable
host mounts. Its synthetic docker.service only exercises dependency ordering.
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools-image', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', args.tools_image):
        raise ValueError('Resolve the immutable local verifier image ID')
    with tempfile.TemporaryDirectory(prefix='voicechat-network-units-') as directory:
        root = Path(directory)
        shutil.copyfile(ROOT / 'infra/voicechat-network.service', root / 'voicechat-network.service')
        drop = root / 'docker.service.d'
        drop.mkdir()
        shutil.copyfile(ROOT / 'infra/voicechat-docker-network.conf', drop / '50-voicechat-network.conf')
        (root / 'docker.service').write_text('''[Unit]
Wants=network-online.target
After=network-online.target
[Service]
ExecStart=/bin/true
''')
        (root / 'verify.py').write_text('''import os,shutil,subprocess,sys
from pathlib import Path
sys.path.insert(0,'/opt/voicechat/network')
import network_runtime
unit=Path('/units/voicechat-network.service').read_text()
starts=[line.split('=',1)[1].split() for line in unit.splitlines() if line.startswith('ExecStart=')]
assert len(starts)==1 and starts[0][1].endswith('/network_runtime.py')
assert 'ConditionPathExists' not in unit and 'ExecStop=' not in unit and 'PrivateNetwork=yes' not in unit
drop=Path('/units/docker.service.d/50-voicechat-network.conf').read_text()
assert 'Requires=voicechat-network.service' in drop and 'After=voicechat-network.service' in drop
subprocess.run(['systemd-analyze','verify','--man=no','/units/voicechat-network.service','/units/docker.service'],check=True)
for command in starts:
    result=subprocess.run(command,text=True,capture_output=True)
    assert result.returncode!=0 and 'No saved' in result.stderr
print('PASS: systemd 252 unit verification; coordinated network resume; Docker requires network success; missing state fails closed',flush=True)
# Demonstrate that this verifier catches a real dependency cycle.
cycle=Path('/tmp/cycle');cycle.mkdir()
shutil.copytree('/units/docker.service.d',cycle/'docker.service.d')
(cycle/'docker.service').write_text(Path('/units/docker.service').read_text().replace('[Unit]','[Unit]'+chr(10)+'Before=voicechat-network.service'))
environment={**os.environ,'SYSTEMD_UNIT_PATH':str(cycle)+':'+os.environ['SYSTEMD_UNIT_PATH']}
result=subprocess.run(['systemd-analyze','verify','--man=no',str(cycle/'docker.service'),'/units/voicechat-network.service'],env=environment,text=True,capture_output=True)
assert result.returncode!=0 and 'cycle' in result.stderr.lower(),result.stderr
print('PASS: negative dependency-cycle fixture rejected; no actual boot or running systemd claimed',flush=True)
''')
        subprocess.run(['docker', 'run', '--rm', '--network', 'none', '--cap-drop', 'ALL', '--read-only',
            '--tmpfs', '/tmp', '--tmpfs', '/run',
            '--tmpfs', '/var/lib/voicechat-network:mode=700',
            '-e', 'PYTHONDONTWRITEBYTECODE=1',
            '-e', 'SYSTEMD_UNIT_PATH=/units:/lib/systemd/system:/usr/lib/systemd/system',
            '-v', str(ROOT / 'infra') + ':/opt/voicechat/network:ro',
            '-v', str(root) + ':/units:ro', args.tools_image, '/usr/bin/python3', '/units/verify.py'], check=True)


if __name__ == '__main__': main()
