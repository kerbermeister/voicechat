#!/usr/bin/env python3
"""Изолированный SS-04 smoke на локальном pinned SFU, без Matrix-аккаунтов/медиаключей."""
import json
import tempfile
import time
import urllib.request
from pathlib import Path
from uuid import uuid4
from screen_control import ScreenStore
from screen_transitions import ScreenTransitions
from token_server import media_api, jwt


def room_names():
    now = int(time.time())
    token = jwt({'iss':'prototype','nbf':now-5,'exp':now+30,'video':{'roomList':True}})
    request = urllib.request.Request('http://127.0.0.1:7880/twirp/livekit.RoomService/ListRooms',
        b'{}', {'Authorization':'Bearer '+token,'Content-Type':'application/json'})
    with urllib.request.urlopen(request,timeout=5) as response:
        return {room['name'] for room in json.load(response).get('rooms',[])}


def main():
    start = time.monotonic()
    created = set()
    def media(method, body):
        if method == 'CreateRoom': created.add(body['name'])
        return media_api(method,body)
    try:
        with tempfile.TemporaryDirectory() as directory:
            store = ScreenStore(Path(directory)/'calls.sqlite')
            engine = ScreenTransitions(store,media)
            a,b = ({'user_id':'@probe-a:local','device_id':'A'}, {'user_id':'@probe-b:local','device_id':'B'})
            valid = {'@probe-a:local/A':('curve-a','ed-a'),'@probe-b:local/B':('curve-b','ed-b')}
            request = {'room_id':'!ss04:local','call_session':str(uuid4()),'transport':'direct','peer':b}
            first=store.bind(a,request,valid)
            second=store.bind(b,{**request,'peer':a},valid)
            def session():
                with store.db() as db: return dict(db.execute('SELECT * FROM screen_sessions').fetchone())
            def command(actor,bound,action='claim'):
                return engine.command(action,actor,bound['binding_id'],bound['lease_id'],valid,str(uuid4()),session()['revision'])
            assert command(a,first)['status']=='succeeded'
            old=session()['generation']
            assert old in room_names()
            assert command(b,second)['status']=='succeeded'
            new=session()['generation']
            names=room_names()
            assert old not in names and new in names
            assert command(b,second,'stop')['status']=='succeeded'
            assert new not in room_names()
            result={'result':'PASS','elapsed_seconds':time.monotonic()-start,
                    'checks':['real CreateRoom','old room deleted before takeover','new room present','stop removes room'],
                    'matrix_and_media':'NOT_TESTED: synthetic admission, no media in this smoke'}
            Path(__file__).with_name('verified-screen-transitions-run.json').write_text(json.dumps(result,indent=2)+'\n')
            print(json.dumps(result))
    finally:
        for generation in created: media_api('DeleteRoom',{'room':generation})


if __name__=='__main__': main()
