from copy import deepcopy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'infra'))
import initial_entry
import release_delivery
import route_catalog
import ssh_deploy
import topology
from test_node_inventory import fixture
import test_release_delivery


class InitialEntryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary=tempfile.TemporaryDirectory();cls.addClassCleanup(temporary.cleanup)
        cls.key=Path(temporary.name)/'synthetic.pem'
        subprocess.run(['openssl','genpkey','-algorithm','ED25519','-out',str(cls.key)],check=True,capture_output=True)
        cls.public_key=route_catalog.public_key(cls.key)

    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        self.base=Path(temporary.name).resolve()
        public=topology.load(ROOT/'infra/single-vps.example.json');inventory=fixture()
        inventory['edges']=[{'id':'a','host':'core','legacy_turn':True,'shared_tls':{
            'network':'voicechat-shared-ingress','subnet':'172.29.0.0/29',
            'legacy_ip':'172.29.0.2','ingress_ip':'172.29.0.3'}}]
        now=int(time.time())
        self.value={'schema':1,'root':str(self.base/'managed'),'legacy_root':str(self.base/'legacy'),
            'shared_root':str(self.base/'shared'),'public':public,'inventory':inventory,
            'subnet':'10.241.0.0/28','catalog_key':self.public_key,
            'catalog':route_catalog.sign(public,self.key,1,now,now+3600)}

    def raw(self):return json.dumps(self.value).encode()

    def test_request_accepts_public_signature_and_rejects_unknown_secret_paths_and_schema(self):
        self.assertEqual(initial_entry.request(self.raw()),self.value)
        for change in ({'private_key':'never-upload'},{'schema':True},{'root':'/srv/a/../b'},
                       {'root':'/'},{'shared_root':self.value['root']+'/child'}):
            with self.subTest(change=change),self.assertRaises(ValueError):
                initial_entry.request(json.dumps({**self.value,**change}).encode())
        with self.assertRaisesRegex(ValueError,'too large'):initial_entry.request(b' '*65537)
        with self.assertRaises(ValueError):initial_entry.request(self.raw().replace(b'"schema": 1',b'"schema": 1, "schema": 1',1))

    def test_invalid_signature_or_noninitial_host_inventory_is_rejected(self):
        value=deepcopy(self.value);value['catalog']['signature']='A'*88
        with self.assertRaises(ValueError):initial_entry.request(json.dumps(value).encode())
        value=deepcopy(self.value);value['inventory']['edges'][0]['legacy_turn']=False
        with self.assertRaisesRegex(ValueError,'canonical cohost'):initial_entry.request(json.dumps(value).encode())
        self.value['subnet']='10.88.0.0/28'
        with self.assertRaisesRegex(ValueError,'overlaps'):initial_entry.request(self.raw())

    def test_environment_separates_offline_signature_from_client_key_and_checks_origin(self):
        config={name:value for name,value in self.value.items() if name not in ('catalog','catalog_key')}
        env={'SERVER_ROLE_CONFIG':json.dumps(config),'SIGNED_ROUTE_CATALOG':json.dumps(self.value['catalog']),
             'CLIENT_ROUTE_CATALOG_KEY':self.public_key,'PUBLIC_URL':self.value['public']['canonical_origin']}
        with patch.dict(os.environ,env):self.assertEqual(initial_entry.environment(),self.value)
        with patch.dict(os.environ,{**env,'PUBLIC_URL':'https://foreign.example.com'}):
            with self.assertRaisesRegex(ValueError,'origins differ'):initial_entry.environment()

    def test_deploy_verifies_complete_bundle_before_calling_controller(self):
        case=test_release_delivery.ImmutableSourceDeliveryTests();case.setUp();self.addCleanup(case.doCleanups)
        raw,sha=case.archive();root=Path(self.value['root'])
        source=release_delivery.install(raw,root,sha,case.manifest['commit'])
        with patch.object(initial_entry.platform,'system',return_value='Linux'), \
             patch.object(initial_entry,'os',SimpleNamespace(geteuid=lambda:0)), \
             patch.object(initial_entry.shutil,'which',return_value='/fixture/tool'), \
             patch.object(initial_entry.initial_cohost,'migrate',return_value={'target':{'synthetic':True}}) as migrate:
            result=initial_entry.deploy(self.raw(),root,sha,source=source,retry=True)
            self.assertEqual(result['kind'],'roles');self.assertTrue(migrate.call_args.kwargs['retry'])
            self.assertEqual(migrate.call_args.args[5],case.manifest)
            (source/'infra/core_deploy.py').write_text('changed')
            with self.assertRaisesRegex(ValueError,'source file changed'):
                initial_entry.deploy(self.raw(),root,sha,source=source)

    def test_transport_keeps_request_on_stdin_and_validates_completion(self):
        delivery={'path':self.value['root']+'/bundles/'+'a'*64,'archive_sha256':'a'*64}
        response={'schema':1,'kind':'roles','root':self.value['root'],'commit':'b'*40,'target':'c'*64}
        ssh=['ssh','-o','StrictHostKeyChecking=yes','root@fixture']
        with patch.object(ssh_deploy,'receive',return_value=delivery) as receive, \
             patch.object(ssh_deploy.subprocess,'check_output',return_value=json.dumps(response).encode()) as execute:
            self.assertEqual(ssh_deploy.initial(ssh,self.value,'b'*40,'/fixture/archive',retry=True),response)
            args=execute.call_args.args[0]
            self.assertEqual(args[:-1],ssh);self.assertIn('--retry',args[-1])
            self.assertNotIn(self.public_key,args[-1]);self.assertEqual(json.loads(execute.call_args.kwargs['input']),self.value)
            receive.assert_called_once()
            execute.return_value=json.dumps({**response,'commit':'d'*40}).encode()
            with self.assertRaisesRegex(ValueError,'unexpected completion'):
                ssh_deploy.initial(ssh,self.value,'b'*40,'/fixture/archive')
        invalid={**self.value,'schema':False}
        with patch.object(ssh_deploy,'receive') as receive:
            with self.assertRaises(ValueError):ssh_deploy.initial(ssh,invalid,'b'*40,'/fixture/archive')
            receive.assert_not_called()
