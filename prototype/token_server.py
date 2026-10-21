#!/usr/bin/env python3
"""Loopback-only test token issuer. No media keys, no production control API."""
import base64
import hashlib
import hmac
import json
import time
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

secret = json.loads((Path(__file__).resolve().parents[1] / '.prototype/secrets.json').read_text())['livekit']
reports = []
report_lock = threading.Lock()

def jwt(payload):
    def enc(v):
        return base64.urlsafe_b64encode(json.dumps(v, separators=(',', ':')).encode()).rstrip(b'=')
    data = enc({'alg': 'HS256', 'typ': 'JWT'}) + b'.' + enc(payload)
    return (data + b'.' + base64.urlsafe_b64encode(hmac.new(secret.encode(), data, hashlib.sha256).digest()).rstrip(b'=')).decode()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, status, body):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        origin = self.headers.get('Origin', '')
        if origin in ('http://localhost:7357', 'http://127.0.0.1:7357'):
            self.send_header('Access-Control-Allow-Origin', origin)
        self.send_header('Access-Control-Allow-Headers', 'Authorization,Content-Type')
        self.send_header('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def do_OPTIONS(self): self.reply(204, {})
    def do_GET(self):
        if self.path == '/reports': return self.reply(200, reports)
        self.reply(404, {'error': 'not_found'})
    def do_POST(self):
        if self.path == '/report':
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 8192: return self.reply(400, {'error': 'invalid_size'})
                item = json.loads(self.rfile.read(size))
                # Diagnostics and public device fingerprints only; never private keys or credentials.
                allowed = {'run', 'role', 'stage', 'room_id', 'event_id', 'detail', 'user_id', 'device_id', 'fingerprint'}
                if (not isinstance(item, dict) or set(item) - allowed
                        or not {'run', 'role', 'stage'} <= item.keys()
                        or any(not isinstance(v, str) or len(v) > 512 for v in item.values())):
                    return self.reply(400, {'error': 'invalid_report'})
                item['timestamp'] = int(time.time())
                with report_lock:
                    reports.append(item)
                    path = Path(__file__).resolve().parents[1] / '.prototype/reports.json'
                    path.write_text(json.dumps(reports, indent=2))
                    path.chmod(0o600)
                return self.reply(200, {'ok': True})
            except (ValueError, TypeError): return self.reply(400, {'error': 'invalid_report'})
        if self.path != '/token': return self.reply(404, {'error': 'not_found'})
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 4096: return self.reply(400, {'error': 'invalid_size'})
            body = json.loads(self.rfile.read(size))
            room = body['room_id']
            session = body['session']
            if not isinstance(room, str) or not room.startswith('!') or len(room) > 255:
                return self.reply(400, {'error': 'invalid_room'})
            if not isinstance(session, str) or not 1 <= len(session) <= 64:
                return self.reply(400, {'error': 'invalid_session'})
            auth = self.headers.get('Authorization', '')
            if not auth.startswith('Bearer '): return self.reply(401, {'error': 'unauthorized'})
            def matrix(path):
                req = urllib.request.Request('http://127.0.0.1:8008/_matrix/client/v3/' + path,
                                             headers={'Authorization': auth})
                with urllib.request.urlopen(req, timeout=10) as r: return json.load(r)
            who = matrix('account/whoami')
            prefix = 'rooms/' + urllib.parse.quote(room, safe='') + '/state/'
            member = matrix(prefix + 'm.room.member/' + urllib.parse.quote(who['user_id'], safe=''))
            if member.get('membership') != 'join': return self.reply(403, {'error': 'not_joined'})
            if matrix(prefix + 'm.room.encryption/').get('algorithm') != 'm.megolm.v1.aes-sha2':
                return self.reply(403, {'error': 'unencrypted_room'})
            identity = who['user_id'] + '/' + who['device_id']
            media_room = hashlib.sha256((room + '\0' + session).encode()).hexdigest()
            now = int(time.time())
            token = jwt({'iss': 'prototype', 'sub': identity, 'nbf': now - 5, 'exp': now + 60,
                         'video': {'roomJoin': True, 'room': media_room,
                                   'canPublish': True, 'canSubscribe': True,
                                   'canPublishData': True, 'canPublishSources': ['microphone']}})
            self.reply(200, {'token': token, 'identity': identity})
        except urllib.error.HTTPError as e:
            self.reply(401 if e.code == 401 else 403, {'error': 'matrix_denied'})
        except (KeyError, ValueError, TypeError):
            self.reply(400, {'error': 'invalid_request'})
        except Exception:
            self.reply(503, {'error': 'upstream_unavailable'})

if __name__ == '__main__':
    print('Prototype token issuer: http://127.0.0.1:8090 (local test accounts only)', flush=True)
    ThreadingHTTPServer(('127.0.0.1', 8090), Handler).serve_forever()
