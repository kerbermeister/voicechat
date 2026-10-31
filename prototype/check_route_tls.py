"""Real Caddy/coturn TLS via one HAProxy port. Private CA; no system trust changes."""
import json
import argparse
import ipaddress
import os
from pathlib import Path
import secrets
import signal
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import uuid

from check_three_vps import ROOT, image
sys.path.insert(0, str(ROOT / 'infra'))
from edge_config import sni_proxy, edge_proxy


def run_process(arguments, *, check=True, timeout=90, capture_output=False):
    # Docker Desktop launches wrapper/CLI/plugin children. Killing only the
    # first PID on timeout leaves Compose running against a deleted fixture.
    with subprocess.Popen(arguments, start_new_session=True,
            stdout=subprocess.PIPE if capture_output else None,
            stderr=subprocess.PIPE if capture_output else None) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except BaseException:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.communicate()
            raise
    result = subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
    if check: result.check_returncode()
    return result


def certificate(root, name):
    key = root / (name + '.key')
    key.touch(mode=0o600)
    subprocess.run(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key),
        '-out', str(root / (name + '.csr')), '-subj', '/CN=' + name], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    extension = root / (name + '.ext')
    extension.write_text('subjectAltName=DNS:' + name + '\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n')
    subprocess.run(['openssl', 'x509', '-req', '-in', str(root / (name + '.csr')), '-CA', str(root / 'ca.crt'),
        '-CAkey', str(root / 'ca.key'), '-CAcreateserial', '-out', str(root / (name + '.crt')),
        '-days', '3', '-extfile', str(extension)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    # The containing directory is private; only disposable service containers read these keys.
    key.chmod(0o644)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--role-bundle', action='store_true', help='Run the generated edge role, including TURN initialization/readiness')
    parser.add_argument('--single-entry', action='store_true', help='Validate one edge assigned explicitly to the core host')
    parser.add_argument('--android-updates', action='store_true', help='Verify APK publication and withdrawal through the real edge TLS proxy')
    parser.add_argument('--activation', action='store_true', help='Exercise the full host TLS activation controller (Linux root only)')
    parser.add_argument('--cpus', type=float, default=.25, help='Per-service fixture CPU quota; use 1 on a disposable emulated VM')
    args = parser.parse_args()
    if not 0 < args.cpus <= 2: parser.error('--cpus must be greater than zero and at most 2')
    if args.activation and (not args.role_bundle or sys.platform != 'linux' or os.geteuid() != 0):
        parser.error('--activation requires --role-bundle on an isolated Linux root fixture')
    if args.android_updates and not args.role_bundle:
        parser.error('--android-updates requires --role-bundle')
    if args.single_entry and not args.role_bundle:
        parser.error('--single-entry requires --role-bundle')
    edge_id = 'probe-' + uuid.uuid4().hex[:12]
    project = 'voicechat-edge-' + edge_id
    with tempfile.TemporaryDirectory(prefix=project) as temporary:
        root = Path(temporary).resolve()
        (root / 'ca.key').touch(mode=0o600)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3',
            '-keyout', str(root / 'ca.key'), '-out', str(root / 'ca.crt'), '-subj', '/CN=Disposable VoiceChat CA',
            '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign'],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for name in ('web.routes.test', 'turn.routes.test'): certificate(root, name)
        (root / 'haproxy.cfg').write_text(sni_proxy(['web.routes.test'], 'turn.routes.test'))
        network_ids = subprocess.check_output(['docker','network','ls','-q'],text=True).split()
        networks = json.loads(subprocess.check_output(['docker','network','inspect',*network_ids])) if network_ids else []
        occupied = [ipaddress.ip_network(item['Subnet']) for network in networks
                    for item in (network.get('IPAM',{}).get('Config') or []) if item.get('Subnet')]
        if sys.platform == 'linux':
            routes = json.loads(subprocess.check_output(['ip', '-j', '-4', 'route', 'show', 'table', 'all'], timeout=15))
            occupied.extend(ipaddress.ip_network(item['dst'], strict=False) for item in routes
                            if item.get('dst', 'default') != 'default')
        free = ['10.240.' + str(i) for i in range(1,255)
                if not any(ipaddress.ip_network('10.240.' + str(i) + '.0/28').overlaps(n)
                           for n in occupied if n.version == 4)]
        if len(free) < 2: raise RuntimeError('No free Docker test subnets')
        prefix, backend_prefix = free[:2]
        topology = {'schema': 1, 'service_id': project, 'matrix_server_name': 'web.routes.test',
            'canonical_origin': 'https://web.routes.test',
            'web_origins': ['https://web.routes.test', 'https://backup.routes.test'],
            'edges': [{'id': edge_id, 'origin': 'https://web.routes.test', 'turn_host': 'turn.routes.test'},
                      {'id': 'c', 'origin': 'https://backup.routes.test', 'turn_host': 'turn-c.routes.test'}]}
        (root / 'Caddyfile').write_text(edge_proxy(topology, edge_id, prefix + '.5', prefix + '.2'))
        (root / 'upstream.py').write_text("""from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        value = {'versions':['v1.11']} if self.path == '/_matrix/client/versions' else {'ok':True} if self.path == '/health' else {'path':self.path,'headers':dict(self.headers)}
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
for port in (8088, 8090, 7880):
    threading.Thread(target=ThreadingHTTPServer(('0.0.0.0',port),Handler).serve_forever).start()
""")
        (root / 'turn.conf').write_text('''listening-port=3478
tls-listening-port=5349
cert=/tls/turn.routes.test.crt
pkey=/tls/turn.routes.test.key
fingerprint
use-auth-secret
static-auth-secret=''' + secrets.token_hex(32) + '''
realm=local-route-test
no-dtls
no-multicast-peers
cli=off
log-file=stdout
''')
        haproxy = json.loads((ROOT / 'infra/edge-images.json').read_text())['haproxy']
        caddy = (ROOT / 'infra/web.Dockerfile').read_text().splitlines()[0].split()[1]
        compose = root / 'compose.json'
        services = {
            'web': {'image': caddy, 'volumes': ['./Caddyfile:/etc/caddy/Caddyfile:ro', './web.routes.test.crt:/tls/web.crt:ro', './web.routes.test.key:/tls/web.key:ro'], 'depends_on': ['upstream']},
            'turn': {'image': image('turn'), 'command': ['-c', '/turn.conf'], 'volumes': ['./turn.conf:/turn.conf:ro', './turn.routes.test.crt:/tls/turn.routes.test.crt:ro', './turn.routes.test.key:/tls/turn.routes.test.key:ro']},
            'ingress': {'image': haproxy, 'ports': ['127.0.0.1::8443'], 'volumes': ['./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro'], 'depends_on': ['web','turn']},
            'upstream': {'image': image('configure'), 'entrypoint': ['python3', '/upstream.py'], 'volumes': ['./upstream.py:/upstream.py:ro']},
        }
        for service, last in [('ingress',2),('web',3),('turn',4),('upstream',5)]:
            services[service]['networks'] = {'default': {'ipv4_address': prefix + '.' + str(last)}}
        model = {'name':project, 'services':services,
                 'networks': {'default': {'ipam': {'config': [{'subnet':prefix + '.0/28'}]}}}}
        if args.role_bundle:
            from publish_catalog import publish
            from route_catalog import public_key, sign, verify
            from render_roles import bundle, write_bundle
            from test_node_inventory import fixture
            inventory = fixture()
            inventory['service_id'] = topology['service_id']
            inventory['edges'][0]['id'] = edge_id
            inventory['core']['tunnel_ip'] = backend_prefix + '.2'
            if args.single_entry:
                topology['edges'] = topology['edges'][:1]
                inventory['edges'] = [{'id':edge_id,'host':'core','legacy_turn':True}]
            files, runtime = bundle(topology, inventory, 'edge', edge_id, prefix + '.0/28')
            bundle_root = root / 'bundle'
            write_bundle(bundle_root, files, runtime)
            config_root = bundle_root / 'infra'
            compose = config_root / 'compose.edge.json'
            model = json.loads(compose.read_text())
            model['name'] = project
            services = model['services']
            # Test-only: random loopback ingress; no public TURN ports or real A.
            services['ingress']['ports'] = ['127.0.0.1::8443']
            if args.single_entry:
                assert '3488:3478/tcp' in services['turn']['ports'] and '3488:3478/udp' in services['turn']['ports']
                services['turn']['ports'] = ['127.0.0.1::3478/tcp', '127.0.0.1::3478/udp']
            else:
                services['turn']['ports'] = []
            services['web']['image'] = caddy
            # Test-only upstream substitution: this probe tests the proxy/role
            # process configuration, not host routing or WireGuard. Keep the
            # fixture on one bridge (multi-network attach is unreliable in the
            # local Docker runtime), without changing production generation.
            upstream_ip = prefix + '.7'
            proxy = config_root / 'Caddyfile'
            proxy.write_text(proxy.read_text().replace(backend_prefix + '.2', upstream_ip))
            services['route-health']['command'] = [value.replace(backend_prefix + '.2', upstream_ip)
                                                    for value in services['route-health']['command']]
            services['upstream'] = {'image':image('configure'), 'entrypoint':['python3','/upstream.py'],
                'volumes':[str(root / 'upstream.py') + ':/upstream.py:ro'],
                'networks':{'default':{'ipv4_address':upstream_ip}}}
            topology_file = root / 'tls-topology.json'
            topology_file.write_text(json.dumps(topology))
            publisher_code = root / 'tls-publisher-code'
            publisher_code.mkdir(mode=0o700)
            for filename in ('tls_runtime.py', 'tls_material.py', 'managed_state.py', 'topology.py', 'client_config.py'):
                shutil.copyfile(config_root / filename, publisher_code / filename)
            def install_certificate(name, target, *, certificate_file=None, key_file=None, activate_service=False):
                from check_tls_runtime import IMAGE as tls_image
                private_key = root / (name + '.private.key')
                private_key.touch(mode=0o600)
                shutil.copyfile(key_file or root / (name + '.key'), private_key)
                if args.activation and activate_service:
                    from tls_activation import activate
                    container = subprocess.check_output([*command, 'ps', '-q', target], text=True, timeout=15).strip()
                    result = activate(config_root / 'runtime/tls', topology, edge_id, target,
                        certificate_file or root / (name + '.crt'), private_key,
                        container=container, image=caddy if target == 'web' else image('turn'),
                        address='127.0.0.1', port=port, ca_file=root / 'ca.crt', minimum_validity_days=1)
                    assert not result['reload_required']
                    receipt = json.loads((config_root / 'runtime/tls' / (target + '.activation.json')).read_text())
                    assert receipt['phase'] == 'verified'
                    return os.readlink(config_root / 'runtime/tls' / target / 'current')
                mounts = [(publisher_code, '/bundle', True), (config_root / 'runtime/tls', '/tls', False),
                          (certificate_file or root / (name + '.crt'), '/certificate.pem', True),
                          (private_key, '/private.pem', True), (root / 'ca.crt', '/ca.pem', True),
                          (topology_file, '/topology.json', True)]
                # Exercise the actual publisher as Linux root. Unlike the old
                # fixture-only copy, TURN gets a 0640 root:10001 private key.
                helper = project + '-tls-' + target
                try:
                    run_process(['docker', 'run', '--rm', '--name', helper, '--pull', 'never', '--network', 'none',
                        '--memory', '128m', '--cpus', '.5',
                        '--read-only', '--cap-drop', 'ALL', '--cap-add', 'CHOWN', '--security-opt', 'no-new-privileges:true',
                        '--tmpfs', '/tmp:rw,nosuid,nodev,size=16m', '--env', 'PYTHONDONTWRITEBYTECODE=1',
                        *(argument for source, destination, readonly in mounts for argument in
                          ('--mount', f'type=bind,source={source},target={destination}' + (',readonly' if readonly else ''))),
                        tls_image, 'python3', '/bundle/tls_runtime.py', '--root', '/tls', '--topology', '/topology.json',
                        '--edge', edge_id, '--service', target, '--chain', '/certificate.pem', '--key', '/private.pem',
                        '--ca-file', '/ca.pem', '--minimum-validity-days', '1'], capture_output=True, timeout=60)
                finally:
                    run_process(['docker', 'rm', '--force', helper], check=False, capture_output=True, timeout=20)
                return os.readlink(config_root / 'runtime/tls' / target / 'current')
            for name, target in [('web.routes.test','web'),('turn.routes.test','turn')]:
                install_certificate(name, target)
            secret = config_root / 'runtime/turn-secret'
            secret.write_text(secrets.token_hex(32)); secret.chmod(0o600)
            catalog_key = root / 'test-only-catalog.pem'
            subprocess.run(['openssl','genpkey','-algorithm','ED25519','-out',str(catalog_key)],
                           check=True, capture_output=True)
            catalog_public = public_key(catalog_key)
            catalog_directory = config_root / 'runtime/catalog'
            now = int(time.time())
            initial_catalog = json.dumps(sign(topology, catalog_key, 1, now, now + 3600)).encode()
            publish(catalog_directory, initial_catalog, catalog_public, topology, initialize=True)
        for service in services.values():
            service.update(mem_limit='128m', cpus=args.cpus)
        compose.write_text(json.dumps(model))
        command = ['docker','compose','--parallel','1','-f',str(compose)]
        try:
            run_process([*command,'up','-d'])
            address = subprocess.check_output([*command,'port','ingress','8443'],text=True).strip()
            if not address.startswith('127.0.0.1:'): raise ValueError('Loopback ingress required')
            port = int(address.split(':')[1])
            trusted = ssl.create_default_context(cafile=str(root / 'ca.crt'))
            def connect(name, context=trusted):
                return context.wrap_socket(socket.create_connection(('127.0.0.1',port),timeout=3),server_hostname=name)
            deadline = time.monotonic() + 30
            while True:
                try:
                    with connect('web.routes.test') as stream:
                        stream.sendall(b'GET /api/echo HTTP/1.1\r\nHost: web.routes.test\r\nConnection: close\r\n\r\n')
                        body = b''
                        while part := stream.recv(4096): body += part
                        assert b'200 OK' in body and b'/echo' in body
                    break
                except (OSError, AssertionError):
                    if time.monotonic() >= deadline: raise
                    time.sleep(.2)
            def request(path, origin, method='GET'):
                with connect('web.routes.test') as stream:
                    # Allow Caddy's bounded upstream dial timeout to produce its
                    # HTTP error before the fixture gives up reading that error.
                    stream.settimeout(5)
                    stream.sendall((method + ' ' + path + ' HTTP/1.1\r\nHost: web.routes.test\r\nOrigin: ' + origin +
                        '\r\nForwarded: for=198.51.100.99\r\nX-Forwarded-For: 198.51.100.99\r\nX-Forwarded-Proto: http\r\nConnection: close\r\n\r\n').encode())
                    result = b''
                    while part := stream.recv(4096): result += part
                    return result
            if args.android_updates:
                import hashlib
                from unittest.mock import patch
                import android_release
                update_root = config_root / 'runtime/android-updates'
                candidate = root / 'android-candidate'; candidate.mkdir()
                def prepare_apk(build):
                    content = ('fixture-only-not-an-installable-apk-' + str(build)).encode()
                    data = dict(schema=1, applicationId=android_release.PACKAGE,
                        versionName='1.0.' + str(build), versionCode=build, minSdk=24,
                        apkPath='/updates/android/' + str(build) + '/voicechat.apk',
                        sizeBytes=len(content), sha256=hashlib.sha256(content).hexdigest(), notes='Fixture')
                    (candidate / 'voicechat.apk').write_bytes(content)
                    (candidate / 'latest.json').write_text(json.dumps(data))
                    return data, content
                def verify_apk(origin, data):
                    response = request(data['apkPath'], 'https://web.routes.test')
                    header, body = response.split(b'\r\n\r\n', 1)
                    assert b'200 OK' in header and b'application/vnd.android.package-archive' in header
                    assert b'immutable' in header and hashlib.sha256(body).hexdigest() == data['sha256']
                def pointer():
                    response = request('/updates/android/latest.json', 'https://web.routes.test')
                    header, body = response.split(b'\r\n\r\n', 1)
                    assert b'200 OK' in header and b'no-cache' in header
                    return json.loads(body)
                def processes():
                    ids = subprocess.check_output([*command, 'ps', '-q'], text=True).split()
                    return {v['Id']:v['State']['StartedAt'] for v in json.loads(
                        subprocess.check_output(['docker','inspect',*ids]))}
                before_updates = processes()
                first, _ = prepare_apk(2)
                android_release.publish(candidate, update_root, 'https://web.routes.test', verify=verify_apk)
                assert pointer() == first
                android_release.withdraw(update_root, 'https://web.routes.test')
                assert b'404 Not Found' in request('/updates/android/latest.json', 'https://web.routes.test')
                verify_apk('https://web.routes.test', first)
                android_release.publish(candidate, update_root, 'https://web.routes.test', verify=verify_apk)
                second, _ = prepare_apk(3)
                android_release.publish(candidate, update_root, 'https://web.routes.test', verify=verify_apk)
                assert pointer() == second
                android_release.publish(candidate, update_root, 'https://web.routes.test', verify=verify_apk)
                assert android_release.load_manifest(update_root / 'previous.json') == first
                with patch.object(android_release, 'verify_public', side_effect=verify_apk):
                    android_release.withdraw(update_root, 'https://web.routes.test')
                assert pointer() == first
                for private in ('previous.json', 'withdrawn.json', '.publish.lock', '2/manifest.json'):
                    assert b'404 Not Found' in request('/updates/android/' + private, 'https://web.routes.test')
                assert processes() == before_updates
                print('PASS: edge TLS APK publish/retry/withdraw/cache/private-files; service IDs/StartedAt unchanged', flush=True)
            response = request('/api/echo','https://backup.routes.test')
            assert b'200 OK' in response
            assert b'Access-Control-Allow-Origin: https://backup.routes.test' in response
            assert b'Access-Control-Allow-Origin: *' not in response
            assert b'198.51.100.99' not in response
            assert b'"X-Forwarded-Proto": "https"' in response
            assert b'403 Forbidden' in request('/api/echo','https://foreign.test')
            assert b'204 No Content' in request('/api/echo','https://backup.routes.test','OPTIONS')
            assert b'404 Not Found' in request('/_synapse/admin/v1/users','https://backup.routes.test')
            if args.role_bundle:
                deadline = time.monotonic() + 10
                while True:
                    try: ready = request('/health/route','https://backup.routes.test')
                    except OSError: ready = b''
                    if b'200 OK' in ready and b'"matrix":true' in ready and b'"control":true' in ready: break
                    if time.monotonic() >= deadline: raise AssertionError('Route readiness failed: ' + repr(ready))
                    time.sleep(.2)
                catalog = request('/.well-known/voicechat/routes.json','https://backup.routes.test')
                assert b'200 OK' in catalog and b'Cache-Control: no-store' in catalog
                assert catalog.split(b'\r\n\r\n', 1)[1] == initial_catalog
                web_id = subprocess.check_output([*command,'ps','-q','web'],text=True).strip()
                before = json.loads(subprocess.check_output(['docker','inspect',web_id]))[0]
                expanded = {**topology, 'edges': [*topology['edges'],
                    {'id':'d','origin':'https://new.routes.test','turn_host':'turn-d.routes.test'}]}
                updated_catalog = json.dumps(sign(expanded, catalog_key, 2, now, now + 3600)).encode()
                publish(catalog_directory, updated_catalog, catalog_public, topology)
                received = request('/.well-known/voicechat/routes.json','https://backup.routes.test').split(b'\r\n\r\n', 1)[1]
                assert received == updated_catalog
                assert verify(received, catalog_public, topology).topology == expanded
                try:
                    publish(catalog_directory, initial_catalog, catalog_public, topology)
                except ValueError:
                    pass
                else:
                    raise AssertionError('Catalog publication rollback accepted')
                assert request('/.well-known/voicechat/routes.json','https://backup.routes.test').split(b'\r\n\r\n', 1)[1] == updated_catalog
                after = json.loads(subprocess.check_output(['docker','inspect',web_id]))[0]
                assert before['State']['StartedAt'] == after['State']['StartedAt'] and before['RestartCount'] == after['RestartCount']
                print('PASS: signed catalog atomic update visible through running TLS proxy; rollback rejected; no proxy restart',flush=True)
                untrusted_proxy = f"""import socket,ssl
context=ssl.create_default_context(cadata={(root / 'ca.crt').read_text()!r})
stream=socket.create_connection(({prefix + '.3'!r},8443),timeout=3)
stream.sendall(b'PROXY TCP4 198.51.100.99 192.0.2.11 50000 8443\\r\\n')
try:
    context.wrap_socket(stream,server_hostname='web.routes.test')
except (OSError,ssl.SSLError):
    pass
else:
    raise AssertionError('Untrusted PROXY protocol source accepted')
"""
                run_process([*command,'exec','-T','upstream','python3','-c',untrusted_proxy])
            with connect('turn.routes.test') as stream:
                transaction = secrets.token_bytes(12)
                stream.sendall(struct.pack('!HHI', 1, 0, 0x2112a442) + transaction)
                response = b''
                while len(response) < 20:
                    part = stream.recv(20 - len(response))
                    if not part: raise OSError('TURN closed before its binding response')
                    response += part
                assert response[:2] == b'\x01\x01' and response[8:20] == transaction
            if args.role_bundle:
                from turn_tls_probe import check_policy, authenticated_allocation, exchange, attribute
                old_secret = secret.read_text()
                with connect('turn.routes.test') as stream:
                    check_policy(stream, old_secret)
                with connect('turn.routes.test') as stream:
                    authenticated_allocation(stream, old_secret, lifetime=-60, rejected=True)
                if args.single_entry:
                    def legacy_port(protocol):
                        value = subprocess.check_output([*command, 'port', '--protocol', protocol, 'turn', '3478'], text=True).strip()
                        host, port = value.rsplit(':', 1)
                        assert host == '127.0.0.1'
                        return int(port)
                    with socket.create_connection(('127.0.0.1', legacy_port('tcp')), timeout=10) as stream:
                        check_policy(stream, old_secret)
                    with socket.create_connection(('127.0.0.1', legacy_port('tcp')), timeout=10) as stream:
                        authenticated_allocation(stream, old_secret, lifetime=-60, rejected=True)
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as stream:
                        stream.settimeout(10)
                        transaction = secrets.token_bytes(12)
                        stream.sendto(struct.pack('!HHI', 1, 0, 0x2112a442) + transaction, ('127.0.0.1', legacy_port('udp')))
                        response, _ = stream.recvfrom(4096)
                        assert response[:2] == b'\x01\x01' and response[8:20] == transaction
                    print('PASS: legacy TURN mapping, authenticated TCP allocation/private-peer denial/expiry and UDP binding (no media)', flush=True)
                identifiers = subprocess.check_output([*command, 'ps', '-q', 'web', 'turn'], text=True).split()
                def processes():
                    return subprocess.check_output(['docker', 'inspect', '--format',
                        '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}', *identifiers], text=True)
                before_reload = processes()
                old_versions = {target: os.readlink(config_root / 'runtime/tls' / target / 'current')
                                for target in ('web', 'turn')}
                old_certificates = {}
                for name in ('web.routes.test', 'turn.routes.test'):
                    with connect(name) as stream: old_certificates[name] = stream.getpeercert(binary_form=True)
                with connect('turn.routes.test') as turn_stream:
                    auth, turn_key = authenticated_allocation(turn_stream, old_secret)
                    expected = {}
                    original_files = {}
                    for name, target in [('web.routes.test', 'web'), ('turn.routes.test', 'turn')]:
                        original_files[target] = {}
                        for suffix in ('crt', 'key'):
                            original_file = root / ('original-' + name + '.' + suffix)
                            original_file.touch(mode=0o600)
                            shutil.copyfile(root / (name + '.' + suffix), original_file)
                            original_files[target][suffix] = original_file
                        certificate(root, name)
                        install_certificate(name, target, activate_service=True)
                        expected[name] = ssl.PEM_cert_to_DER_cert((root / (name + '.crt')).read_text())
                        assert expected[name] != old_certificates[name]
                    def reload_certificates(certificates):
                        if not args.activation:
                            run_process([*command, 'kill', '-s', 'SIGUSR1', 'web'])
                            run_process([*command, 'kill', '-s', 'SIGUSR2', 'turn'])
                        deadline = time.monotonic() + 10
                        for name, expected_certificate in certificates.items():
                            while True:
                                with connect(name) as stream:
                                    if stream.getpeercert(binary_form=True) == expected_certificate: break
                                if time.monotonic() >= deadline: raise AssertionError('TLS reload did not select certificate')
                                time.sleep(.1)
                        # Caddy drains the old HTTP server on config reload and
                        # can close idle keep-alive sockets. Fresh API requests
                        # must work; this does not prove WSS continuity.
                        assert b'200 OK' in request('/api/echo', 'https://backup.routes.test')
                        kind, _ = exchange(turn_stream, 4, [attribute(0x000d, struct.pack('!I', 60)), *auth], turn_key)
                        assert kind == 0x0104, 'Existing TURN allocation lost during TLS reload'
                        assert processes() == before_reload, 'TLS renewal restarted a container'
                    reload_certificates(expected)
                    # Rollback through the same publisher revalidates the old
                    # pair, including its remaining validity and identity.
                    for target, previous in old_versions.items():
                        selected = install_certificate(target + '.routes.test', target,
                            certificate_file=original_files[target]['crt'], key_file=original_files[target]['key'], activate_service=True)
                        assert selected == previous
                    reload_certificates(old_certificates)
                if args.activation: print('PASS: host activation controller verified container identity, read-only mounts, same processes and TLS certificates under one lock', flush=True)
                print('PASS: atomic TLS pair selection, signal reload and rollback; same processes, fresh HTTPS and existing TURN allocation verified (not WSS continuity)', flush=True)
                new_secret = secrets.token_hex(32)
                def rotate(values):
                    secret.write_text('\n'.join(values))
                    run_process([*command,'run','--rm','--no-deps','configure'])
                    run_process([*command,'up','-d','--no-deps','--force-recreate','turn'])
                    deadline = time.monotonic() + 15
                    while True:
                        try:
                            with connect('turn.routes.test') as stream:
                                check_policy(stream, new_secret)
                            break
                        except OSError:
                            if time.monotonic() >= deadline: raise
                            time.sleep(.2)
                rotate([old_secret, new_secret])
                with connect('turn.routes.test') as stream:
                    check_policy(stream, old_secret)
                rotate([new_secret])
                with connect('turn.routes.test') as stream:
                    authenticated_allocation(stream, old_secret, rejected=True)
                print('PASS: TURN secret overlap accepts old/new; retirement rejects old; expired credentials rejected',flush=True)
                run_process([*command,'stop','-t','1','upstream'])
                deadline = time.monotonic() + 10
                while True:
                    failed = request('/health/route','https://backup.routes.test')
                    if b'503 Service Unavailable' in failed and b'"matrix":false' in failed and b'"control":false' in failed: break
                    if time.monotonic() >= deadline: raise AssertionError('Upstream failure not reported')
                    time.sleep(.2)
                marker = 'test-only-no-request-log-' + secrets.token_hex(8)
                assert b'502 Bad Gateway' in request('/api/echo?access_token=' + marker,'https://backup.routes.test')
                web_log = subprocess.check_output([*command,'logs','web'],text=True)
                assert marker not in web_log, 'Request query leaked into edge logs'
                print('PASS: generated edge role, private upstream, catalog/readiness/failure, authenticated TURN TLS allocation, private/metadata peers denied, PROXY trust and no request logs',flush=True)
            for name, context in [('unknown.routes.test',trusted), ('web.routes.test',ssl.create_default_context())]:
                try:
                    with connect(name, context): pass
                except (OSError, ssl.SSLError): pass
                else: raise AssertionError('Untrusted certificate or SNI was accepted')
            print('PASS: one TLS ingress port, HTTPS and coturn binding via SNI, trusted CA/hostname, CORS/private routes/forwarded headers, unknown SNI and untrusted CA rejected',flush=True)
        except Exception:
            run_process([*command,'logs','--tail','60'],check=False,timeout=20)
            if args.role_bundle:
                run_process([*command,'exec','-T','web','ip','route'],check=False,timeout=20)
            raise
        finally:
            run_process([*command,'down','--volumes','--remove-orphans'])


if __name__ == '__main__': main()
