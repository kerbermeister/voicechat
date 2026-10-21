#!/usr/bin/env python3
"""Loopback-only test token issuer. No media keys, no production control API."""
import base64
import hashlib
import hmac
import json
import time
import threading
import sqlite3
from contacts import ContactStore, ContactError
from link_preview import preview
import http.client
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

_secrets = json.loads((Path(__file__).resolve().parents[1] / '.prototype/secrets.json').read_text())
secret = _secrets['livekit']
policy_secret = _secrets['policy']
reports = []
report_lock = threading.Lock()
_contacts = None
_contacts_lock = threading.Lock()
_preview_slots = threading.BoundedSemaphore(4)
_preview_calls = {}
_preview_lock = threading.Lock()

def contact_store():
    global _contacts
    with _contacts_lock:
        if _contacts is None: _contacts = ContactStore()
    return _contacts

def jwt(payload):
    def enc(v):
        return base64.urlsafe_b64encode(json.dumps(v, separators=(',', ':')).encode()).rstrip(b'=')
    data = enc({'alg': 'HS256', 'typ': 'JWT'}) + b'.' + enc(payload)
    return (data + b'.' + base64.urlsafe_b64encode(hmac.new(secret.encode(), data, hashlib.sha256).digest()).rstrip(b'=')).decode()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def matrix(self, path):
        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Bearer ') or len(auth) > 8192:
            raise ContactError('unauthorized')
        req = urllib.request.Request('http://127.0.0.1:8008/_matrix/client/v3/' + path,
                                     headers={'Authorization': auth})
        with urllib.request.urlopen(req, timeout=10) as response: return json.load(response)
    def contact_get(self):
        user = self.matrix('account/whoami')['user_id']
        store = contact_store()
        if self.path == '/contacts':
            return self.reply(200, {'allow_direct': store.policy(user), 'requests': store.list(user)})
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        target = query.get('user_id', [])
        if len(target) != 1: raise ContactError('invalid_user')
        ContactStore.pair(user, target[0])
        return self.reply(200, {'allow_direct': store.policy(target[0])})
    def contact_post(self):
        user = self.matrix('account/whoami')['user_id']
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 < size <= 4096: raise ContactError('invalid_size')
        body = json.loads(self.rfile.read(size))
        if not isinstance(body, dict): raise ContactError('invalid_request')
        store = contact_store()
        action = body.get('action')
        if action == 'policy' and set(body) == {'action', 'allow_direct'}:
            store.set_policy(user, body['allow_direct'])
            return self.reply(200, {'ok': True})
        if action in ('accept', 'decline', 'cancel') and set(body) == {'action', 'id'}:
            if not isinstance(body['id'], str) or len(body['id']) != 32: raise ContactError('invalid_id')
            state = store.decide(user, body['id'], action)
            return self.reply(200, {'state': state})
        if action != 'request' or set(body) != {'action', 'recipient', 'room_id'}:
            raise ContactError('invalid_request')
        target, room = body['recipient'], body['room_id']
        ContactStore.pair(user, target)
        if not isinstance(room, str) or not room.startswith('!') or len(room) > 255: raise ContactError('invalid_room')
        state = self.matrix('rooms/' + urllib.parse.quote(room, safe='') + '/state')
        members = {e['state_key']: e['content'].get('membership') for e in state if e['type'] == 'm.room.member' and e['content'].get('membership') in ('invite', 'join')}
        encrypted = any(e['type'] == 'm.room.encryption' and e['content'].get('algorithm') == 'm.megolm.v1.aes-sha2' for e in state)
        direct = any(e['type'] == 'dev.voicechat.kind' and e['content'].get('kind') == 'direct' and
                     {e['content'].get('owner'), e['content'].get('peer')} == {user, target} for e in state)
        if not encrypted or not direct or members.get(user) != 'join' or set(members) != {user, target}:
            raise ContactError('invalid_direct_room')
        return self.reply(200, store.request(user, target, room))
    def reply(self, status, body):
        encoded = b'' if status == 204 else json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.send_header('Cache-Control', 'no-store')
        origin = self.headers.get('Origin', '')
        if origin in ('http://localhost:7357', 'http://127.0.0.1:7357',
                      'http://localhost:7358', 'http://127.0.0.1:7358'):
            self.send_header('Access-Control-Allow-Origin', origin)
        self.send_header('Access-Control-Allow-Headers', 'Authorization,Content-Type')
        self.send_header('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
        self.end_headers()
        self.wfile.write(encoded)
    def do_OPTIONS(self): self.reply(204, {})
    def do_GET(self):
        if self.path.startswith('/internal/contact-authorized?'):
            if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + policy_secret):
                return self.reply(403, {'error': 'forbidden'})
            try:
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                if set(query) != {'inviter', 'invitee'} or any(len(v) != 1 for v in query.values()):
                    raise ContactError('invalid_users')
                return self.reply(200, {'accepted': contact_store().accepted(query['inviter'][0], query['invitee'][0])})
            except (ContactError, OSError, sqlite3.Error):
                return self.reply(403, {'error': 'forbidden'})
        if self.path == '/contacts' or self.path.startswith('/contact-policy?'):
            try: return self.contact_get()
            except ContactError as error: return self.reply(403, {'error': str(error)})
            except urllib.error.HTTPError: return self.reply(401, {'error': 'matrix_denied'})
            except (OSError, ValueError, KeyError, TypeError, sqlite3.Error): return self.reply(503, {'error': 'contacts_unavailable'})
        if self.path == '/config':
            try:
                from client_policy import load_policy
                return self.reply(200, load_policy())
            except (OSError, ValueError, TypeError):
                return self.reply(503, {'error': 'invalid_policy'})
        if self.path == '/reports': return self.reply(200, reports)
        self.reply(404, {'error': 'not_found'})
    def do_POST(self):
        if self.path == '/link-preview':
            try:
                user = self.matrix('account/whoami')['user_id']
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 4096: return self.reply(400, {'error': 'invalid_size'})
                body = json.loads(self.rfile.read(size))
                if not isinstance(body, dict) or set(body) != {'url'}:
                    return self.reply(400, {'error': 'invalid_request'})
                now = time.monotonic()
                with _preview_lock:
                    for key in list(_preview_calls):
                        if _preview_calls[key][-1] < now - 60: del _preview_calls[key]
                    recent = [t for t in _preview_calls.get(user, []) if t > now - 60]
                    if len(recent) >= 10: return self.reply(429, {'error': 'rate_limit'})
                    _preview_calls[user] = [*recent, now]
                if not _preview_slots.acquire(blocking=False):
                    return self.reply(429, {'error': 'busy'})
                try:
                    return self.reply(200, preview(body['url']))
                finally:
                    _preview_slots.release()
            except (ContactError, urllib.error.HTTPError): return self.reply(401, {'error': 'unauthorized'})
            except (OSError, ValueError, KeyError, TypeError, http.client.HTTPException):
                return self.reply(400, {'error': 'preview_unavailable'})
        if self.path == '/contacts':
            try: return self.contact_post()
            except ContactError as error: return self.reply(403, {'error': str(error)})
            except urllib.error.HTTPError: return self.reply(401, {'error': 'matrix_denied'})
            except (OSError, ValueError, KeyError, TypeError, sqlite3.Error): return self.reply(503, {'error': 'contacts_unavailable'})
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
            video = body.get('video', False)
            if type(video) is not bool or set(body) - {'room_id', 'session', 'video'}:
                return self.reply(400, {'error': 'invalid_call_mode'})
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
                                   'canPublishData': True,
                                   'canPublishSources': ['microphone', 'camera'] if video else ['microphone']}})
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
