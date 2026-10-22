#!/usr/bin/env python3
"""One-time configuration; never replace existing server identity or secrets."""
import argparse
import base64
import ipaddress
import os
from pathlib import Path
import re
import secrets
from urllib.parse import urlsplit
from client_config import client_config


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--url', default='http://localhost:7360')
    parser.add_argument('--ip', default='127.0.0.1')
    parser.add_argument('--server-name', default='voicechat.local')
    args=parser.parse_args()
    target=Path(__file__).with_name('runtime')
    if (target/'stand.env').exists():
        print('Existing configuration retained; edit runtime/stand.env deliberately to change deployment.')
        return
    args.url=client_config(args.url)["MATRIX_URL"]
    url=urlsplit(args.url)
    local=url.hostname in ('localhost','127.0.0.1')
    if local and url.scheme != 'http': raise SystemExit('The local stand uses HTTP loopback; use a public domain for HTTPS')
    if not local and url.port not in (None,443): raise SystemExit('Public HTTPS must use port 443')
    ip=ipaddress.ip_address(args.ip)
    if ip.version != 4: raise SystemExit('This deployment currently requires an IPv4 media address')
    if not local and not ip.is_global: raise SystemExit('A public media IP is required')
    if not re.fullmatch(r'[a-zA-Z0-9.-]+',args.server_name): raise SystemExit('Invalid immutable Matrix server name')
    if not local and not os.environ.get('SMTP_HOST'): raise SystemExit('Set SMTP_HOST and SMTP credentials before production bootstrap')
    values={
        'PUBLIC_URL':args.url,'PUBLIC_IP':args.ip,'MATRIX_SERVER_NAME':args.server_name,
        'SITE':'http://:80' if local else url.hostname,'BIND':'127.0.0.1' if local else '0.0.0.0',
        'HTTP_PORT':str(url.port or 80) if local else '80','HTTPS_PORT':'7361' if local else '443',
        'CONTROL_IMAGE':'voicechat-control:local','WEB_IMAGE':'voicechat-web:local',
        'COMPOSE_PROFILES':'local' if local else '', 'LOCAL_STAND':'1' if local else '0',
        'SMTP_HOST':os.environ.get('SMTP_HOST','mailpit'),'SMTP_PORT':os.environ.get('SMTP_PORT','1025' if local else '587'),
        'SMTP_USER_B64':base64.b64encode(os.environ.get('SMTP_USER','').encode()).decode(),
        'SMTP_PASSWORD_B64':base64.b64encode(os.environ.get('SMTP_PASSWORD','').encode()).decode(),
        **{name:secrets.token_hex(32) for name in ('POSTGRES_PASSWORD','REGISTRATION_SECRET','MACAROON_SECRET','LIVEKIT_SECRET','TURN_SECRET','POLICY_SECRET')},
    }
    if any('\n' in value or '\r' in value or "'" in value for value in values.values()): raise SystemExit('Configuration values must be single-line and contain no single quotes')
    target.mkdir(mode=0o700,parents=True,exist_ok=True)
    path=target/'stand.env'
    descriptor=os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    with os.fdopen(descriptor,'w') as output:
        output.write(''.join(f"{key}='{value}'\n" for key,value in values.items()))
    print('Private runtime/stand.env created; back it up before starting the server.')


if __name__=='__main__': main()
