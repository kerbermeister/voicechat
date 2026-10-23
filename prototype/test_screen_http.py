"""Настоящий loopback HTTP, тестовый Matrix и подписанные grants без медиаключей."""
import base64
import json
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.error
from pathlib import Path
from uuid import uuid4
from unittest.mock import patch
import token_server
from contacts import ContactError
from screen_control import ScreenStore
from screen_http import ScreenService


class ScreenHTTPTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.now=1000.
        self.enabled=True
        self.rooms=set()
        self.store=ScreenStore(Path(self.directory.name)/'calls.sqlite',lambda:self.now)
        self.service=ScreenService(self.store,self.media,token_server.jwt,lambda:self.enabled)
        self.patch_service=patch.object(token_server,'_screens',self.service)
        self.patch_service.start(); self.addCleanup(self.patch_service.stop)
        def matrix(handler,path,body=None):
            auth=handler.headers.get('Authorization','')
            if auth not in ('Bearer a','Bearer b','Bearer other'): raise ContactError('unauthorized')
            user=auth.split()[1]
            if path=='account/whoami': return {'user_id':'@'+user+':x','device_id':user.upper()}
            if path.endswith('joined_members'): return {'joined':{'@a:x':{},'@b:x':{}}}
            if '/state/' in path: return {'algorithm':'m.megolm.v1.aes-sha2'}
            if path=='keys/query':
                return {'device_keys':{u:{d:{'user_id':u,'device_id':d,'keys':{'curve25519:'+d:'A'*43,'ed25519:'+d:'B'*43}}
                                         for d in devices} for u,devices in body['device_keys'].items()}}
            raise AssertionError('unexpected Matrix request')
        self.patch_matrix=patch.object(token_server.Handler,'matrix',matrix)
        self.patch_matrix.start();self.addCleanup(self.patch_matrix.stop)
        self.server=token_server.ControlServer(('127.0.0.1',0),token_server.Handler)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True)
        self.thread.start()
        self.addCleanup(self.close)

    def close(self):
        self.server.shutdown();self.server.server_close();self.thread.join()

    def media(self,method,body):
        if method=='ListParticipants': return {'participants':getattr(self,'participants',[])}
        if method=='CreateRoom':self.rooms.add(body['name'])
        else:self.rooms.discard(body['room'])

    def request(self,path,body=None,actor='a',raw=None):
        data=raw if raw is not None else None if body is None else json.dumps(body).encode()
        req=urllib.request.Request(f'http://127.0.0.1:{self.server.server_port}/screen/'+path,data,
                                   {'Authorization':'Bearer '+actor,'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(req,timeout=5) as response:return response.status,json.load(response)
        except urllib.error.HTTPError as error:return error.code,json.load(error)

    def pair(self):
        base={'protocol_version':1,'room_id':'!dm:x','call_session':str(uuid4()),'transport':'direct'}
        status,first=self.request('bind',{**base,'peer':{'user_id':'@b:x','device_id':'B'}})
        self.assertEqual(status,200)
        self.assertEqual(first['binding_state'],'pending')
        status,second=self.request('bind',{**base,'peer':{'user_id':'@a:x','device_id':'A'}},actor='b')
        self.assertEqual(status,200)
        return first,second

    def test_empty_duplicate_and_plaintext_publications_are_revoked(self):
        first,_=self.pair();binding=first['binding_id']
        def claim():
            state=self.request(binding+'/state')[1]
            return self.request(binding+'/claim',{'protocol_version':1,'lease_id':first['lease_id'],
                'request_id':str(uuid4()),'expected_revision':state['revision']})[1]['snapshot']
        claim(); self.service.tick()
        self.now+=14
        self.service.tick(); self.assertTrue(self.rooms)
        self.now+=1
        self.service.tick(); self.assertFalse(self.rooms)
        for tracks in ([{'source':'SCREEN_SHARE','encryption':'GCM'}]*2,
                       [{'source':'SCREEN_SHARE','encryption':'NONE'}],
                       [{'source':'CAMERA','encryption':'GCM'}]):
            claim()
            self.participants=[{'identity':'@a:x/A','tracks':tracks}]
            self.service.tick();self.assertFalse(self.rooms)
        claim()
        self.participants=[{'identity':'@a:x/A','tracks':[{'source':'SCREEN_SHARE','encryption':'GCM'}]}]
        self.service.tick();self.assertTrue(self.rooms)

    def test_routes_roles_receipts_and_no_cross_device_secrets(self):
        first,second=self.pair(); binding=first['binding_id']
        status,state=self.request(binding+'/state')
        self.assertEqual(status,200)
        self.assertNotIn('lease_id',json.dumps(state))
        claim={'protocol_version':1,'lease_id':first['lease_id'],'request_id':str(uuid4()),'expected_revision':state['revision']}
        status,result=self.request(binding+'/claim',claim)
        self.assertEqual((status,result['status']),(200,'succeeded'))
        state=result['snapshot']
        token={'protocol_version':1,'lease_id':first['lease_id'],'generation':state['generation'],'expected_revision':state['revision']}
        for actor,bound,publisher in [('a',first,True),('b',second,False)]:
            status,data=self.request(binding+'/token',{**token,'lease_id':bound['lease_id']},actor=actor)
            self.assertEqual(status,200)
            payload=json.loads(base64.urlsafe_b64decode(data['token'].split('.')[1]+'=='))
            self.assertEqual(payload['video']['canPublish'],publisher)
            self.assertFalse(payload['video']['canPublishData'])
            self.assertEqual(payload['video'].get('canPublishSources'),['screen_share'] if publisher else None)
        self.assertEqual(self.request(binding+'/claim',claim)[1]['result_revision'],state['revision'])
        self.assertEqual(self.request(binding+'/operations/'+claim['request_id'])[0],200)
        self.assertEqual(self.request(binding+'/operations/'+claim['request_id'],actor='b')[0],404)
        self.assertEqual(self.request(binding+'/state',actor='other')[0],404)
        self.assertEqual(self.request(binding+'/token',{**token,'expected_revision':0})[0],409)
        self.assertEqual(self.request(binding+'/heartbeat',{'protocol_version':1,'lease_id':first['lease_id'],
                                                          'observed_revision':state['revision'],'capture_state':'sharing'})[0],200)
        stop={'protocol_version':1,'lease_id':first['lease_id'],'request_id':str(uuid4()),'expected_revision':state['revision']}
        self.assertEqual(self.request(binding+'/stop',stop)[0],200)
        self.assertEqual(self.rooms,set())
        unbind={'protocol_version':1,'binding_id':binding,'lease_id':first['lease_id'],'request_id':str(uuid4())}
        self.assertEqual(self.request('unbind',unbind)[1]['snapshot'],None)
        self.assertEqual(self.request('unbind',unbind)[0],200)

    def test_disabled_auth_json_and_revocation(self):
        self.assertEqual(self.request('capabilities',actor='invalid')[0],401)
        self.assertEqual(self.request('bind',raw=b'{"protocol_version":1,"protocol_version":1}')[0],400)
        first,_=self.pair();binding=first['binding_id']
        revision=self.request(binding+'/state')[1]['revision']
        self.request(binding+'/claim',{'protocol_version':1,'lease_id':first['lease_id'],
                                      'expected_revision':revision,'request_id':str(uuid4())})
        self.enabled=False
        self.service.tick()
        self.assertEqual(self.rooms,set())
        self.assertEqual(self.request('capabilities')[1]['screen'],False)
        self.assertEqual(self.request(binding+'/state')[0],503)
        self.enabled=True
        self.assertEqual(self.request(binding+'/state')[0],404)

    def test_claim_limit_does_not_charge_idempotent_replay(self):
        first,_=self.pair();binding=first['binding_id']
        for _ in range(5):
            revision=self.request(binding+'/state')[1]['revision']
            body={'protocol_version':1,'lease_id':first['lease_id'],'expected_revision':revision,'request_id':str(uuid4())}
            self.assertEqual(self.request(binding+'/claim',body)[0],200)
            self.assertEqual(self.request(binding+'/claim',body)[0],200)
        revision=self.request(binding+'/state')[1]['revision']
        status,data=self.request(binding+'/claim',{'protocol_version':1,'lease_id':first['lease_id'],
            'expected_revision':revision,'request_id':str(uuid4())})
        self.assertEqual(status,429)
        self.assertEqual(data['retry_after'],10)


if __name__=='__main__':unittest.main()
