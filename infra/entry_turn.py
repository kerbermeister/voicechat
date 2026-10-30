"""Verify actual TURN/TLS authentication and retire a previous credential epoch.

Only short-lived synthetic credentials are used; no media or user identifiers.
A successful allocation must carry a valid STUN MESSAGE-INTEGRITY response.
"""
import base64
import hashlib
import hmac
import ipaddress
import secrets
import socket
import ssl
import struct
import time

import node_inventory

COOKIE = 0x2112A442


def attribute(kind, value):
    return struct.pack('!HH', kind, len(value)) + value + bytes((-len(value)) % 4)


def exchange(stream, kind, attributes, key=None):
    transaction = secrets.token_bytes(12)
    body = b''.join(attributes)
    header = struct.pack('!HHI', kind, len(body) + (24 if key is not None else 0), COOKIE) + transaction
    if key is not None:
        body += attribute(8, hmac.new(key, header + body, hashlib.sha1).digest())
    stream.sendall(header + body)
    deadline = time.monotonic() + 15
    def receive(count):
        result = b''
        while len(result) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0: raise TimeoutError('TURN response timed out')
            stream.settimeout(min(5, remaining))
            part = stream.recv(count - len(result))
            if not part: raise ValueError('TURN response ended early')
            result += part
        return result
    response = receive(20)
    response_kind, length, cookie = struct.unpack('!HHI', response[:8])
    if cookie != COOKIE or response[8:] != transaction or length > 8192 or length % 4:
        raise ValueError('Invalid TURN response header')
    payload = receive(length); result = {}; offset = 0; verified = False
    while offset < length:
        if offset + 4 > length: raise ValueError('Truncated TURN attribute')
        attr, size = struct.unpack('!HH', payload[offset:offset + 4])
        if offset + 4 + size > length or attr in result: raise ValueError('Invalid or duplicate TURN attribute')
        value = payload[offset + 4:offset + 4 + size]; result[attr] = value
        if attr == 8 and key is not None:
            signed_header = struct.pack('!HHI', response_kind, offset + 24, COOKIE) + transaction
            verified = size == 20 and hmac.compare_digest(value,
                hmac.new(key, signed_header + payload[:offset], hashlib.sha1).digest())
        offset += 4 + size + (-size) % 4
    return response_kind, result, verified


def error_code(attributes):
    value = attributes.get(9, b'')
    if len(value) < 4: raise ValueError('TURN error response lacks a code')
    return value[2] * 100 + value[3]


def allocate(stream, username, password, *, relay_ip, rejected=False):
    udp = attribute(0x19, bytes([17, 0, 0, 0]))
    kind, challenge, _ = exchange(stream, 3, [udp])
    if kind != 0x113 or error_code(challenge) != 401:
        raise ValueError('TURN did not require authentication')
    realm, nonce = challenge.get(0x14, b''), challenge.get(0x15, b'')
    if not 1 <= len(realm) <= 255 or not 1 <= len(nonce) <= 1024:
        raise ValueError('Invalid TURN authentication challenge')
    key = hashlib.md5(username.encode() + b':' + realm + b':' + password.encode()).digest()
    auth = [attribute(6, username.encode()), attribute(0x14, realm), attribute(0x15, nonce)]
    kind, result, verified = exchange(stream, 3, [udp, attribute(0xd, struct.pack('!I', 60)), *auth], key)
    if rejected:
        if kind != 0x113 or error_code(result) != 401:
            raise ValueError('Retired TURN credential is still accepted')
        return
    if kind != 0x103 or 0x16 not in result or not verified:
        raise ValueError('New TURN credentials did not produce an authenticated allocation')
    relay = result[0x16]
    if len(relay) != 8 or relay[:2] != b'\0\1':
        raise ValueError('TURN did not allocate the configured IPv4 relay')
    port = struct.unpack('!H', relay[2:4])[0] ^ (COOKIE >> 16)
    address = str(ipaddress.IPv4Address(struct.unpack('!I', relay[4:])[0] ^ COOKIE))
    if address != relay_ip or not 49300 <= port <= 49400:
        raise ValueError('TURN allocated an unexpected relay address or port')
    kind, _, verified = exchange(stream, 4, [attribute(0xd, bytes(4)), *auth], key)
    if kind != 0x104 or not verified:
        raise ValueError('Temporary TURN allocation was not released')


def credential(secret, expires=None):
    username = str(int(time.time()) + 300 if expires is None else expires)
    return {'username': username, 'credential': base64.b64encode(
        hmac.new(secret.encode(), username.encode(), hashlib.sha1).digest()).decode()}


def verify(public, inventory, edge_id, secret, previous=None):
    node_inventory.validate(inventory, public)
    edge = next(item for item in public['edges'] if item['id'] == edge_id)
    node = node_inventory.edge_assignment(inventory, edge_id)
    current = credential(secret)
    if previous is not None:
        from topology import fields
        fields(previous, ('username', 'credential'))
        if (not isinstance(previous['username'], str) or not previous['username'].isdigit() or
                not int(time.time()) + 30 <= int(previous['username']) <= int(time.time()) + 600 or
                not isinstance(previous['credential'], str) or len(base64.b64decode(previous['credential'], validate=True)) != 20):
            raise ValueError('Fresh short-lived retired-epoch credentials required')
    context = ssl.create_default_context(); context.minimum_version = ssl.TLSVersion.TLSv1_2
    probes = [(current, False)] + ([(previous, True)] if previous is not None else [])
    for candidate, rejected in probes:
        with socket.create_connection((node['public_ip'], 443), timeout=10) as raw:
            with context.wrap_socket(raw, server_hostname=edge['turn_host']) as stream:
                allocate(stream, candidate['username'], candidate['credential'], relay_ip=node['public_ip'], rejected=rejected)
    return {'schema': 1, 'edge_id': edge_id, 'turn_verified': True,
            'retired_credential_rejected': previous is not None}
