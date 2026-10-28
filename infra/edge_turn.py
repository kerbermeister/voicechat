"""Initialize only the edge's TURN configuration, from its own secret file."""
import argparse
from pathlib import Path
import re

from configure import write
from node_inventory import ipv4
from topology import hostname


def configuration(secret, public_ip, relay_ip, realm):
    secrets = secret.splitlines()
    if (not 1 <= len(secrets) <= 2 or len(set(secrets)) != len(secrets) or
            any(not re.fullmatch(r'[a-f0-9]{64}', value) for value in secrets)):
        raise ValueError('One or two distinct TURN secrets required, each 32 bytes in lowercase hex')
    ipv4(public_ip)
    ipv4(relay_ip, tunnel=True)
    hostname(realm)
    # No private peers: LiveKit advertises A's public media address. The private
    # tunnel carries API traffic only; permitting arbitrary private TURN peers
    # would expose metadata and internal services to authenticated users.
    denied = ('0.0.0.0-0.255.255.255', '10.0.0.0-10.255.255.255',
              '100.64.0.0-100.127.255.255', '127.0.0.0-127.255.255.255',
              '169.254.0.0-169.254.255.255', '172.16.0.0-172.31.255.255',
              '192.168.0.0-192.168.255.255', '224.0.0.0-255.255.255.255',
              '::1', 'fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff', 'fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff')
    return '\n'.join([
        'listening-port=3478', 'tls-listening-port=5349', 'listening-ip=0.0.0.0',
        'relay-ip=' + relay_ip, 'external-ip=' + public_ip + '/' + relay_ip,
        'fingerprint', 'use-auth-secret', *('static-auth-secret=' + value for value in secrets), 'realm=' + realm,
        'cert=/tls/turn.crt', 'pkey=/tls/turn.key', 'min-port=49300', 'max-port=49400',
        'cli=off', 'no-multicast-peers', 'no-tcp-relay',
        'user-quota=16', 'total-quota=512', 'max-allocate-lifetime=3600',
        'log-file=stdout', 'simple-log', 'pidfile=/tmp/turn.pid',
        *('denied-peer-ip=' + address for address in denied), '',
    ])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--public-ip', required=True)
    parser.add_argument('--relay-ip', required=True)
    parser.add_argument('--realm', required=True)
    args = parser.parse_args()
    secret = Path('/run/secrets/turn-secret').read_text().strip()
    write('/turn/turnserver.conf', configuration(secret, args.public_ip, args.relay_ip, args.realm), 10001)


if __name__ == '__main__':
    main()
