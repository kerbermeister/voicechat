import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

infra=Path(__file__).resolve().parents[1]/'infra'
sys.path.insert(0,str(infra))
from client_config import client_config
import configure
import bootstrap
import deploy

class DeploymentTests(unittest.TestCase):
    def test_policy_upgrade_preserves_operator_limits_and_adds_new_defaults(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(configure.os, 'chown'):
            defaults, target = (Path(directory) / name for name in ('defaults.json', 'policy.json'))
            defaults.write_text(json.dumps({'version':1, 'text_max_length':16000, 'schedule_max_seconds':172800}))
            target.write_text(json.dumps({'version':1, 'text_max_length':8000}))
            configure.configure_policy(defaults, target)
            self.assertEqual(json.loads(target.read_text()), {'version':1, 'text_max_length':8000, 'schedule_max_seconds':172800})
            target.write_text(json.dumps({'version':1, 'text_max_length':8000, 'schedule_max_seconds':3600}))
            configure.configure_policy(defaults, target)
            self.assertEqual(json.loads(target.read_text())['schedule_max_seconds'],3600)
            target.write_text('invalid')
            with self.assertRaises(ValueError): configure.configure_policy(defaults,target)
            self.assertEqual(target.read_text(),'invalid')

    def test_endpoint_origins_are_canonical_and_never_contain_credentials(self):
        self.assertEqual(client_config('https://EXAMPLE.com:443/'), {
            'MATRIX_URL':'https://example.com','TOKEN_URL':'https://example.com/api','LIVEKIT_URL':'wss://example.com'})
        self.assertEqual(client_config('http://localhost:7360')['LIVEKIT_URL'],'ws://localhost:7360')
        for url in ('http://example.com','https://u:p@example.com','https://example.com/path','javascript:alert(1)','https://example.com?q=1','https://example.com:0'):
            with self.assertRaises(ValueError): client_config(url)

    def test_manifest_rejects_tags_credentials_and_unsupported_schema(self):
        value={'commit':'a'*40,'schema':1,'origin':'https://chat.example.com',
               'control':'ghcr.io/owner/chat/control@sha256:'+'b'*64,
               'web':'ghcr.io/owner/chat/web@sha256:'+'c'*64}
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'release.json'
            path.write_text(json.dumps(value))
            self.assertEqual(deploy.manifest(path),value)
            for change in ({'schema':True},{'schema':2},{'commit':'main'},{'web':'ghcr.io/owner/chat/web:latest'},
                           {'origin':'https://name:password@chat.example.com'}, {'extra':'unrecognized'}):
                path.write_text(json.dumps({**value,**change}))
                with self.assertRaises(ValueError): deploy.manifest(path)

    def test_failed_backup_resumes_previous_release_without_advancing_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            runtime=root/'runtime'; runtime.mkdir()
            (runtime/'stand.env').write_text("PUBLIC_URL='https://chat.example.com'\n")
            release=root/'releases'/('a'*40); (release/'infra').mkdir(parents=True)
            value={'commit':'a'*40,'schema':1,'origin':'https://chat.example.com',
                   'control':'ghcr.io/owner/chat/control@sha256:'+'b'*64,
                   'web':'ghcr.io/owner/chat/web@sha256:'+'c'*64}
            (release/'release.json').write_text(json.dumps(value))
            old={'release':str(root/'releases'/('d'*40)),
                 'manifest':{**value,'commit':'d'*40,'control':'ghcr.io/owner/chat/control@sha256:'+'e'*64}}
            current=root/'current.json'; current.write_text(json.dumps(old))
            config=json.dumps({'services':{'configure':{'environment':{'PUBLIC_URL':value['origin']}}}}).encode()
            with patch.object(sys,'argv',['deploy.py','--root',str(root),'--release',str(release)]), \
                 patch.object(deploy.subprocess,'check_output',side_effect=[config,b'postgres']), \
                 patch.object(deploy,'execute') as execute, \
                 patch.object(deploy,'backup',side_effect=OSError('Backup storage unavailable')):
                with self.assertRaisesRegex(OSError,'Backup storage unavailable'): deploy.main()
            self.assertEqual(json.loads(current.read_text()),old)
            calls=execute.call_args_list
            self.assertTrue(any(c.kwargs.get('env',{}).get('CONTROL_IMAGE')==old['manifest']['control']
                                and 'up' in c.args[0] for c in calls))
            self.assertFalse(any('down' in c.args[0] for c in calls))

    def test_bootstrap_preserves_identity_secrets_and_private_permissions(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(bootstrap,'__file__',str(Path(directory)/'bootstrap.py')), patch.dict(os.environ,{'SMTP_USER':'a$'+chr(92)+"'",'SMTP_PASSWORD':"p$'"},clear=True), patch.object(sys,'argv',['bootstrap.py']), contextlib.redirect_stdout(io.StringIO()):
            bootstrap.main()
            path=Path(directory)/'runtime/stand.env'
            initial=path.read_bytes()
            self.assertEqual(path.stat().st_mode & 0o777,0o600)
            self.assertNotIn(b"p$'",initial)
            self.assertIn(base64.b64encode("p$'".encode()),initial)
            bootstrap.main()
            self.assertEqual(path.read_bytes(),initial)

if __name__=='__main__': unittest.main()
