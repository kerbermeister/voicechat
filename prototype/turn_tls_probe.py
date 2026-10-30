"""Small test-only STUN exchange for authenticated TURN/TLS policy assertions.

No relay payloads are sent. RFC 8489 message integrity / RFC 8656 allocation and
permissions; production clients continue using the existing WebRTC SDKs.
"""
import base64
import hashlib
import hmac
import ipaddress
import secrets
import struct
import time

COOKIE = 0x2112a442


def attribute(kind, value):
    return struct.pack('!HH', kind, len(value)) + value + bytes((-len(value)) % 4)


def exchange(stream, kind, attributes, key=None):
    transaction = secrets.token_bytes(12)
    body = b''.join(attributes)
    header = struct.pack('!HHI', kind, len(body) + (24 if key is not None else 0), COOKIE) + transaction
    if key is not None:
        body += attribute(0x0008, hmac.new(key, header + body, hashlib.sha1).digest())
    stream.sendall(header + body)
    def receive(count):
        result = b''
        while len(result) < count:
            part = stream.recv(count - len(result))
            if not part: raise OSError('TURN closed during a STUN response')
            result += part
        return result
    response = receive(20)
    response_kind, length, cookie = struct.unpack('!HHI', response[:8])
    assert cookie == COOKIE and response[8:20] == transaction and length <= 4096 and length % 4 == 0
    payload = receive(length)
    result = {}
    offset = 0
    while offset < length:
        assert offset + 4 <= length
        attr, size = struct.unpack('!HH', payload[offset:offset+4])
        assert offset + 4 + size <= length
        result[attr] = payload[offset+4:offset+4+size]
        offset += 4 + size + (-size) % 4
    return response_kind, result


def error_code(attributes):
    error = attributes[0x0009]
    assert len(error) >= 4
    return error[2] * 100 + error[3]


def authenticated_allocation(stream, secret, *, lifetime=3600, rejected=False):
    udp = attribute(0x0019, bytes([17,0,0,0]))
    kind, challenge = exchange(stream, 3, [udp])
    assert kind == 0x0113 and error_code(challenge) == 401
    username = str(int(time.time()) + lifetime).encode()
    password = base64.b64encode(hmac.new(secret.encode(), username, hashlib.sha1).digest())
    realm, nonce = challenge[0x0014], challenge[0x0015]
    key = hashlib.md5(username + b':' + realm + b':' + password).digest()
    auth = [attribute(0x0006, username), attribute(0x0014, realm), attribute(0x0015, nonce)]
    kind, allocated = exchange(stream, 3, [udp, *auth], key)
    if rejected:
        assert kind == 0x0113 and error_code(allocated) == 401, 'Invalid or expired credential was accepted'
        return None
    assert kind == 0x0103 and 0x0016 in allocated, 'Valid temporary credentials must allocate a relay'
    return auth, key


def check_policy(stream, secret):
    auth, key = authenticated_allocation(stream, secret)
    # Permissions alone do not transmit to the peer. Each forbidden destination
    # must be denied even to an authenticated client with a live allocation.
    for address in ('127.0.0.1','10.88.0.1','169.254.169.254','192.168.1.1'):
        encoded = struct.pack('!BBHI', 0, 1, 80 ^ (COOKIE >> 16), int(ipaddress.ip_address(address)) ^ COOKIE)
        kind, denied = exchange(stream, 8, [attribute(0x0012, encoded), *auth], key)
        assert kind == 0x0118 and error_code(denied) == 403, 'Private peer permission was not denied'
    kind, _ = exchange(stream, 4, [attribute(0x000d, bytes(4)), *auth], key)
    assert kind == 0x0104, 'Allocation must be released'
