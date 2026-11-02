"""Create/delete only this audit's isolated room on the existing loopback test SFU."""
from pathlib import Path
import base64
import hashlib
import hmac
import json
import secrets
import subprocess
import sys
import time
import urllib.request
import urllib.error
import yaml
ROOT = Path(__file__).resolve().parents[3]
FILE = ROOT / '.prototype/call-audit-media.json'
CONTAINER = 'voicechat-streams-local-livekit-1'
CONFIG = Path('/Users/anton/.codex/worktrees/live-streams/VoiceChat/.prototype/livekit.yaml')
config = yaml.safe_load(CONFIG.read_text())
issuer, secret = next(iter(config['keys'].items()))
def jwt(subject, grant):
    def encode(value): return base64.urlsafe_b64encode(json.dumps(value,separators=(',',':')).encode()).rstrip(b'=')
    payload = encode({'iss':issuer,'sub':subject,'nbf':int(time.time())-10,'exp':int(time.time())+1200,'video':grant})
    data = encode({'alg':'HS256','typ':'JWT'}) + b'.' + payload
    return (data+b'.'+base64.urlsafe_b64encode(hmac.new(str(secret).encode(),data,hashlib.sha256).digest()).rstrip(b'=')).decode()
def state():
    raw = subprocess.check_output(['docker','inspect',CONTAINER],text=True)
    data = json.loads(raw)[0]
    return {'id':data['Id'],'started_at':data['State']['StartedAt'],'restart_count':data['RestartCount']}
def api(method, body):
    request=urllib.request.Request('http://127.0.0.1:7880/twirp/livekit.RoomService/'+method,
        json.dumps(body).encode(),{'Authorization':'Bearer '+jwt('qa-room-admin',{'roomCreate':True,'roomAdmin':True,'room':body.get('name',body.get('room'))}),'Content-Type':'application/json'})
    with urllib.request.urlopen(request,timeout=10) as response:return json.load(response)
if sys.argv[1] == 'create':
    assert not FILE.exists(), 'Clean up the preceding audit room first'
    room='qa-call-audit-'+secrets.token_hex(12)
    baseline=state()
    api('CreateRoom',{'name':room,'max_participants':5,'empty_timeout':600,'departure_timeout':10})
    data={'QA_GROUP_ROOM':room,'QA_GROUP_KEY':secrets.token_urlsafe(32),'baseline':baseline}
    for name in ['A','B','C']: data['QA_GROUP_'+name]=jwt('qa-'+name.lower(),{'roomJoin':True,'room':room,'canPublish':True,'canSubscribe':True,'canPublishData':True})
    FILE.write_text(json.dumps(data));FILE.chmod(0o600)
    print('PASS: isolated QA room created; credentials remain private')
elif sys.argv[1] == 'refresh':
    data=json.loads(FILE.read_text());room=data['QA_GROUP_ROOM']
    assert room.startswith('qa-call-audit-') and len(room)==38
    try: api('DeleteRoom',{'room':room})
    except urllib.error.HTTPError as error:
        if error.code != 404: raise
    api('CreateRoom',{'name':room,'max_participants':5,'empty_timeout':600,'departure_timeout':10})
    print('PASS: owned QA room recreated with600s empty timeout')
elif sys.argv[1] == 'cleanup':
    data=json.loads(FILE.read_text());room=data['QA_GROUP_ROOM']
    assert room.startswith('qa-call-audit-') and len(room)==38
    try: api('DeleteRoom',{'room':room})
    except urllib.error.HTTPError as error:
        if error.code != 404: raise
    assert state()==data['baseline'], 'SFU container state changed'
    FILE.unlink()
    print('PASS: only audit room deleted; SFU ID/StartedAt/RestartCount unchanged')
else: raise SystemExit('Use create, refresh or cleanup')
