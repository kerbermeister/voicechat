"""Exercise rendered WireGuard configs in isolated Linux network namespaces.

Requires a local tools image with wg-quick, iproute2, ping and Python. This is a
kernel/peer proof, not a VPS bootstrap or production firewall acceptance test.
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
import tunnel_config as tunnel
from test_node_inventory import fixture, key


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools-image', required=True, help='Local immutable sha256 image ID')
    args = parser.parse_args()
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', args.tools_image):
        raise ValueError('Resolve the local fixture image ID before running')
    project = 'voicechat-tunnel-' + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix=project) as temporary:
        root = Path(temporary)
        inventory = fixture()
        registry = {'schema': 1, 'service_id': inventory['service_id'], 'nodes': {}}
        private = {}
        endpoints = {}
        for name in tunnel.physical_nodes(inventory):
            (root / name).mkdir()
            path = root / name / 'private.key'
            registry['nodes'][name] = {'generation': 1, 'public_key': tunnel.ensure_key(path)}
            private[name] = tunnel.read_private(path)

        def content(name):
            value = tunnel.render(inventory, registry, name, private[name])
            # Only the fixture endpoints change: Docker DNS names replace the
            # synthetic public IPs. Keys, AllowedIPs and tunnel addresses are real.
            for identity, node in tunnel.physical_nodes(inventory).items():
                value = value.replace('Endpoint = ' + node['public_ip'] + ':51820',
                                      'Endpoint = ' + endpoints.get(identity, identity) + ':51820')
            return value

        services = {}
        for name in private:
            config = root / name / 'wg-vc.conf'
            config.write_text(content(name)); config.chmod(0o600)
            start = 'wg-quick up /config/wg-vc.conf && '
            start += ('exec python3 -m http.server 8088 --bind 10.88.0.1 --directory /empty'
                      if name == 'core' else 'exec sleep infinity')
            services[name] = {'image': args.tools_image,
                'cap_add': ['NET_ADMIN'], 'sysctls': {'net.ipv4.ip_forward': '0'},
                'entrypoint': ['/bin/sh', '-ec', start],
                'volumes': ['./' + name + ':/config:ro'], 'tmpfs': ['/empty'],
                'healthcheck': {'test': ['CMD', 'wg', 'show', 'wg-vc', 'public-key'],
                                'interval': '1s', 'timeout': '2s', 'retries': 15}}
        compose = root / 'compose.json'
        compose.write_text(json.dumps({'name': project, 'services': services,
                                       'networks': {'default': {'internal': True}}}))
        command = ['docker', 'compose', '-f', str(compose)]

        def run(*parts):
            return subprocess.check_output([*command, *parts], text=True, stderr=subprocess.PIPE, timeout=15).strip()

        def fetch(name, succeeds=True):
            script = ('import urllib.request; '
                      'assert urllib.request.urlopen("http://10.88.0.1:8088",timeout=2).status == 200')
            deadline = time.monotonic() + 12
            while True:
                result = subprocess.run([*command, 'exec', '-T', name, 'python3', '-c', script],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if result.returncode == 0 or not succeeds or time.monotonic() >= deadline: break
                # All peers start together; a first handshake can precede the
                # other interface's creation. Allow WireGuard's handshake retry.
                time.sleep(0.2)
            if (result.returncode == 0) != succeeds:
                raise AssertionError('Unexpected private API reachability for ' + name + ': ' + result.stderr.decode()[-2000:])

        try:
            subprocess.run([*command, 'up', '-d', '--wait', '--wait-timeout', '30'], check=True)
            core_id = run('ps', '-q', 'core')
            core_started = subprocess.check_output(['docker', 'inspect', '--format', '{{.State.StartedAt}}', core_id], text=True)
            for name in private:
                # Preserve the address while that container is stopped: Docker
                # removes stopped names from DNS, unlike our public-IP inventory.
                endpoints[name] = subprocess.check_output(['docker', 'inspect', '--format',
                    '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', run('ps', '-q', name)], text=True).strip()
                assert run('exec', '-T', name, 'wg', 'show', 'wg-vc', 'public-key') == registry['nodes'][name]['public_key']
            for name in ('edge-b', 'edge-c'): fetch(name)
            before_key = run('exec', '-T', 'core', 'wg', 'show', 'wg-vc', 'public-key')
            assert before_key == registry['nodes']['core']['public_key']
            subprocess.run([*command, 'stop', '-t', '1', 'edge-b'], check=True)
            fetch('edge-c')
            previous_key = registry['nodes']['edge-b']['public_key']
            replacement = root / 'edge-b' / 'replacement.key'
            new_public = tunnel.ensure_key(replacement)
            inventory = deepcopy(inventory)
            inventory['edges'][0].update(generation=2, ssh_host_key=key(9))
            registry['nodes']['edge-b'] = {'generation': 2, 'public_key': new_public}
            private['edge-b'] = tunnel.read_private(replacement)
            sync = root / 'core' / 'sync.conf'
            sync.write_text('\n'.join(line for line in content('core').splitlines()
                                      if not line.startswith('Address = ')) + '\n')
            sync.chmod(0o600)
            run('exec', '-T', 'core', 'wg', 'syncconf', 'wg-vc', '/config/sync.conf')
            peers = run('exec', '-T', 'core', 'wg', 'show', 'wg-vc', 'peers').splitlines()
            assert previous_key not in peers and new_public in peers
            assert run('exec', '-T', 'core', 'wg', 'show', 'wg-vc', 'public-key') == before_key
            fetch('edge-c')
            # The old machine/configuration can no longer reach the private API.
            subprocess.run([*command, 'up', '-d', '--no-recreate', '--wait', '--wait-timeout', '20', 'edge-b'], check=True)
            fetch('edge-b', succeeds=False)
            subprocess.run([*command, 'stop', '-t', '1', 'edge-b'], check=True)
            (root / 'edge-b' / 'wg-vc.conf').write_text(content('edge-b'))
            subprocess.run([*command, 'up', '-d', '--no-recreate', '--wait', '--wait-timeout', '20', 'edge-b'], check=True)
            fetch('edge-b'); fetch('edge-c')
            assert subprocess.check_output(['docker', 'inspect', '--format', '{{.State.StartedAt}}', core_id], text=True) == core_started
            print('PASS: independent B/C tunnels, live B key replacement, old key denied, core/C uninterrupted', flush=True)
            # One physical host needs the private interface even with no peers.
            single = {**inventory, 'edges': [{'id': 'a', 'host': 'core'}]}
            keys = {**registry, 'nodes': {'core': registry['nodes']['core']}}
            value = tunnel.render(single, keys, 'core', private['core'])
            sync.write_text('\n'.join(line for line in value.splitlines() if not line.startswith('Address = ')) + '\n')
            run('exec', '-T', 'core', 'wg', 'syncconf', 'wg-vc', '/config/sync.conf')
            assert run('exec', '-T', 'core', 'wg', 'show', 'wg-vc', 'peers') == ''
            fetch('core')
            print('PASS: private core address remains usable with a single co-located entry and zero peers', flush=True)
        except Exception:
            for name in private:
                for query in (['ip', 'route'], ['wg', 'show', 'wg-vc', 'latest-handshakes'],
                              ['wg', 'show', 'wg-vc', 'endpoints']):
                    subprocess.run([*command, 'exec', '-T', name, *query], check=False)
            subprocess.run([*command, 'logs', '--tail', '20'], check=False)
            raise
        finally:
            subprocess.run([*command, 'down', '--volumes', '--remove-orphans'], check=True)


if __name__ == '__main__': main()
