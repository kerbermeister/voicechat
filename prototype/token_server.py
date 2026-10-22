#!/usr/bin/env python3
"""Loopback-only test token issuer. No media keys, no production control API."""
import base64
import hashlib
import hmac
import json
import time
import threading
import sqlite3
import os
from contacts import ContactStore, ContactError
from call_control import CallStore, CallError
from link_preview import preview
import http.client
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

_secrets = ({'livekit': os.environ['VOICECHAT_LIVEKIT_SECRET'], 'policy': os.environ['VOICECHAT_POLICY_SECRET']}
            if 'VOICECHAT_LIVEKIT_SECRET' in os.environ else
            json.loads((Path(__file__).resolve().parents[1] / '.prototype/secrets.json').read_text()))
secret = _secrets['livekit']
policy_secret = _secrets['policy']
matrix_url = os.environ.get('VOICECHAT_MATRIX_INTERNAL', 'http://127.0.0.1:8008').rstrip('/')
origins = os.environ.get('VOICECHAT_ORIGINS', 'http://localhost:7357,http://127.0.0.1:7357,http://localhost:7358,http://127.0.0.1:7358').split(',')
laboratory = os.environ.get('VOICECHAT_LAB', '1') == '1'
reports = []
report_lock = threading.Lock()
_contacts = None
_contacts_lock = threading.Lock()
_preview_slots = threading.BoundedSemaphore(4)
_preview_calls = {}
_preview_lock = threading.Lock()
_calls = None
_calls_lock = threading.Lock()
_call_failure = threading.Event()

def media_api(method, body):
    now = int(time.time())
    token = jwt({'iss': 'prototype', 'nbf': now - 5, 'exp': now + 30,
                 'video': {'roomCreate': True}})
    request = urllib.request.Request('http://127.0.0.1:7880/twirp/livekit.RoomService/' + method,
        json.dumps(body).encode(), {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if method == 'DeleteRoom' and error.code == 404: return {}
        raise

def call_store():
    global _calls
    with _calls_lock:
        if _calls is None:
            store = CallStore(Path(__file__).resolve().parents[1] / '.prototype/calls/calls.sqlite', media_api)
            store.recover()
            _calls = store
            def watch():
                while True:
                    time.sleep(1)
                    try:
                        store.sweep()
                        _call_failure.clear()
                    except Exception:
                        _call_failure.set()
            threading.Thread(target=watch, daemon=True, name='call-leases').start()
    return _calls

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

def contact_presence(target):
    url = matrix_url + '/_synapse/client/voicechat/presence?' + urllib.parse.urlencode({'user_id': target})
    request = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + policy_secret})
    with urllib.request.urlopen(request, timeout=5) as response: data = response.read(4097)
    if len(data) > 4096: raise ValueError('Presence response too large')
    return json.loads(data)

class ControlServer(ThreadingHTTPServer):
    # Simultaneous call admission/report bursts exceed the stdlib's five pending connections.
    request_queue_size = 64

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def matrix(self, path, body=None):
        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Bearer ') or len(auth) > 8192:
            raise ContactError('unauthorized')
        req = urllib.request.Request(matrix_url + '/_matrix/client/v3/' + path,
                                     None if body is None else json.dumps(body).encode(),
                                     headers={'Authorization': auth, 'Content-Type': 'application/json'})
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
        if origin in origins:
            self.send_header('Access-Control-Allow-Origin', origin)
        self.send_header('Access-Control-Allow-Headers', 'Authorization,Content-Type')
        self.send_header('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
        self.end_headers()
        try: self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_OPTIONS(self): self.reply(204, {})
    def do_GET(self):
        if self.path == '/health':
            return self.reply(503 if _call_failure.is_set() else 200, {'ok': not _call_failure.is_set()})
        if self.path.startswith('/presence?'):
            try:
                user = self.matrix('account/whoami')['user_id']
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                if set(query) != {'user_id'} or len(query['user_id']) != 1: raise ContactError('invalid_user')
                target = query['user_id'][0]
                if not contact_store().accepted(user, target): raise ContactError('not_accepted')
                body = contact_presence(target)
                if not isinstance(body, dict) or body.get('presence') not in ('online', 'offline', 'unavailable'): raise ValueError('Invalid presence')
                return self.reply(200, body)
            except ContactError: return self.reply(403, {'error': 'forbidden'})
            except urllib.error.HTTPError as error: return self.reply(401 if error.code == 401 else 503, {'error': 'presence_unavailable'})
            except (OSError, ValueError, KeyError, TypeError, sqlite3.Error): return self.reply(503, {'error': 'presence_unavailable'})
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
        if self.path == '/reports' and laboratory: return self.reply(200, reports)
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
        if self.path == '/report' and laboratory:
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
        if self.path not in ('/token', '/call/leave'): return self.reply(404, {'error': 'not_found'})
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 4096: return self.reply(400, {'error': 'invalid_size'})
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict): return self.reply(400, {'error': 'invalid_request'})
            who = self.matrix('account/whoami')
            if not all(isinstance(who.get(k), str) and who[k] for k in ('user_id', 'device_id')):
                return self.reply(403, {'error': 'device_required'})
            if self.path == '/call/leave':
                if set(body) != {'lease_id'} or not isinstance(body['lease_id'], str) or len(body['lease_id']) != 64:
                    return self.reply(400, {'error': 'invalid_lease'})
                call_store().leave(who, body['lease_id'])
                return self.reply(200, {'ok': True})
            room = body['room_id']
            session = body['session']
            video = body.get('video', False)
            if (type(video) is not bool or body.get('protocol_version') != 1 or
                set(body) - {'room_id', 'session', 'video', 'protocol_version', 'lease_id', 'reconnect'}):
                return self.reply(400, {'error': 'invalid_call_mode'})
            if not isinstance(room, str) or not room.startswith('!') or len(room) > 255:
                return self.reply(400, {'error': 'invalid_room'})
            if not isinstance(session, str) or not 1 <= len(session) <= 64:
                return self.reply(400, {'error': 'invalid_session'})
            lease, reconnect = body.get('lease_id'), body.get('reconnect')
            if lease is not None and (not isinstance(lease, str) or len(lease) != 64):
                return self.reply(400, {'error': 'invalid_lease'})
            if reconnect is not None and (not isinstance(reconnect, str) or len(reconnect) != 51):
                return self.reply(400, {'error': 'invalid_generation'})
            prefix = 'rooms/' + urllib.parse.quote(room, safe='') + '/state/'
            members = self.matrix('rooms/' + urllib.parse.quote(room, safe='') + '/joined_members')['joined']
            if who['user_id'] not in members: return self.reply(403, {'error': 'not_joined'})
            if self.matrix(prefix + 'm.room.encryption/').get('algorithm') != 'm.megolm.v1.aes-sha2':
                return self.reply(403, {'error': 'unencrypted_room'})
            store = call_store()
            wanted = {who['user_id']: [who['device_id']]}
            observed = store.roster(room, session)
            for peer in observed:
                if peer['user_id'] in members:
                    wanted.setdefault(peer['user_id'], []).append(peer['identity'][len(peer['user_id'])+1:])
            keys = self.matrix('keys/query', {'device_keys': wanted})['device_keys']
            device = keys[who['user_id']][who['device_id']]
            if device.get('user_id') != who['user_id'] or device.get('device_id') != who['device_id']:
                return self.reply(403, {'error': 'invalid_device'})
            curve, ed = (device['keys'][kind + ':' + who['device_id']] for kind in ('curve25519', 'ed25519'))
            for key in (curve, ed):
                if not isinstance(key, str) or len(key) != 43 or len(base64.b64decode(key + '=', validate=True)) != 32:
                    return self.reply(403, {'error': 'invalid_device'})
            valid = {}
            for user, devices in wanted.items():
                for identifier in devices:
                    candidate = keys.get(user, {}).get(identifier, {})
                    if candidate.get('user_id') != user or candidate.get('device_id') != identifier: continue
                    values = candidate.get('keys', {})
                    valid[user + '/' + identifier] = (values.get('curve25519:' + identifier), values.get('ed25519:' + identifier))
            admission = store.admission(room, session, video, who, curve, ed, lease, reconnect, valid,
                                        {peer['id'] for peer in observed})
            now = int(time.time())
            token = jwt({'iss': 'prototype', 'sub': admission['identity'], 'nbf': now - 5, 'exp': now + 60,
                         'video': {'roomJoin': True, 'room': admission['generation'],
                                   'canPublish': True, 'canSubscribe': True,
                                   'canPublishData': False,
                                   'canPublishSources': ['microphone', 'camera'] if video else ['microphone']}})
            self.reply(200, {**admission, 'token': token})
        except ContactError:
            self.reply(401, {'error': 'unauthorized'})
        except CallError as error:
            self.reply(error.status, {'error': str(error)})
        except urllib.error.HTTPError as e:
            self.reply(401 if e.code == 401 else 403, {'error': 'matrix_denied'})
        except (KeyError, ValueError, TypeError):
            self.reply(400, {'error': 'invalid_request'})
        except Exception:
            self.reply(503, {'error': 'upstream_unavailable'})

if __name__ == '__main__':
    print('Prototype token issuer: http://127.0.0.1:8090 (local test accounts only)', flush=True)
    ControlServer((os.environ.get('VOICECHAT_BIND', '127.0.0.1'), 8090), Handler).serve_forever()
