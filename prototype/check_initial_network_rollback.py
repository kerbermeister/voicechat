"""Exercise initial network rollback on the explicitly marked disposable VM.

No application data is created. Preserve the saved private intent/key and an
unrelated live Docker HTTP service across retirement and same-intent restoration.
"""
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import firewall_config
import managed_state
import network_bootstrap
import network_runtime
import role_config
import role_deploy
from tunnel_config import physical_nodes


def main():
    base = Path('/srv/voicechat-edge-fixture')
    if sys.platform != 'linux' or os.geteuid() != 0 or not base.is_dir() or base.is_symlink():
        raise ValueError('Use the marked disposable Linux VM')
    key = ' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    if json.loads((base / '.disposable-vm').read_text()) != {
            'kind': 'voicechat-disposable-vm', 'ssh_host_key_sha256': hashlib.sha256(key.encode()).hexdigest()}:
        raise ValueError('Disposable VM marker differs from this host')
    directory = Path('/var/lib/voicechat-network')
    desired_bytes = (directory / 'desired.json').read_bytes()
    desired = managed_state.read(directory / 'desired.json')
    if desired['node'] != 'core' or set(physical_nodes(desired['inventory'])) != {'core'}:
        raise ValueError('Only the disposable peerless core fixture is supported')
    run = role_deploy.run
    rows = run(['docker', 'ps', '-a', '--format', '{{.Label "com.docker.compose.project"}}']).decode().splitlines()
    if any(row == 'voicechat' or row.startswith('voicechat-edge-') for row in rows):
        raise ValueError('Finish and clean up the core/edge fixture first')
    name = 'vc-network-rollback-' + uuid.uuid4().hex[:10]
    identifier = None
    code = '''from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'network-rollback-neighbor')
HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
'''
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def command(*args): return run(list(args)).decode()
    def http():
        with opener.open('http://127.0.0.1:18090/', timeout=3) as response:
            if response.status != 200 or response.read(128) != b'network-rollback-neighbor':
                raise ValueError('Unrelated HTTP fixture is unavailable')
    def snapshot():
        process = command('docker', 'inspect', '--format', '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}', identifier)
        engine = command('systemctl', 'show', 'docker.service', '--property=MainPID', '--value')
        return process, engine
    def tables():
        return {(item['table']['family'], item['table']['name'])
                for item in json.loads(command('nft', '-j', 'list', 'tables'))['nftables'] if 'table' in item}
    try:
        identifier = command('docker', 'run', '-d', '--name', name, '--label', 'voicechat.fixture=' + name,
            '--restart', 'unless-stopped', '--memory', '64m', '--cpus', '.25', '--pids-limit', '64',
            '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
            '--tmpfs', '/tmp:size=16m', '--env', 'PYTHONDONTWRITEBYTECODE=1',
            '--publish', '127.0.0.1:18090:8080', '--entrypoint', 'python3',
            role_config.pinned_image('configure'), '-u', '-c', code).strip()
        deadline = time.monotonic() + 30
        while True:
            try:
                http(); break
            except OSError:
                if time.monotonic() >= deadline: raise
                time.sleep(.2)
        before = snapshot()
        network_bootstrap.upgrade(shared_host=True, run=command)
        if snapshot() != before: raise AssertionError('Network source upgrade restarted a neighbor')
        fingerprint = network_runtime.fingerprint(desired)
        public_key = command('wg', 'show', 'wg-vc', 'public-key')
        table, _ = firewall_config.identity(desired['inventory'], 'core')
        foreign = tables() - {('inet', table)}
        def interrupted_delete(*args):
            result = command(*args)
            if args == ('ip', 'link', 'delete', 'wg-vc'): raise SystemExit('Lost real interface deletion response')
            return result
        try: network_bootstrap.retire_initial(Path('/'), fingerprint, run=interrupted_delete)
        except SystemExit: pass
        else: raise AssertionError('Expected interrupted real retirement')
        http()
        try: network_runtime.reconcile(directory)
        except ValueError as error:
            if 'retired' not in str(error): raise
        else: raise AssertionError('Retired intent must not resurrect its interface')
        network_bootstrap.retire_initial(Path('/'), fingerprint, run=command)
        if tables() != foreign: raise AssertionError('Unrelated firewall tables changed')
        if snapshot() != before: raise AssertionError('Retirement restarted Docker or its neighbor')
        http()
        try: network_bootstrap.install(shared_host=True, run=command)
        except ValueError as error:
            if 'explicit initial' not in str(error): raise
        else: raise AssertionError('Restoration must require explicit same-intent ownership')
        def interrupted_start(*args):
            result = command(*args)
            if args == ('systemctl', 'start', 'voicechat-network.service'):
                raise SystemExit('Lost real restoration response')
            return result
        try:
            network_bootstrap.install(shared_host=True, restore_initial=fingerprint, run=interrupted_start)
        except SystemExit: pass
        else: raise AssertionError('Expected interrupted real restoration')
        try:
            with role_deploy.network_ready(desired['inventory'], 'core', desired['edge_subnet']): pass
        except ValueError as error:
            if 'rollback/restoration' not in str(error): raise
        else: raise AssertionError('Role deployment must remain fenced before restore commit')
        network_bootstrap.install(shared_host=True, restore_initial=fingerprint, run=command)
        with role_deploy.network_ready(desired['inventory'], 'core', desired['edge_subnet']): pass
        if command('wg', 'show', 'wg-vc', 'public-key') != public_key:
            raise AssertionError('Restoration changed WireGuard identity')
        if (directory / 'desired.json').read_bytes() != desired_bytes:
            raise AssertionError('Initial rollback replaced saved private intent')
        if tables() - {('inet', table)} != foreign or snapshot() != before:
            raise AssertionError('Restoration changed an unrelated host resource')
        http()
        result = {'schema': 1, 'production_changed': False,
            'actual_interface_retirement_lost_response_resumed': True,
            'retired_network_did_not_auto_reapply': True,
            'actual_systemd_restore_lost_response_resumed': True,
            'role_deployment_fenced_until_restore_commit': True,
            'wireguard_key_and_private_intent_preserved': True,
            'neighbor_http_docker_process_and_foreign_tables_preserved': True,
            'limits': ['Marked disposable peerless core VM; no production data or legacy adoption.',
                       'This operation is forbidden for normal multi-host peer replacement/revocation.']}
    finally:
        if identifier:
            label = command('docker', 'inspect', '--format', '{{index .Config.Labels "voicechat.fixture"}}', identifier).strip()
            if label != name: raise ValueError('Unknown neighbor container must be preserved')
            command('docker', 'rm', '-f', identifier)
    result['neighbor_fixture_removed'] = True
    print(json.dumps(result))


if __name__ == '__main__': main()
