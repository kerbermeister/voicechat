"""Public endpoints compiled into both clients; no credentials belong in this file."""
import ipaddress
import json
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


if __name__=='__main__':
    if len(sys.argv)!=3: raise SystemExit('Usage: client_config.py public_origin output_json')
    Path(sys.argv[2]).write_text(json.dumps(client_config(sys.argv[1])))
