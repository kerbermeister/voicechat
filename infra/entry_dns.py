"""Guarded, resumable DuckDNS IPv4 cutover from the trusted operator.

DuckDNS has no atomic compare-and-swap API. Our journal serializes this operator,
checks the expected DNS value before writing, and verifies convergence afterward.
A separate DDNS writer must be disabled for the selected entry domain. DNS tokens
stay in the central credential store; errors never include the request URL.
"""
import ipaddress
import json
from pathlib import Path
import re
import socket
import urllib.parse
import urllib.request

import managed_state
import node_inventory
import route_health
import tls_material
import topology


def addresses(host):
    try:
        values = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    except socket.gaierror as error:
        if error.errno == socket.EAI_NONAME:
            return []
        raise ValueError('DNS lookup failed; no cutover attempted') from None
    return sorted({str(ipaddress.ip_address(value[4][0])) for value in values})


def plan(public, inventory, edge_id, domain, expected):
    node_inventory.validate(inventory, public)
    if not isinstance(domain, str) or not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*\.duckdns\.org', domain):
        raise ValueError('One separately registered DuckDNS entry domain required')
    if not isinstance(expected, list) or len(expected) > 1:
        raise ValueError('Expected previous IPv4 record or an empty record required')
    for value in expected: node_inventory.ipv4(value)
    entry = next(edge for edge in public['edges'] if edge['id'] == edge_id)
    names = sorted({urllib.parse.urlsplit(entry['origin']).hostname, entry['turn_host']})
    belongs = lambda host: host == domain or host.endswith('.' + domain)
    if not all(belongs(host) for host in names):
        raise ValueError('Entry HTTPS and TURN names must share their dedicated DNS domain')
    protected = [urllib.parse.urlsplit(public['canonical_origin']).hostname]
    for edge in public['edges']:
        if edge['id'] != edge_id:
            protected += [urllib.parse.urlsplit(edge['origin']).hostname, edge['turn_host']]
    if any(belongs(host) for host in protected):
        raise ValueError('DNS change would move a canonical or unrelated entry name')
    return {'schema': 1, 'service_id': public['service_id'], 'edge_id': edge_id,
            'domain': domain, 'names': names, 'expected': expected,
            'target': [node_inventory.edge_assignment(inventory, edge_id)['public_ip']]}


def update(domain, address, token_file):
    token = tls_material.read_material(token_file, private=True).strip()
    if not re.fullmatch(rb'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}', token):
        raise ValueError('Invalid DuckDNS token file')
    query = urllib.parse.urlencode({'domains': domain.removesuffix('.duckdns.org'),
        'token': token.decode(), 'ip': address, 'verbose': 'true'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), route_health.NoRedirect())
    try:
        with opener.open('https://www.duckdns.org/update?' + query, timeout=30) as response:
            raw = response.read(257)
            if response.status != 200 or len(raw) > 256:
                raise ValueError('Invalid response')
        lines = raw.decode('ascii').strip().splitlines()
        if len(lines) != 4 or lines[0] != 'OK' or lines[1] != address or lines[2] != '' or lines[3] not in ('UPDATED', 'NOCHANGE'):
            raise ValueError('Unexpected DNS state')
    except Exception:
        raise ValueError('DuckDNS update failed or returned unexpected IPv6 state; preserve the cutover journal') from None


def cutover(directory, request, token_file, *, lookup=addresses, write=update):
    topology.fields(request, ('schema', 'service_id', 'edge_id', 'domain', 'names', 'expected', 'target'))
    # Request is produced by plan(). Recheck primitive bounds before I/O even
    # when the caller accidentally supplies a malformed saved step.
    if (type(request['schema']) is not int or request['schema'] != 1 or
            not isinstance(request['domain'], str) or
            not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*\.duckdns\.org', request['domain']) or
            not isinstance(request['names'], list) or not 1 <= len(request['names']) <= 2 or
            request['names'] != sorted(set(request['names'])) or
            not isinstance(request['expected'], list) or len(request['expected']) > 1 or
            not isinstance(request['target'], list) or len(request['target']) != 1):
        raise ValueError('Known bounded DNS cutover request required')
    for host in request['names']:
        topology.hostname(host)
        if host != request['domain'] and not host.endswith('.' + request['domain']):
            raise ValueError('Foreign DNS name')
    for value in [*request['expected'], *request['target']]: node_inventory.ipv4(value)
    with managed_state.locked(directory) as root:
        path = root / 'cutover.json'
        saved = managed_state.read(path) if path.exists() or path.is_symlink() else None
        if saved is not None:
            topology.fields(saved, ('schema', 'request', 'phase'))
            if saved['schema'] != 1 or saved['request'] != request or saved['phase'] not in ('pending', 'complete'):
                raise ValueError('Resume the same DNS cutover first')
        actual = {host: lookup(host) for host in [request['domain'], *request['names']]}
        if any(value != request['expected'] and not (saved is not None and value == request['target'])
               for value in actual.values()):
            raise ValueError('DNS changed from its expected value; no update attempted')
        if saved is not None and saved['phase'] == 'complete' and any(
                value != request['target'] for value in actual.values()):
            raise ValueError('Completed DNS cutover drifted; refuse to replay a stale operation')
        if saved is None:
            managed_state.persist(path, {'schema': 1, 'request': request, 'phase': 'pending'})
        if any(value != request['target'] for value in actual.values()):
            write(request['domain'], request['target'][0], token_file)
        actual = {host: lookup(host) for host in [request['domain'], *request['names']]}
        if any(value != request['target'] for value in actual.values()):
            raise ValueError('DNS has not converged; retry the same cutover after TTL expiry')
        managed_state.persist(path, {'schema': 1, 'request': request, 'phase': 'complete'})
        return {'schema': 1, 'domain': request['domain'], 'addresses': request['target'],
                'phase': 'complete', 'atomic_provider_cas': False}
