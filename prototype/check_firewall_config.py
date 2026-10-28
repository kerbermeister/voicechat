"""Check generated nftables on real INPUT/FORWARD and conntrack DNAT paths.

Disposable namespaces simulate the host side of Docker DNAT. No privileged/host
network containers, production data or host firewall modifications are used.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import firewall_config
import node_inventory
import tunnel_config
from test_node_inventory import fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools-image', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', args.tools_image):
        raise ValueError('Resolve the local immutable tools image ID')
    project = 'voicechat-firewall-' + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix=project) as directory:
        root = Path(directory)
        inventory = fixture()
        registry = {'schema': 1, 'service_id': inventory['service_id'], 'nodes': {}}
        for name in tunnel_config.physical_nodes(inventory):
            registry['nodes'][name] = {'generation': 1, 'public_key': tunnel_config.ensure_key(root / (name + '.key'))}
        (root / 'inventory.json').write_text(json.dumps(inventory))
        (root / 'public-keys.json').write_text(json.dumps(registry))
        # This bridge name is the same one produced for the later co-located edge.
        single = {**inventory, 'edges': [{'id': 'a', 'host': 'core'}]}
        bridge = node_inventory.edge_bridge(single, 'a')
        core_bridge = node_inventory.core_bridge(inventory)
        (root / 'core-http.py').write_text('''import functools, http.server, socket, threading
def serve_http(port):
    http.server.ThreadingHTTPServer(('10.88.0.1',port),functools.partial(http.server.SimpleHTTPRequestHandler,directory='/empty')).serve_forever()
for port in (8090,8091): threading.Thread(target=serve_http,args=(port,),daemon=True).start()
sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sock.bind(('192.0.2.10',50301))
while True:
    value,address=sock.recvfrom(1024);sock.sendto(value,address)
''')
        (root / 'backend.py').write_text('''import functools, http.server, socket, threading
threading.Thread(target=lambda:http.server.ThreadingHTTPServer(('0.0.0.0',8008),functools.partial(http.server.SimpleHTTPRequestHandler,directory='/empty')).serve_forever(),daemon=True).start()
sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sock.bind(('0.0.0.0',8009))
while True:
    value,address=sock.recvfrom(1024);sock.sendto(value,address)
''')
        (root / 'echo.py').write_text('''import socket
sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sock.bind(('0.0.0.0',50305))
while True:
    value,address=sock.recvfrom(1024);sock.sendto(value,address)
''')
        (root / 'nat.nft').write_text('''table ip fixture_nat {
 chain prerouting {
  type nat hook prerouting priority dstnat; policy accept;
  ip daddr { 192.0.2.10, 10.88.0.1 } tcp dport { 8088, 7981 } dnat to 10.245.0.3:8008
  ip daddr 192.0.2.10 tcp dport 9002 dnat to 10.242.0.6:8008
  ip daddr 192.0.2.10 udp dport 50300 dnat to 10.245.0.3:8009
 }
 chain postrouting {
  type nat hook postrouting priority srcnat; policy accept;
  ip daddr { 10.245.0.3, 10.242.0.6 } masquerade
  ip saddr 10.245.0.3 masquerade
 }
}
table inet fixture_foreign {
 comment "unrelated host policy must survive"
 chain input { type filter hook input priority 10; policy accept; tcp dport 9000 drop; }
}
''')
        (root / 'start.py').write_text('''import json,os,shutil,subprocess,sys,time
from pathlib import Path
name=sys.argv[1]
def run(*args): subprocess.run(args,check=True)
if name in ('core','edge-b'):
    shutil.copyfile('/input/'+name+'.key','/state/private.key');os.chmod('/state/private.key',0o600)
    run('python3','/source/tunnel_runtime.py','--directory','/state/managed','--inventory','/input/inventory.json','--public-keys','/input/public-keys.json','--node',name,'--private-key','/state/private.key')
if name=='core':
    for attempt in range(100):
        links=json.loads(subprocess.check_output(['ip','-j','-4','address','show']))
        present={a.get('local') for item in links for a in item.get('addr_info',[])}
        if {'192.0.2.10','10.245.0.2','10.242.0.1'} <= present: break
        time.sleep(0.1)
    else: raise RuntimeError('Fixture networks did not attach: '+str(present))
    for address,bridge in [('10.242.0.1',sys.argv[2]),('10.245.0.2',sys.argv[3])]:
        link=next(item['ifname'] for item in links if any(a.get('local')==address for a in item.get('addr_info',[])))
        run('ip','link','add','name',bridge,'type','bridge')
        run('ip','address','del',address+'/28','dev',link)
        run('ip','link','set','dev',link,'master',bridge)
        run('ip','address','add',address+'/28','dev',bridge)
        run('ip','link','set','dev',bridge,'up')
    run('nft','-f','/input/nat.nft')
    os.execvp('python3',['python3','/input/core-http.py'])
elif name=='backend':
    for address in ('192.0.2.0/28','10.242.0.0/28','10.88.0.1/32'): run('ip','route','add',address,'via','10.245.0.2')
    os.execvp('python3',['python3','/input/backend.py'])
elif name=='outsider':
    for address in ('10.88.0.1/32','10.245.0.3/32'): run('ip','route','add',address,'via','192.0.2.10')
elif name!='edge-b':
    for address in ('10.88.0.1/32','192.0.2.10/32'): run('ip','route','add',address,'via','10.242.0.1')
if name=='other': os.execvp('python3',['python3','/input/backend.py'])
if name in ('outsider','edge-b','relay'): os.execvp('python3',['python3','/input/echo.py'])
os.execvp('sleep',['sleep','infinity'])
''')
        assignments = {
            'core': {'public': '192.0.2.10', 'backend': '10.245.0.2', 'local': '10.242.0.1'},
            'edge-b': {'public': '192.0.2.11'}, 'outsider': {'public': '192.0.2.14'},
            'backend': {'backend': '10.245.0.3'},
            'web': {'local': '10.242.0.3'}, 'relay': {'local': '10.242.0.4'},
            'health': {'local': '10.242.0.5'}, 'other': {'local': '10.242.0.6'},
        }
        services = {name: {'image': args.tools_image, 'cap_add': ['NET_ADMIN'],
            'mem_limit': '128m', 'cpus': .25, 'pids_limit': 64,
            'sysctls': {'net.ipv4.ip_forward': '1' if name == 'core' else '0'},
            'entrypoint': ['python3', '/input/start.py', name, bridge, core_bridge],
            'environment': {'PYTHONDONTWRITEBYTECODE': '1'},
            'tmpfs': ['/state:mode=700', '/empty:mode=755'],
            'volumes': [str(root) + ':/input:ro', str(ROOT / 'infra') + ':/source:ro'],
            'networks': {net: {'ipv4_address': address} for net, address in networks.items()}}
            for name, networks in assignments.items()}
        compose = root / 'compose.json'
        compose.write_text(json.dumps({'name': project, 'services': services, 'networks': {
            # Docker's internal bridge drops routed destinations before they
            # reach our namespace, masking the private-address ACL under test.
            # No host ports, Internet requests or masqueraded egress are needed.
            name: {'internal': False,
                   'driver_opts': {'com.docker.network.bridge.enable_ip_masquerade': 'false'},
                   'ipam': {'config': [{'subnet': subnet, 'gateway': gateway}]}}
            for name, subnet, gateway in (('public','192.0.2.0/28','192.0.2.1'),
                                         ('backend','10.245.0.0/28','10.245.0.1'),
                                         ('local','10.242.0.0/28','10.242.0.14'))}}))
        command = ['docker', 'compose', '-f', str(compose)]

        def run(name, *parts):
            result = subprocess.run([*command, 'exec', '-T', name, *parts],
                                    text=True, capture_output=True, timeout=15)
            if result.returncode:
                raise RuntimeError(f'{name} {parts[:3]} failed: {result.stderr}')
            return result.stdout.strip()

        def http(name, host, port, succeeds=True):
            code = f'import urllib.request; assert urllib.request.urlopen("http://{host}:{port}",timeout=1).status==200'
            deadline = time.monotonic() + 12
            while True:
                result = subprocess.run([*command,'exec','-T',name,'python3','-c',code],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
                if not succeeds or result.returncode == 0 or time.monotonic() >= deadline: break
                time.sleep(0.2)
            assert (result.returncode == 0) == succeeds, (name, host, port, succeeds, result.stderr.decode())

        def udp(name, port, succeeds=True):
            code = (f'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(1); '
                    f's.sendto(b"probe",("192.0.2.10",{port})); assert s.recv(32)==b"probe"')
            result = subprocess.run([*command,'exec','-T',name,'python3','-c',code],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            assert (result.returncode == 0) == succeeds, (name, port, succeeds)

        def media_reply(host, succeeds=True):
            # SFU-originated ICE creates a reply-direction NAT flow. It must not
            # create an unrestricted return path from a direct client to SFU.
            code = (f'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(1); '
                    f's.bind(("10.245.0.3",50302)); s.sendto(b"reply",("{host}",50305)); assert s.recv(32)==b"reply"')
            result = subprocess.run([*command,'exec','-T','backend','python3','-c',code],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            assert (result.returncode == 0) == succeeds, ('SFU-originated reply', host, succeeds)

        def apply(name, value, node):
            path = root / (name + '-firewall.json')
            path.write_text(json.dumps(value))
            run(name, 'python3', '/source/firewall_runtime.py', '--directory', '/state/firewall',
                '--inventory', '/input/' + path.name, '--node', node, '--edge-subnet', '10.242.0.0/28')

        try:
            subprocess.run([*command, 'create'], check=True)
            # Older Compose can omit a third bridge from a multihomed service.
            # Check the actual endpoints before starting any network probe.
            container = subprocess.check_output([*command, 'ps', '-aq', 'core'], text=True).strip()
            attached = json.loads(subprocess.check_output(['docker', 'inspect', '--format',
                '{{json .NetworkSettings.Networks}}', container], text=True))
            for network, address in assignments['core'].items():
                name = project + '_' + network
                if name not in attached:
                    subprocess.run(['docker', 'network', 'connect', '--ip', address, name, container], check=True)
            subprocess.run([*command, 'start'], check=True)
            http('edge-b', '10.88.0.1', 8090)
            http('outsider', '10.88.0.1', 8088)  # Private binding alone is not an ACL.
            http('outsider', '10.245.0.3', 8008)  # Direct container routing bypasses published-port matching.
            media_reply('192.0.2.14')
            # A malicious peer can change its own AllowedIPs. Authentication of
            # its /32 source must not grant transit to the backend network.
            run('edge-b', 'wg', 'set', 'wg-vc', 'peer', registry['nodes']['core']['public_key'],
                'allowed-ips', '10.88.0.1/32,10.245.0.3/32')
            run('edge-b', 'ip', 'route', 'add', '10.245.0.3/32', 'dev', 'wg-vc')
            http('edge-b', '10.245.0.3', 8008)
            apply('core', inventory, 'core'); apply('edge-b', inventory, 'edge-b')
            # A private push callback from the owned core bridge may reach only
            # control:8090, through both a host listener and Docker-style DNAT.
            http('backend','10.88.0.1',8090)
            http('backend','10.88.0.1',8088,False)
            http('backend','10.88.0.1',8091,False)
            run('core','nft','add','rule','ip','fixture_nat','prerouting',
                'ip','daddr','10.88.0.1','tcp','dport','8090','dnat','to','10.245.0.3:8008')
            http('backend','10.88.0.1',8090)
            http('edge-b', '10.245.0.3', 8008, False)
            http('outsider', '10.245.0.3', 8008, False)
            media_reply('192.0.2.14', False); media_reply('192.0.2.11')
            for port in (8090,8088):
                http('edge-b','10.88.0.1',port)
                http('outsider','10.88.0.1',port,False)
            http('edge-b','10.88.0.1',8091,False)
            http('edge-b','192.0.2.10',8088,False)
            http('edge-b','192.0.2.10',7981)
            http('outsider','192.0.2.10',7981,False)
            for port in (50300,50301):
                udp('edge-b',port); udp('outsider',port,False)
            http('outsider','192.0.2.10',9002)
            apply('core', inventory, 'core')
            table, _ = firewall_config.identity(inventory, 'edge-b')
            run('edge-b', 'nft', 'delete', 'table', 'inet', table)
            run('edge-b', 'python3', '/source/firewall_runtime.py', '--directory', '/state/firewall', '--resume')
            http('edge-b','10.88.0.1',8088)
            assert 'unrelated host policy' in run('core','nft','list','table','inet','fixture_foreign')
            assert 'prerouting' in run('core','nft','list','table','ip','fixture_nat')
            # One-host shape: only web/health may reach API, relay only media.
            apply('core', single, 'core')
            for name in ('web','health'):
                http(name,'10.88.0.1',8090); http(name,'10.88.0.1',8088)
            for name in ('relay','other'):
                http(name,'10.88.0.1',8090,False); http(name,'10.88.0.1',8088,False)
            http('relay','192.0.2.10',7981); udp('relay',50300); udp('relay',50301)
            media_reply('10.242.0.4'); media_reply('192.0.2.11', False)
            http('web','192.0.2.10',7981,False)
            http('edge-b','10.88.0.1',8088,False)
            http('outsider','192.0.2.10',9002)
            print('PASS: scoped INPUT/FORWARD, real WireGuard replies, DNAT original ports, media source ACL, private core callback INPUT/DNAT, co-located roles, unrelated tables retained', flush=True)
        except Exception:
            subprocess.run([*command, 'logs', '--tail', '12'], check=False)
            subprocess.run([*command, 'ps', '-a'], check=False)
            for name in ('core', 'backend', 'outsider'):
                subprocess.run([*command, 'exec', '-T', name, 'ip', '-4', 'address'], check=False)
                subprocess.run([*command, 'exec', '-T', name, 'ip', '-4', 'route'], check=False)
            subprocess.run([*command, 'exec', '-T', 'core', 'nft', 'list', 'ruleset'], check=False)
            raise
        finally:
            subprocess.run([*command, 'down', '--volumes', '--remove-orphans'], check=True)


if __name__ == '__main__': main()
