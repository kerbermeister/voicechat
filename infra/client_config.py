"""Public endpoints compiled into both clients; no credentials belong in this file."""
import ipaddress
import argparse
import base64
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


def client_config(value):
    parsed=urlsplit(value)
    if (parsed.scheme not in ('http','https') or not parsed.hostname or parsed.username or parsed.password or
        parsed.path not in ('','/') or parsed.query or parsed.fragment):
        raise ValueError('Use a bare HTTP(S) origin without credentials')
    host=parsed.hostname.encode('idna').decode('ascii').lower()
    try: ipaddress.ip_address(host)
    except ValueError:
        if len(host)>253 or not re.fullmatch(r'[a-z0-9.-]+',host): raise ValueError('Invalid hostname')
    if parsed.scheme=='http' and host not in ('localhost','127.0.0.1','::1'):
        raise ValueError('HTTP is allowed only on loopback')
    port=parsed.port
    if port is not None and not 1<=port<=65535: raise ValueError('Invalid port')
    origin=parsed.scheme+'://'+('['+host+']' if ':' in host else host)
    if port is not None and port != (443 if parsed.scheme=='https' else 80): origin+=':'+str(port)
    return {'MATRIX_URL':origin,'TOKEN_URL':origin+'/api',
            'LIVEKIT_URL':('wss' if parsed.scheme=='https' else 'ws')+origin[len(parsed.scheme):]}


def build_config(value, topology_json='', catalog_key=''):
    result = client_config(value)
    if not topology_json and not catalog_key: return result
    if not topology_json or not catalog_key:
        raise ValueError('CLIENT_ROUTE_CONFIG and CLIENT_ROUTE_CATALOG_KEY must be set together')
    from topology import validate, unique_object, client_defines
    if len(topology_json.encode()) > 48000: raise ValueError('Oversized client topology')
    public = validate(json.loads(topology_json, object_pairs_hook=unique_object))
    if public['canonical_origin'] != result['MATRIX_URL']:
        raise ValueError('Client topology must match PUBLIC_URL; account identity cannot change')
    raw = base64.b64decode(catalog_key, validate=True)
    if len(raw) != 32 or raw == bytes(32) or base64.b64encode(raw).decode() != catalog_key:
        raise ValueError('Canonical base64 Ed25519 public key required')
    return {**client_defines(public), 'ROUTE_CATALOG_KEY': catalog_key}


def verify_candidate_config(current, path):
    path = Path(path)
    if not path.exists():
        # Legacy candidates predate this record; never use this exception to
        # relabel a candidate with a newly enabled routed configuration.
        if 'ROUTE_CONFIG' in current:
            raise ValueError('Candidate has no recorded routing configuration; rebuild it')
        return
    from topology import read_json
    previous = read_json(path)
    if previous != current:
        raise ValueError('Build configuration differs from the existing candidate; do not relabel its APK')


if __name__=='__main__':
    if '--topology' in sys.argv:
        from topology import load
        parser = argparse.ArgumentParser()
        parser.add_argument('--topology', type=Path, required=True)
        parser.add_argument('--catalog-key-file', type=Path, required=True)
        parser.add_argument('output', type=Path)
        args = parser.parse_args()
        public = load(args.topology)
        key = args.catalog_key_file.read_text().strip()
        value = build_config(public['canonical_origin'], json.dumps(public), key)
        args.output.write_text(json.dumps(value))
        raise SystemExit(0)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--environment', action='store_true', help='Read the optional CLIENT_ROUTE_CONFIG/CLIENT_ROUTE_CATALOG_KEY pair')
    parser.add_argument('--candidate', type=Path, help='Check the recorded configuration before reusing an existing APK')
    parser.add_argument('public_origin')
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    value = build_config(args.public_origin, os.environ.get('CLIENT_ROUTE_CONFIG', ''),
                         os.environ.get('CLIENT_ROUTE_CATALOG_KEY', '')) if args.environment else client_config(args.public_origin)
    if args.candidate: verify_candidate_config(value, args.candidate)
    args.output.write_text(json.dumps(value))
