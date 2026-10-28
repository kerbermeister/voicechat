"""Sign or verify the public route catalog with Ed25519 (OpenSSL 3)."""
import argparse
import base64
from dataclasses import dataclass
import json
from pathlib import Path
import subprocess
import tempfile
import time

from topology import fields, load, unique_object, validate

DOMAIN = b'voicechat-route-catalog-v1\n'
MAX_ENVELOPE = 65536
MAX_PAYLOAD = 48000
ED25519_PREFIX = bytes.fromhex('302a300506032b6570032100')


@dataclass(frozen=True)
class VerifiedCatalog:
    revision: int
    expires_at: int
    topology: dict
    payload: bytes


def read_envelope(path):
    with Path(path).open('rb') as stream:
        envelope = stream.read(MAX_ENVELOPE + 1)
    if len(envelope) > MAX_ENVELOPE:
        raise ValueError('Catalog envelope too large')
    return envelope


def verify(envelope, public, bootstrap, *, previous=None, restoring=False, now=None):
    """Verify exact signed bytes; only an existing high-water mark may be expired."""
    validate(bootstrap)
    if len(envelope) > MAX_ENVELOPE:
        raise ValueError('Catalog envelope too large')
    key = base64.b64decode(public, validate=True)
    raw = json.loads(envelope.decode('utf-8'), object_pairs_hook=unique_object)
    fields(raw, ('payload', 'signature'))
    if len(key) != 32 or not all(isinstance(raw[name], str) for name in raw):
        raise ValueError('Invalid catalog key or envelope')
    payload = base64.b64decode(raw['payload'], validate=True)
    signature = base64.b64decode(raw['signature'], validate=True)
    if len(payload) > MAX_PAYLOAD or len(signature) != 64:
        raise ValueError('Invalid catalog payload or signature size')
    with tempfile.TemporaryDirectory(prefix='voicechat-catalog-verify-') as temporary:
        directory = Path(temporary)
        (directory / 'key.der').write_bytes(ED25519_PREFIX + key)
        (directory / 'message').write_bytes(DOMAIN + payload)
        (directory / 'signature').write_bytes(signature)
        result = subprocess.run(['openssl', 'pkeyutl', '-verify', '-rawin', '-pubin',
            '-keyform', 'DER', '-inkey', str(directory / 'key.der'),
            '-in', str(directory / 'message'), '-sigfile', str(directory / 'signature')],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        raise ValueError('Invalid catalog signature or unsupported OpenSSL')
    value = json.loads(payload.decode('utf-8'), object_pairs_hook=unique_object)
    fields(value, ('schema', 'revision', 'issued_at', 'expires_at', 'topology'))
    if (any(type(value[name]) is not int for name in ('schema', 'revision', 'issued_at', 'expires_at'))
        or value['schema'] != 1 or not 1 <= value['revision'] <= 9007199254740991):
        raise ValueError('Invalid catalog version')
    now = int(time.time()) if now is None else now
    issued, expires = value['issued_at'], value['expires_at']
    if (not 0 <= issued < expires <= issued + 30 * 86400 or issued > now + 300
        or (not restoring and expires <= now)):
        raise ValueError('Catalog outside its validity interval')
    config = validate(value['topology'])
    if any(config[name] != bootstrap[name] for name in ('service_id', 'matrix_server_name', 'canonical_origin')):
        raise ValueError('Catalog cannot change installation identity')
    revision = value['revision']
    if previous is not None and (revision < previous.revision or
                                (revision == previous.revision and payload != previous.payload)):
        raise ValueError('Catalog rollback or conflicting revision')
    return VerifiedCatalog(revision, expires, config, payload)


def sign(topology, private_key, revision, issued_at, expires_at):
    validate(topology)
    if type(revision) is not int or not 1 <= revision <= 9007199254740991:
        raise ValueError('Positive safe revision required')
    if type(issued_at) is not int or type(expires_at) is not int or not 0 <= issued_at < expires_at <= issued_at + 30 * 86400:
        raise ValueError('Catalog lifetime must be at most 30 days')
    payload = json.dumps({'schema': 1, 'revision': revision, 'issued_at': issued_at,
                          'expires_at': expires_at, 'topology': topology},
                         separators=(',', ':'), sort_keys=True).encode()
    if len(payload) > MAX_PAYLOAD:
        raise ValueError('Catalog payload too large')
    with tempfile.TemporaryDirectory(prefix='voicechat-catalog-') as temporary:
        message = Path(temporary) / 'message'
        message.write_bytes(DOMAIN + payload)
        signature = subprocess.check_output(['openssl', 'pkeyutl', '-sign', '-rawin',
            '-inkey', str(private_key), '-in', str(message)], stderr=subprocess.PIPE)
    if len(signature) != 64:
        raise ValueError('Ed25519 key required')
    return {'payload': base64.b64encode(payload).decode(),
            'signature': base64.b64encode(signature).decode()}


def public_key(private_key):
    der = subprocess.check_output(['openssl', 'pkey', '-in', str(private_key),
                                  '-pubout', '-outform', 'DER'], stderr=subprocess.PIPE)
    if len(der) != 44 or der[:12] != ED25519_PREFIX:
        raise ValueError('Ed25519 key required')
    return base64.b64encode(der[12:]).decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--topology', type=Path, required=True)
    parser.add_argument('--private-key', type=Path, required=True)
    parser.add_argument('--revision', type=int, required=True)
    parser.add_argument('--valid-days', type=int, default=7, choices=range(1, 31))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit('Output exists; use a new release artifact')
    value = load(args.topology)
    now = int(time.time())
    try:
        envelope = sign(value, args.private_key, args.revision, now, now + args.valid_days * 86400)
        public = public_key(args.private_key)
    except subprocess.CalledProcessError:
        raise SystemExit('Catalog signing failed; check OpenSSL 3 and the Ed25519 key') from None
    # A public artifact, never a private key or user data. Exclusive creation.
    with args.output.open('x') as output:
        json.dump(envelope, output, separators=(',', ':'))
        output.write('\n')
    print('ROUTE_CATALOG_KEY=' + public)


if __name__ == '__main__':
    main()
