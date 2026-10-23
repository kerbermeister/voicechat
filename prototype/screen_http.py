"""HTTP-сценарии экрана; Matrix IO выполняется до коротких SQL-фаз."""
import json
import re
import threading
import hashlib
from screen_access import verified_devices
from screen_control import ScreenError
from screen_protocol import parse_request, identifier
from screen_transitions import ScreenTransitions


def publication_state(info, owner, allowed):
    """Проверяет фактическую SFU metadata; SDP и клиентский heartbeat не заменяют её."""
    participants=info.get('participants',[])
    tracks=[(p.get('identity'),t) for p in participants for t in p.get('tracks',[])]
    invalid=any(p.get('identity') not in allowed for p in participants)
    invalid=invalid or len(tracks)>1 or any(
        identity!=owner or track.get('source') not in (3,'SCREEN_SHARE')
        or track.get('type',0) not in (0,'VIDEO') or track.get('encryption') not in (1,'GCM')
        or 'av1' in str(track.get('mimeType',track.get('mime_type',''))).lower()
        for identity,track in tracks)
    return invalid,bool(tracks)


class ScreenService:
    def __init__(self, store, media_api, signer, enabled):
        self.store, self.signer, self.enabled = store, signer, enabled
        self.transitions = ScreenTransitions(store, media_api)
        self.lock = threading.RLock()
        self._publication_deadlines = {}

    def tick(self):
        with self.lock:
            if not self.enabled():
                self.store.recover()
            else:
                with self.store.db() as db:
                    db.execute('BEGIN IMMEDIATE')
                    for binding in db.execute("SELECT * FROM screen_bindings WHERE state!='ended'").fetchall():
                        self.store._prune(db,binding,{})
                    db.execute('''DELETE FROM screen_commands WHERE binding_id IN
                        (SELECT id FROM screen_bindings WHERE state='ended' AND ended_at<?)
                        AND binding_id NOT IN (SELECT binding_id FROM screen_retired)''',
                        (self.store._now()-86400000,))
            self.transitions.recover()
            self._watch_publications()

    def _watch_publications(self):
        # Эти часы не авторизуют доступ. После restart все binding отзываются.
        with self.store.db() as db:
            sessions = [dict(r) for r in db.execute("SELECT * FROM screen_sessions WHERE state='active'")]
        active = {s['generation'] for s in sessions}
        self._publication_deadlines = {g:d for g,d in self._publication_deadlines.items() if g in active}
        for session in sessions:
            generation = session['generation']
            now = self.store._now()
            deadline = self._publication_deadlines.setdefault(generation,now+15000)
            info = self.transitions.media_api('ListParticipants',{'room':generation})
            if not isinstance(info,dict) or not isinstance(info.get('participants',[]),list):
                raise ValueError('invalid_screen_media_state')
            allowed = {p['identity'] for p in self.store.participants(session['binding_id'])}
            invalid, tracks = publication_state(info,session['owner_identity'],allowed)
            if tracks and not invalid:
                self._publication_deadlines[generation]=now+15000
            if invalid or (not tracks and now>=deadline):
                with self.store.db() as db:
                    db.execute('BEGIN IMMEDIATE')
                    current=db.execute('SELECT generation FROM screen_sessions WHERE binding_id=?',
                                       (session['binding_id'],)).fetchone()
                    if current and current[0]==generation:
                        self.store._invalidate(db,session['binding_id'])
                self.transitions.recover()

    def _binding(self, binding_id, who):
        identity = who['user_id']+'/'+who['device_id']
        with self.store.db() as db:
            binding = db.execute('SELECT * FROM screen_bindings WHERE id=?', (binding_id,)).fetchone()
            participant = db.execute('SELECT * FROM screen_participants WHERE binding_id=? AND identity=?',
                                     (binding_id,identity)).fetchone()
        if binding is None or participant is None:
            raise ScreenError('screen_session_not_found',404)
        return dict(binding),dict(participant)

    def _valid(self, matrix, who, room, participants, peer=None):
        wanted = {}
        for participant in participants:
            wanted.setdefault(participant['user_id'],[]).append(participant['device_id'])
        if peer:
            wanted.setdefault(peer['user_id'],[]).append(peer['device_id'])
        return verified_devices(matrix,who,room,wanted)

    def _snapshot(self, binding_id):
        with self.store.db() as db:
            row = dict(db.execute('SELECT * FROM screen_sessions WHERE binding_id=?',(binding_id,)).fetchone())
            roster = [dict(r) for r in db.execute('''SELECT identity,curve,ed FROM screen_participants
                WHERE binding_id=? AND confirmed=1 ORDER BY identity''',(binding_id,))]
        return {'protocol_version':1,'binding_id':binding_id,
                **{k:row[k] for k in ('revision','state','owner_identity','generation','roster_version','deadline')},
                'roster':roster,'server_time':self.store._now(),'capabilities':{'screen':self.enabled()}}

    def _unbind(self, who, body):
        actor=who['user_id']+'/'+who['device_id']
        fingerprint=hashlib.sha256(json.dumps(body,sort_keys=True).encode()).hexdigest()
        binding_id=body['binding_id']
        with self.store.db() as db:
            db.execute('BEGIN IMMEDIATE')
            receipt=db.execute('SELECT * FROM screen_commands WHERE binding_id=? AND actor_identity=? AND request_id=?',
                               (binding_id,actor,body['request_id'])).fetchone()
            if receipt:
                if receipt['operation']!='unbind' or receipt['fingerprint']!=fingerprint:
                    raise ScreenError('idempotency_conflict',409)
            else:
                participant=db.execute('SELECT 1 FROM screen_participants WHERE binding_id=? AND identity=? AND lease_id=?',
                                       (binding_id,actor,body['lease_id'])).fetchone()
                if not participant: raise ScreenError('screen_session_not_found',404)
                revision=db.execute('SELECT revision FROM screen_sessions WHERE binding_id=?',(binding_id,)).fetchone()[0]
                db.execute('''INSERT INTO screen_commands(binding_id,actor_identity,request_id,operation,fingerprint,
                    expected_revision,status,created_at) VALUES(?,?,?,'unbind',?,?,'pending',?)''',
                    (binding_id,actor,body['request_id'],fingerprint,revision,self.store._now()))
        self.store.leave(who,binding_id,body['lease_id'])
        self.transitions.recover()
        with self.store.db() as db:
            db.execute("UPDATE screen_commands SET status='succeeded' WHERE binding_id=? AND actor_identity=? AND request_id=?",
                       (binding_id,actor,body['request_id']))
        # После выхода нельзя возвращать актуальные roster/keys продолжающегося звонка.
        return 200,{'status':'succeeded','request_id':body['request_id'],'snapshot':None}

    def handle(self, method, path, raw, matrix):
        # Не принимаем query-token, actor/device из тела и произвольные URL SFU.
        if '?' in path:
            raise ScreenError('invalid_request',400)
        who = matrix('account/whoami')
        if not all(isinstance(who.get(k),str) and who[k] for k in ('user_id','device_id')):
            raise ScreenError('screen_access_denied')
        if method == 'GET' and path == '/screen/capabilities':
            return 200,{'protocol_version':1,'screen':self.enabled()}
        with self.lock:
            if not self.enabled():
                self.tick()
                raise ScreenError('screen_disabled',503)
            if method == 'POST' and path == '/screen/bind':
                body = parse_request('bind',raw)
                with self.store.db() as db:
                    existing = db.execute('SELECT id FROM screen_bindings WHERE room_id=? AND call_session=? AND transport=?',
                                          (body['room_id'],body['call_session'],body['transport'])).fetchone()
                participants = self.store.participants(existing['id']) if existing else []
                valid = self._valid(matrix,who,body['room_id'],participants,body.get('peer'))
                result = self.store.bind(who,body,valid)
                self.transitions.recover()
                with self.store.db() as db:
                    state = db.execute('SELECT state FROM screen_bindings WHERE id=?',(result['binding_id'],)).fetchone()[0]
                return 200,{**result,'binding_state':state,'snapshot':self._snapshot(result['binding_id'])}
            if method == 'POST' and path == '/screen/unbind':
                return self._unbind(who,parse_request('unbind',raw))
            else:
                match = re.fullmatch(r'/screen/([^/]+)/(state|claim|stop|heartbeat|token|operations/([^/]+))',path)
                if not match or not identifier(match[1],'uuid'):
                    raise ScreenError('screen_session_not_found',404)
                binding_id,operation,request_id = match[1],match[2],match[3]
                if operation in ('state',) or operation.startswith('operations/'):
                    if method != 'GET' or (request_id and not identifier(request_id,'uuid')):
                        raise ScreenError('invalid_request',400)
                    body = {}
                else:
                    if method != 'POST': raise ScreenError('invalid_request',400)
                    body = parse_request(operation,raw)
            binding, own = self._binding(binding_id,who)
            valid = self._valid(matrix,who,binding['room_id'],self.store.participants(binding_id))
            if body.get('lease_id',own['lease_id']) != own['lease_id']:
                raise ScreenError('screen_access_denied')
            # Первый direct bind может читать pending, но не публиковать/получать JWT.
            if operation == 'state' and binding['state'] == 'pending':
                with self.store.db() as db:
                    db.execute('BEGIN IMMEDIATE')
                    self.store._prune(db,binding,valid)
                    current = db.execute('SELECT 1 FROM screen_participants WHERE binding_id=? AND lease_id=?',
                                         (binding_id,own['lease_id'])).fetchone()
                if not current: raise ScreenError('screen_access_denied')
            else:
                self.store.authorize(who,binding_id,own['lease_id'],valid,renew=operation=='heartbeat')
            if operation in ('claim','stop'):
                with self.store.db() as db:
                    repeated = db.execute('SELECT 1 FROM screen_commands WHERE binding_id=? AND actor_identity=? AND request_id=?',
                                          (binding_id,own['identity'],body['request_id'])).fetchone()
                    recent = db.execute("SELECT COUNT(*) FROM screen_commands WHERE actor_identity=? AND operation='claim' AND created_at>?",
                                        (own['identity'],self.store._now()-10000)).fetchone()[0]
                if operation == 'claim' and not repeated and recent >= 5:
                    raise ScreenError('screen_rate_limited',429)
                result = self.transitions.command(operation,who,binding_id,own['lease_id'],valid,
                                                   body['request_id'],body['expected_revision'])
                return (202 if result['status']=='pending' else 200),{**result,'snapshot':self._snapshot(binding_id)}
            if operation == 'token':
                with self.store.db() as db:
                    db.execute('BEGIN IMMEDIATE')
                    session = db.execute('SELECT * FROM screen_sessions WHERE binding_id=?',(binding_id,)).fetchone()
                    if (session['state']!='active' or session['revision']!=body['expected_revision']
                            or session['generation']!=body['generation']
                            or db.execute('SELECT 1 FROM screen_retired WHERE binding_id=?',(binding_id,)).fetchone()):
                        raise ScreenError('screen_revision_conflict',409)
                    publisher = session['owner_identity']==own['identity']
                    now = int(self.store.clock())
                    grant = {'roomJoin':True,'room':session['generation'],'canSubscribe':True,
                             'canPublish':publisher,'canPublishData':False}
                    if publisher: grant['canPublishSources']=['screen_share']
                    token = self.signer({'iss':'prototype','sub':own['identity'],'nbf':now-5,'exp':now+60,'video':grant})
                return 200,{'generation':session['generation'],'revision':session['revision'],
                            'role':'publisher' if publisher else 'viewer','token':token,'expires_at':(now+60)*1000}
            self.transitions.recover()
            snapshot = self._snapshot(binding_id)
            if operation == 'state': return 200,snapshot
            if operation == 'heartbeat': return 200,{'lease_expires_at':self.store._now()+30000,'snapshot':snapshot}
            with self.store.db() as db:
                receipt = db.execute('''SELECT request_id,status,result_revision,error_code FROM screen_commands
                    WHERE binding_id=? AND actor_identity=? AND request_id=?''',(binding_id,own['identity'],request_id)).fetchone()
            if receipt is None: raise ScreenError('screen_session_not_found',404)
            return 200,{**dict(receipt),'snapshot':snapshot}
