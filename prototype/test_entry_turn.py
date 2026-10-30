import hashlib
import hmac
import ipaddress
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import entry_turn


class TurnStream:
    def __init__(self, *, tamper=False, rejected=False, relay='192.0.2.11'):
        self.count = 0; self.pending = b''; self.tamper = tamper; self.rejected = rejected; self.relay = relay
        self.key = hashlib.md5(b'123:realm:password').digest()

    def settimeout(self, value): pass

    def sendall(self, message):
        self.count += 1
        if self.count == 1 or self.rejected:
            kind = 0x113
            body = entry_turn.attribute(9, b'\0\0\4\1') + entry_turn.attribute(0x14, b'realm') + entry_turn.attribute(0x15, b'nonce')
            header = struct.pack('!HHI', kind, len(body), entry_turn.COOKIE) + message[8:20]
        else:
            kind = 0x103 if self.count == 2 else 0x104
            relay = b'\0\1' + struct.pack('!HI', 49350 ^ (entry_turn.COOKIE >> 16),
                         int(ipaddress.IPv4Address(self.relay)) ^ entry_turn.COOKIE)
            body = entry_turn.attribute(0x16, relay) if self.count == 2 else b''
            header = struct.pack('!HHI', kind, len(body) + 24, entry_turn.COOKIE) + message[8:20]
            integrity = hmac.new(self.key, header + body, hashlib.sha1).digest()
            body += entry_turn.attribute(8, bytes(20) if self.tamper else integrity)
        self.pending = header + body

    def recv(self, length):
        value, self.pending = self.pending[:length], self.pending[length:]
        return value


class EntryTurnTests(unittest.TestCase):
    def test_allocation_and_cleanup_require_authenticated_response_and_expected_relay(self):
        stream = TurnStream()
        entry_turn.allocate(stream, '123', 'password', relay_ip='192.0.2.11')
        self.assertEqual(stream.count, 3)
        with self.assertRaisesRegex(ValueError, 'authenticated allocation'):
            entry_turn.allocate(TurnStream(tamper=True), '123', 'password', relay_ip='192.0.2.11')
        with self.assertRaisesRegex(ValueError, 'unexpected relay'):
            entry_turn.allocate(TurnStream(relay='192.0.2.99'), '123', 'password', relay_ip='192.0.2.11')

    def test_retired_credentials_must_be_rejected_instead_of_allocated(self):
        entry_turn.allocate(TurnStream(rejected=True), '123', 'password', relay_ip='192.0.2.11', rejected=True)
        with self.assertRaisesRegex(ValueError, 'still accepted'):
            entry_turn.allocate(TurnStream(), '123', 'password', relay_ip='192.0.2.11', rejected=True)

    def test_wrong_transaction_and_truncated_responses_fail_closed(self):
        stream = TurnStream()
        original = stream.sendall
        def wrong(message):
            original(message); stream.pending = stream.pending[:8] + bytes(12) + stream.pending[20:]
        stream.sendall = wrong
        with self.assertRaisesRegex(ValueError, 'header'): entry_turn.exchange(stream, 3, [])
        stream = TurnStream(); stream.sendall = lambda _: None
        with self.assertRaisesRegex(ValueError, 'ended early'): entry_turn.exchange(stream, 3, [])


if __name__ == '__main__': unittest.main()
