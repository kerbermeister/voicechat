"""Validate and stage an immutable TLS pair locally; never issue or activate it."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import ssl
import stat
import subprocess
import tempfile
import time
from urllib.parse import urlsplit

from managed_state import locked
from topology import load, validate


def names(public, edge_id, service):
    validate(public)
    edge = next((item for item in public['edges'] if item['id'] == edge_id), None)
    if edge is None or service not in ('web', 'turn'):
        raise ValueError('Known edge and web/turn service required')
    if service == 'turn': return [edge['turn_host']]
    origins = (edge['origin'], public['canonical_origin'])
    if any(urlsplit(value).scheme != 'https' or urlsplit(value).port not in (None, 443)
           for value in origins):
        raise ValueError('Standard HTTPS origins required for TLS')
    return sorted({urlsplit(value).hostname for value in origins})


def read_material(path, *, private=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('TLS material must be a regular file')
        if private and (info.st_uid != os.geteuid() or info.st_mode & 0o077):
            raise ValueError('TLS private key must be owner-only')
        content = source.read(262145)
    if not content or len(content) > 262144:
        raise ValueError('Empty or oversized TLS material')
    return content


def openssl(*arguments):
    # Never expose command diagnostics: key parsing and future provider errors
    # may contain sensitive input. No network/AIA retrieval is performed here.
    result = subprocess.run(['openssl', *map(str, arguments)], input=b'',
                            capture_output=True, timeout=30)
    if result.returncode: raise ValueError('TLS certificate verification failed')
    return result.stdout


def write_private(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        os.fchmod(output.fileno(), 0o600)
        output.write(content)
        output.flush()
        os.fsync(output.fileno())


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(descriptor)
    finally: os.close(descriptor)


def stage(directory, public, edge_id, service, chain_file, key_file, *,
          ca_file=None, minimum_validity_days=7):
    required_names = names(public, edge_id, service)
    if type(minimum_validity_days) is not int or not 1 <= minimum_validity_days <= 90:
        raise ValueError('Minimum validity must be 1–90 days')
    chain = read_material(chain_file)
    key = read_material(key_file, private=True)
    blocks = re.findall(rb'-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+/=\s]+-----END CERTIFICATE-----', chain)
    if not 1 <= len(blocks) <= 8 or re.sub(rb'\s', b'', b''.join(blocks)) != re.sub(rb'\s', b'', chain):
        raise ValueError('A PEM certificate chain without other material is required')
    # Validate the same snapshots that will be staged, not mutable source paths.
    with tempfile.TemporaryDirectory(prefix='voicechat-tls-check-') as temporary:
        root = Path(temporary)
        cert_path, key_path = root / 'chain.pem', root / 'key.pem'
        write_private(cert_path, chain)
        write_private(key_path, key)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        try: context.load_cert_chain(cert_path, key_path, password=lambda: '')
        except (ssl.SSLError, OSError):
            raise ValueError('TLS key must match the certificate and be unencrypted') from None
        san = openssl('x509', '-in', cert_path, '-noout', '-ext', 'subjectAltName')
        if not re.search(rb'DNS:[^,\s]+', san):
            raise ValueError('TLS certificate requires DNS subjectAltName; CN fallback is forbidden')
        trust = []
        if ca_file is not None:
            trust_path = root / 'ca.pem'
            write_private(trust_path, read_material(ca_file))
            trust = ['-no-CAfile', '-no-CApath', '-no-CAstore', '-CAfile', trust_path]
        future = int(time.time()) + minimum_validity_days * 86400
        for name in required_names:
            for at_time in (None, future):
                openssl('verify', *trust, '-x509_strict', '-auth_level', '2',
                        '-purpose', 'sslserver', '-verify_hostname', name,
                        *(['-attime', at_time] if at_time is not None else []),
                        '-untrusted', cert_path, cert_path)
    # A whole directory becomes visible at once. There is deliberately no active
    # pointer: deployment must choose/recreate the correct service after checks.
    generation = hashlib.sha256(service.encode() + b'\0' + chain + b'\0' + key).hexdigest()
    with locked(directory) as store:
        destination = store / generation
        expected = {service + '.crt': chain, service + '.key': key}
        if destination.exists() or destination.is_symlink():
            info = destination.lstat()
            if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or
                    info.st_mode & 0o077 or {item.name for item in destination.iterdir()} != set(expected)):
                raise ValueError('Existing TLS generation is not a private complete directory')
            if any(read_material(destination / name, private=True) != content
                   for name, content in expected.items()):
                raise ValueError('Existing TLS generation was modified')
            return destination
        temporary = Path(tempfile.mkdtemp(prefix='.tls-', dir=store))
        try:
            for name, content in expected.items(): write_private(temporary / name, content)
            sync_directory(temporary)
            os.rename(temporary, destination)
            sync_directory(store)
        finally:
            if temporary.exists(): shutil.rmtree(temporary)
        return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--topology', type=Path, required=True)
    parser.add_argument('--edge', required=True)
    parser.add_argument('--service', choices=('web', 'turn'), required=True)
    parser.add_argument('--chain', type=Path, required=True)
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--ca-file', type=Path, help='Explicit trust store for an isolated test CA')
    parser.add_argument('--minimum-validity-days', type=int, default=7)
    args = parser.parse_args()
    result = stage(args.directory, load(args.topology), args.edge, args.service,
                   args.chain, args.key, ca_file=args.ca_file,
                   minimum_validity_days=args.minimum_validity_days)
    print('Verified local TLS generation: ' + str(result))


if __name__ == '__main__': main()
