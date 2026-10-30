"""Check pinned SSH identity and replacement against disposable OpenSSH nodes.

Only synthetic credentials, an internal documentation-address bridge and no
published host ports. Production hosts, DNS and user SSH configuration are unused.
"""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import node_inventory
from test_node_inventory import fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools-image', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', args.tools_image):
        raise ValueError('Use the immutable local OpenSSH fixture image ID')
    project = 'voicechat-ssh-' + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix=project) as directory:
        root = Path(directory)
        for name in ('client', 'host', 'replacement'):
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(root / name)], check=True)
        inventory = fixture()
        inventory.update(ssh_user='root', ssh_port=2222)
        inventory['edges'][0]['ssh_host_key'] = ' '.join((root / 'host.pub').read_text().split()[:2])
        node_inventory.validate(inventory)
        (root / 'inventory.json').write_text(json.dumps(inventory))
        replacement = deepcopy(inventory)
        replacement['edges'][0].update(generation=2,
            ssh_host_key=' '.join((root / 'replacement.pub').read_text().split()[:2]))
        node_inventory.validate(replacement)
        node_inventory.check_replacement(inventory, replacement)
        (root / 'replacement.json').write_text(json.dumps(replacement))
        (root / 'sshd.conf').write_text('''Port 2222
ListenAddress 192.0.2.11
HostKey /state/host
PidFile /state/sshd.pid
AuthorizedKeysFile /state/authorized_keys
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
StrictModes yes
AllowUsers root
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
LogLevel ERROR
''')
        (root / 'server.py').write_text('''import os,shutil
from pathlib import Path
Path('/run/sshd').mkdir(exist_ok=True)
for source,target in [('host','host'),('client.pub','authorized_keys')]:
    shutil.copyfile('/input/'+source,'/state/'+target);os.chmod('/state/'+target,0o600)
os.execv('/usr/sbin/sshd',['/usr/sbin/sshd','-D','-e','-f','/input/sshd.conf'])
''')
        (root / 'probe.py').write_text('''from copy import deepcopy
import json,os,shutil,subprocess,sys
sys.path.insert(0,'/source')
import host_connection,node_inventory
old=node_inventory.load('/input/inventory.json')
new=node_inventory.load('/input/replacement.json')
shutil.copyfile('/input/client','/state/client');os.chmod('/state/client',0o600)
def execute(inventory,arguments,**kwargs):
    return host_connection.execute(inventory,'edge-b','/state/client',arguments,**kwargs).stdout
def denied(inventory):
    try: execute(inventory,['/usr/bin/python3','-c',"from pathlib import Path; Path('/tmp/untrusted-command').touch()"])
    except subprocess.CalledProcessError as error:
        assert error.returncode==255 and b'Host key verification failed' in error.stderr,error.stderr
    else: raise AssertionError('Unverified host was accepted')
if sys.argv[1]=='initial':
    value="$(touch /tmp/shell-injected); 'quoted'\\nnext"
    result=execute(old,['/usr/bin/python3','-c','import sys,json; print(json.dumps(sys.argv[1:]))',value])
    assert json.loads(result)==[value]
    payload=b'standard input\\x00\\nprivate fixture'
    assert execute(old,['/usr/bin/python3','-c','import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())'],input=payload)==payload
    denied(new)
    active=old
else:
    denied(old)
    active=new
    assert execute(new,['/usr/bin/python3','-c','print("replacement trusted")']).strip()==b'replacement trusted'
assert execute(active,['/usr/bin/python3','-c',"from pathlib import Path; assert not Path('/tmp/untrusted-command').exists(); assert not Path('/tmp/shell-injected').exists(); print('clean')"]).strip()==b'clean'
print('PASS: '+sys.argv[1]+': pinned Ed25519 host, literal arguments, no untrusted remote command',flush=True)
''')
        services = {}
        for name, ip in (('server', '192.0.2.11'), ('client', '192.0.2.14')):
            services[name] = {'image': args.tools_image, 'read_only': True,
                'environment': {'PYTHONDONTWRITEBYTECODE': '1'},
                'tmpfs': ['/state:mode=700', '/run', '/tmp'],
                'volumes': [str(root) + ':/input:ro', str(ROOT / 'infra') + ':/source:ro'],
                'networks': {'default': {'ipv4_address': ip}},
                'entrypoint': ['/usr/bin/python3', '/input/server.py'] if name == 'server' else ['sleep', 'infinity']}
        services['client']['cap_drop'] = ['ALL']
        services['server']['healthcheck'] = {'test': ['CMD', '/usr/bin/python3', '-c',
            'import socket; socket.create_connection(("192.0.2.11",2222),timeout=1).close()'],
            'interval': '1s', 'timeout': '2s', 'retries': 15}
        compose = root / 'compose.json'
        compose.write_text(json.dumps({'name': project, 'services': services,
            'networks': {'default': {'internal': True, 'ipam': {'config': [{'subnet': '192.0.2.0/28'}]}}}}))
        command = ['docker', 'compose', '-f', str(compose)]
        try:
            subprocess.run([*command, 'up', '-d', '--wait', '--wait-timeout', '30'], check=True)
            subprocess.run([*command, 'exec', '-T', 'client', '/usr/bin/python3', '/input/probe.py', 'initial'], check=True)
            # Replace the synthetic host key and restart only this test SSH node.
            (root / 'host').write_bytes((root / 'replacement').read_bytes())
            subprocess.run([*command, 'stop', '-t', '1', 'server'], check=True)
            subprocess.run([*command, 'up', '-d', '--no-recreate', '--wait', '--wait-timeout', '30', 'server'], check=True)
            subprocess.run([*command, 'exec', '-T', 'client', '/usr/bin/python3', '/input/probe.py', 'replacement'], check=True)
        except Exception:
            subprocess.run([*command, 'logs', '--tail', '15'], check=False)
            raise
        finally:
            subprocess.run([*command, 'down', '--volumes', '--remove-orphans'], check=True)


if __name__ == '__main__': main()
