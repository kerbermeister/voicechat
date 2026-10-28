"""Real managed WireGuard reconciliation in disposable Linux containers.

Only an internal documentation-address bridge, NET_ADMIN within each container,
synthetic node keys and disposable volumes. No host networking, SSH or DNS edits.
"""
import argparse
from copy import deepcopy
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
import tunnel_config
from test_node_inventory import fixture, key


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools-image', required=True)
    parser.add_argument('--with-firewall', action='store_true', help='Exercise the coordinated network runtime')
    args = parser.parse_args()
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', args.tools_image):
        raise ValueError('Use an immutable local test image ID')
    project = 'voicechat-managed-wg-' + uuid.uuid4().hex[:12]
    runtime = 'network_runtime.py' if args.with_firewall else 'tunnel_runtime.py'
    with tempfile.TemporaryDirectory(prefix=project) as directory:
        root = Path(directory)
        inventory = fixture()
        registry = {'schema': 1, 'service_id': inventory['service_id'], 'nodes': {}}
        names = {'core': ('core', '192.0.2.10'), 'edge-b': ('edge-b', '192.0.2.11'),
                 'edge-c': ('edge-c', '192.0.2.12'), 'replacement-b': ('edge-b', '192.0.2.13'),
                 'edge-d': ('edge-d', '192.0.2.14')}
        keys = {}
        services = {}
        for name, (identity, address) in names.items():
            keys[name] = tunnel_config.ensure_key(root / (name + '.key'))
            if name in ('core', 'edge-b', 'edge-c'):
                registry['nodes'][identity] = {'generation': 1, 'public_key': keys[name]}
            start = f'''if [ -f /state/managed/desired.json ]; then
  python3 /source/{runtime} --directory /state/managed --resume
else
  cp /input/{name}.key /state/private.key
  chmod 600 /state/private.key
  python3 /source/{runtime} --directory /state/managed --inventory /input/inventory.json --public-keys /input/public-keys.json --node {identity} --private-key /state/private.key
fi
'''
            start += ('exec python3 -m http.server 8088 --bind 10.88.0.1 --directory /empty'
                      if name == 'core' else 'exec sleep infinity')
            services[name] = {'image': args.tools_image, 'cap_add': ['NET_ADMIN'],
                'sysctls': {'net.ipv4.ip_forward': '0'}, 'entrypoint': ['/bin/sh', '-ec', start],
                'environment': {'PYTHONDONTWRITEBYTECODE': '1'},
                'volumes': [str(ROOT / 'infra') + ':/source:ro', str(root) + ':/input:ro', name + '-state:/state'],
                'tmpfs': ['/empty'], 'networks': {'default': {'ipv4_address': address}},
                'healthcheck': {'test': ['CMD', 'wg', 'show', 'wg-vc', 'public-key'],
                                'interval': '1s', 'timeout': '2s', 'retries': 20}}

        def write_inputs():
            (root / 'inventory.json').write_text(json.dumps(inventory))
            (root / 'public-keys.json').write_text(json.dumps(registry))

        write_inputs()
        compose = root / 'compose.json'
        compose.write_text(json.dumps({'name': project, 'services': services,
            'volumes': {name + '-state': {} for name in names},
            'networks': {'default': {'internal': True, 'ipam': {'config': [{'subnet': '192.0.2.0/28'}]}}}}))
        command = ['docker', 'compose', '-f', str(compose)]

        def run(*parts):
            result = subprocess.run([*command, *parts], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, timeout=30)
            if result.returncode:
                raise RuntimeError('Fixture operation failed: ' + ' '.join(parts[:4]) + '\n' + result.stderr[-2000:])
            return result.stdout.strip()

        def apply_core():
            run('exec', '-T', 'core', 'python3', '/source/' + runtime,
                '--directory', '/state/managed', '--inventory', '/input/inventory.json',
                '--public-keys', '/input/public-keys.json', '--node', 'core', '--private-key', '/state/private.key')

        def fetch(name, succeeds=True):
            script = ('import urllib.request; '
                      'assert urllib.request.urlopen("http://10.88.0.1:8088",timeout=2).status == 200')
            deadline = time.monotonic() + 12
            while True:
                result = subprocess.run([*command, 'exec', '-T', name, 'python3', '-c', script],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
                if not succeeds or result.returncode == 0 or time.monotonic() >= deadline: break
                time.sleep(0.2)
            if (result.returncode == 0) != succeeds:
                raise AssertionError('Unexpected private API reachability: ' + name)

        def routes():
            return json.loads(run('exec', '-T', 'core', 'ip', '-j', '-4', 'route', 'show', 'dev', 'wg-vc'))

        try:
            subprocess.run([*command, 'up', '-d', '--wait', '--wait-timeout', '40', 'core', 'edge-b', 'edge-c'], check=True)
            core_id = run('ps', '-q', 'core')
            started = subprocess.check_output(['docker', 'inspect', '--format', '{{.State.StartedAt}}', core_id], text=True)
            fetch('edge-b'); fetch('edge-c')
            apply_core(); apply_core()
            assert len(routes()) == 2
            inventory = deepcopy(inventory)
            inventory['edges'][0].update(public_ip='192.0.2.13', generation=2, ssh_host_key=key(9))
            registry['nodes']['edge-b'] = {'generation': 2, 'public_key': keys['replacement-b']}
            write_inputs(); apply_core()
            fetch('edge-b', succeeds=False); fetch('edge-c')
            subprocess.run([*command, 'up', '-d', '--wait', '--wait-timeout', '40', 'replacement-b'], check=True)
            fetch('replacement-b')
            inventory['edges'].append({'id': 'd', 'generation': 1, 'public_ip': '192.0.2.14',
                                      'tunnel_ip': '10.88.0.4', 'ssh_host_key': key(10)})
            registry['nodes']['edge-d'] = {'generation': 1, 'public_key': keys['edge-d']}
            write_inputs(); apply_core()
            subprocess.run([*command, 'up', '-d', '--wait', '--wait-timeout', '40', 'edge-d'], check=True)
            fetch('edge-d'); fetch('edge-c'); fetch('replacement-b')
            assert len(routes()) == 3
            assert subprocess.check_output(['docker', 'inspect', '--format', '{{.State.StartedAt}}', core_id], text=True) == started
            # Restore only the saved desired state after the runtime namespace is lost.
            run('exec', '-T', 'core', 'ip', 'link', 'del', 'dev', 'wg-vc')
            run('exec', '-T', 'core', 'python3', '/source/' + runtime, '--directory', '/state/managed', '--resume')
            fetch('edge-c'); fetch('edge-d'); fetch('replacement-b')
            assert len(routes()) == 3
            subprocess.run([*command, 'stop', '-t', '1', 'core'], check=True)
            subprocess.run([*command, 'up', '-d', '--no-recreate', '--wait', '--wait-timeout', '40', 'core'], check=True)
            fetch('edge-c'); fetch('edge-d'); fetch('replacement-b')
            assert run('exec', '-T', 'core', 'wg', 'show', 'wg-vc', 'public-key') == keys['core']
            # Retire remote entries while preserving the single-host private address.
            inventory['edges'] = [{'id': 'a', 'host': 'core'}]
            registry['nodes'] = {'core': registry['nodes']['core']}
            write_inputs(); apply_core()
            assert routes() == []
            assert run('exec', '-T', 'core', 'wg', 'show', 'wg-vc', 'peers') == ''
            fetch('core'); fetch('edge-c', succeeds=False)
            print('PASS: ' + runtime + ': managed repeat, B replacement, D addition, route reconciliation, saved-state recreation/restart, zero-peer A', flush=True)
        except Exception:
            # Never print desired.json, private key, showconf or wg dump.
            for name in names:
                for query in (['ip', '-4', 'route'], ['wg', 'show', 'wg-vc', 'latest-handshakes']):
                    subprocess.run([*command, 'exec', '-T', name, *query], check=False)
            subprocess.run([*command, 'logs', '--tail', '15'], check=False)
            raise
        finally:
            subprocess.run([*command, 'down', '--volumes', '--remove-orphans'], check=True)


if __name__ == '__main__': main()
