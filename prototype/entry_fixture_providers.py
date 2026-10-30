"""Synthetic HTTPS registry/DuckDNS for the marked, isolated entry VM drill.

No production credentials or endpoints are used. VM-only hosts/NAT map the two
provider names here so the unmodified operator follows their real wire protocols.
This is not evidence of live GHCR/DuckDNS account acceptance.
"""
import argparse
import hashlib
import http.server
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import ssl
import subprocess
import tarfile
import threading
import time
import urllib.parse


def owned(root):
    if os.geteuid() != 0 or root.resolve() != root or root.parent != Path('/srv') or not root.name.startswith('voicechat-entry-fixture-'):
        raise ValueError('Named disposable entry fixture required')
    marker = root / '.disposable-vm'
    if marker.is_symlink() or marker.stat().st_uid != 0 or marker.stat().st_mode & 0o077:
        raise ValueError('Private disposable marker required')
    value = json.loads(marker.read_text())
    host = ' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    if value != {'kind': 'voicechat-entry-lifecycle-fixture', 'ssh_host_key_sha256': hashlib.sha256(host.encode()).hexdigest()}:
        raise ValueError('Fixture marker belongs to another host')


def save(path, value):
    temporary = path.with_name(path.name + '.next')
    with temporary.open('w') as output:
        os.chmod(temporary, 0o600); json.dump(value, output); output.flush(); os.fsync(output.fileno())
    os.replace(temporary, path)


def build(root):
    owned(root)
    output = root / 'registry'; output.mkdir(mode=0o700, exist_ok=True)
    blobs = output / 'blobs'; blobs.mkdir(mode=0o700, exist_ok=True)
    manifests = output / 'manifests'; manifests.mkdir(mode=0o700, exist_ok=True)
    repositories = {}
    for kind, expected in json.loads((root / 'expected-images.json').read_text()).items():
        if kind not in ('web', 'control'): raise ValueError('Only the two synthetic application images allowed')
        tag = 'ghcr.io/voicechat-fixture/mesh-' + kind + ':fixture'
        actual = subprocess.check_output(['docker', 'image', 'inspect', '--format', '{{.Id}}', tag]).decode().strip()
        if actual != expected: raise ValueError('Fixture image tag changed')
        archive = root / ('raw-' + kind + '.tar')
        if not archive.exists(): subprocess.run(['docker', 'image', 'save', '-o', str(archive), tag], check=True, capture_output=True)
        with tarfile.open(archive) as saved:
            seen = {}; manifest_types = {}; active = set()
            def copy(digest, size=None):
                if not re.fullmatch(r'sha256:[a-f0-9]{64}', digest): raise ValueError('Invalid image descriptor digest')
                if digest in seen:
                    if size is not None and size != seen[digest]: raise ValueError('Conflicting descriptor size')
                    return
                checksum = digest.removeprefix('sha256:')
                item = saved.getmember('blobs/sha256/' + checksum)
                if not item.isfile() or item.size > 1024**3 or (size is not None and size != item.size):
                    raise ValueError('Unexpected image blob')
                temporary = output / 'blob.next'; hashed = hashlib.sha256()
                with saved.extractfile(item) as stream, temporary.open('wb') as target:
                    while True:
                        chunk = stream.read(1024 * 1024)
                        if not chunk: break
                        hashed.update(chunk); target.write(chunk)
                if hashed.hexdigest() != checksum: raise ValueError('Saved image blob digest changed')
                destination = blobs / checksum
                if destination.exists(): temporary.unlink()
                else: os.rename(temporary, destination)
                seen[digest] = item.size
            def walk(digest, media=None, size=None):
                if digest in active or len(seen) > 256: raise ValueError('Invalid image graph')
                copy(digest, size)
                if digest in manifest_types: return
                path = blobs / digest.removeprefix('sha256:')
                if path.stat().st_size > 1024 * 1024: raise ValueError('Oversized image manifest')
                value = json.loads(path.read_bytes()); actual_media = value.get('mediaType')
                if media is not None and actual_media != media: raise ValueError('Image media type changed')
                indexes = ('application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json')
                singles = ('application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json')
                if value.get('schemaVersion') != 2 or actual_media not in indexes + singles:
                    raise ValueError('Unsupported synthetic image manifest')
                active.add(digest)
                if actual_media in indexes:
                    for child in value['manifests']: walk(child['digest'], child['mediaType'], child['size'])
                else:
                    for child in [value['config'], *value['layers']]: copy(child['digest'], child['size'])
                active.remove(digest); manifest_types[digest] = actual_media
                (manifests / (digest.removeprefix('sha256:') + '.json')).write_bytes(path.read_bytes())
            # Docker's containerd store exposes an OCI index as .Id, rather than
            # the config digest. Preserve and verify its entire saved graph.
            walk(actual)
            name = 'voicechat-fixture/mesh-' + kind
            repositories[name] = {'digest': actual, 'blobs': sorted(seen), 'manifests': manifest_types}
    save(output / 'repositories.json', repositories)
    print(json.dumps({'schema': 1, 'images': {name: 'ghcr.io/' + name + '@' + value['digest'] for name, value in repositories.items()},
                      'synthetic_images_only': True, 'oci_manifest_digests': True}))


def hosts(root, address):
    path = Path('/etc/hosts'); value = path.read_text()
    begin, end = '# VoiceChat entry fixture begin', '# VoiceChat entry fixture end'
    if begin in value:
        left, rest = value.split(begin, 1)
        _, right = rest.split(end, 1); value = left + right
    lines = ['127.0.0.2 www.duckdns.org', '192.0.2.14 ghcr.io', '192.0.2.10 chat.example.com turn-a.example.com',
             '192.0.2.11 b.example.com turn-b.example.com', address + ' entry-c.duckdns.org turn.entry-c.duckdns.org']
    temporary = root / 'hosts.next'; temporary.write_text(value.rstrip() + '\n' + begin + '\n' + '\n'.join(lines) + '\n' + end + '\n')
    os.chmod(temporary, 0o644); os.replace(temporary, path)


def serve(root):
    owned(root)
    repositories = json.loads((root / 'registry/repositories.json').read_text())
    token = (root / 'fake-duckdns-token').read_text().strip()
    tokens = {}; lock = threading.Lock()
    state_path = root / 'provider-state.json'
    if not state_path.exists(): save(state_path, {'address': '192.0.2.99', 'dns_updates': [], 'registry_pulls': 0})
    hosts(root, json.loads(state_path.read_text())['address'])
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass  # Never log token-bearing request URLs.
        def answer(self, status, body=b'', *, headers=None):
            self.send_response(status)
            for name, value in (headers or {}).items(): self.send_header(name, value)
            self.send_header('Content-Length', str(len(body))); self.end_headers()
            if self.command != 'HEAD': self.wfile.write(body)
        def challenge(self, repository=None):
            value = 'Bearer realm="https://ghcr.io/token",service="ghcr.io"'
            if repository is not None: value += ',scope="repository:' + repository + ':pull"'
            self.answer(401, b'{}', headers={'WWW-Authenticate': value})
        def do_HEAD(self): self.do_GET()
        def do_GET(self):
            parsed = urllib.parse.urlsplit(self.path); query = urllib.parse.parse_qs(parsed.query)
            if parsed.path == '/update':
                if (query.get('token') != [token] or query.get('domains') != ['entry-c'] or
                        query.get('verbose') != ['true'] or set(query) != {'token', 'domains', 'ip', 'verbose'}):
                    return self.answer(200, b'KO\n')
                try: address = str(ipaddress.IPv4Address(query['ip'][0]))
                except (ValueError, KeyError): return self.answer(200, b'KO\n')
                if address not in ('192.0.2.12', '192.0.2.13'): return self.answer(200, b'KO\n')
                with lock:
                    state = json.loads(state_path.read_text()); changed = state['address'] != address
                    state['address'] = address; state['dns_updates'].append({'address': address, 'at': time.time()})
                    hosts(root, address); save(state_path, state)
                return self.answer(200, ('OK\n' + address + '\n\n' + ('UPDATED' if changed else 'NOCHANGE') + '\n').encode())
            if parsed.path == '/token':
                if query.get('service') != ['ghcr.io'] or set(query) - {'service', 'scope', 'account', 'client_id'}:
                    return self.answer(400)
                scope = query.get('scope', [''])[0]
                repository = scope[len('repository:'):-len(':pull')] if scope.startswith('repository:') and scope.endswith(':pull') else None
                if scope and repository not in repositories: return self.answer(403)
                opaque = secrets.token_urlsafe(32)
                with lock: tokens[opaque] = (repository, time.time() + 600)
                return self.answer(200, json.dumps({'token': opaque, 'expires_in': 600}).encode(), headers={'Content-Type': 'application/json'})
            match = re.fullmatch(r'/v2/(voicechat-fixture/mesh-(?:web|control))/(manifests|blobs)/(sha256:[a-f0-9]{64})', parsed.path)
            repository = match[1] if match else None
            credential = self.headers.get('Authorization', '').removeprefix('Bearer ')
            with lock: authorized = tokens.get(credential)
            if not authorized or authorized[1] <= time.time() or (repository is not None and authorized[0] != repository):
                return self.challenge(repository)
            if parsed.path in ('/v2', '/v2/'): return self.answer(200, b'{}')
            if not match: return self.answer(404)
            record = repositories[repository]; kind, digest = match[2], match[3]
            if kind == 'manifests':
                if digest not in record['manifests']: return self.answer(404)
                body = (root / 'registry/manifests' / (digest.removeprefix('sha256:') + '.json')).read_bytes()
                with lock:
                    state = json.loads(state_path.read_text()); state['registry_pulls'] += 1; save(state_path, state)
                return self.answer(200, body, headers={'Content-Type': record['manifests'][digest], 'Docker-Content-Digest': digest})
            if digest not in record['blobs']: return self.answer(404)
            path = root / 'registry/blobs' / digest.removeprefix('sha256:'); length = path.stat().st_size
            start = 0
            if self.headers.get('Range'):
                matched = re.fullmatch(r'bytes=([0-9]+)-', self.headers['Range'])
                if not matched: return self.answer(416)
                start = int(matched[1])
                if start >= length: return self.answer(416)
            self.send_response(206 if start else 200)
            self.send_header('Content-Length', str(length - start)); self.send_header('Docker-Content-Digest', digest)
            self.send_header('Content-Type', 'application/octet-stream')
            if start: self.send_header('Content-Range', 'bytes ' + str(start) + '-' + str(length - 1) + '/' + str(length))
            self.end_headers()
            if self.command != 'HEAD':
                with path.open('rb') as source:
                    source.seek(start); shutil.copyfileobj(source, self.wfile, 1024 * 1024)
    servers = []
    for label, port in (('dns', 9443), ('registry', 9444)):
        server = http.server.ThreadingHTTPServer(('0.0.0.0', port), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(root / 'pki' / (label + '.chain.pem'), root / 'pki' / (label + '.key'))
        server.socket = context.wrap_socket(server.socket, server_side=True); servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    while True: time.sleep(60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('build', 'serve'))
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    (build if args.action == 'build' else serve)(args.root)


if __name__ == '__main__': main()
