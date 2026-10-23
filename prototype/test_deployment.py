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
import setup_yandex

class DeploymentTests(unittest.TestCase):
    def test_yandex_bootstrap_requires_verified_smtp_login(self):
        for failure in (None, setup_yandex.smtplib.SMTPAuthenticationError(535, b'echoed-secret'),
                        OSError('echoed-secret'), setup_yandex.smtplib.SMTPException('echoed-secret')):
            with self.subTest(failure=failure), patch.dict(os.environ,{},clear=True), \
                 patch.object(Path,'exists',return_value=False), \
                 patch('builtins.input',return_value='sender@yandex.ru'), \
                 patch.object(setup_yandex.getpass,'getpass',return_value='test-only'), \
                 patch.object(setup_yandex.smtplib,'SMTP') as smtp, \
                 patch.object(bootstrap,'main') as initialize:
                connection = smtp.return_value.__enter__.return_value
                connection.login.side_effect = failure
                if failure:
                    with self.assertRaisesRegex(SystemExit,'(authentication|connection) failed') as result:
                        setup_yandex.main()
                    self.assertNotIn('echoed-secret', str(result.exception))
                    if isinstance(failure, setup_yandex.smtplib.SMTPAuthenticationError):
                        self.assertIn('SMTP 535', str(result.exception))
                        self.assertIn('2-3 hours', str(result.exception))
                    initialize.assert_not_called()
                    self.assertNotIn('SMTP_PASSWORD',os.environ)
                else:
                    setup_yandex.main()
                    initialize.assert_called_once()
                    self.assertEqual(os.environ['SMTP_FROM'],'VoiceChat <sender@yandex.ru>')
                    self.assertEqual(os.environ['SMTP_HOST'],'smtp.yandex.ru')
                    connection.login.assert_called_once_with('sender@yandex.ru','test-only')
                self.assertTrue(connection.starttls.call_args.kwargs['context'].check_hostname)

    def test_shared_proxy_override_is_used_for_all_compose_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory)
            runtime = release/'infra/runtime'
            runtime.mkdir(parents=True)
            base = deploy.compose_command(release, 'ps', '-q', 'postgres')
            self.assertEqual(base.count('-f'), 1)
            override = runtime/'compose.override.yaml'
            override.write_text('services: {}')
            for args in (('config','--format','json'), ('ps','-q','postgres'), ('up','-d'), ('exec','-T','postgres','pg_dump')):
                command = deploy.compose_command(release, *args)
                self.assertEqual(command.count('-f'), 2)
                self.assertIn(str(override), command)
                self.assertEqual(command[-len(args):], list(args))

    def test_smtp_sender_override_and_header_validation(self):
        env = {'LOCAL_STAND':'0', 'MATRIX_SERVER_NAME':'univc.duckdns.org',
               'PUBLIC_URL':'https://univc.duckdns.org', 'PUBLIC_IP':'84.200.80.13',
               'SMTP_HOST':'smtp.example.com', 'SMTP_PORT':'587',
               **{key:'test-only' for key in ('POLICY_SECRET','POSTGRES_PASSWORD',
                  'REGISTRATION_SECRET','MACAROON_SECRET','LIVEKIT_SECRET','TURN_SECRET')}}
        for sender in (None, 'VoiceChat <verified@example.com>', 'sender\r\nBcc: other@example.com', ' '):
            values = dict(env)
            if sender is not None:
                values['SMTP_FROM_B64'] = base64.b64encode(sender.encode()).decode()
            with self.subTest(sender=sender), patch.dict(os.environ,values,clear=True), \
                 patch.object(Path,'exists',return_value=False), \
                 patch.object(configure,'configure_policy'), patch.object(configure,'write') as write:
                if sender in ('sender\r\nBcc: other@example.com', ' '):
                    with self.assertRaisesRegex(ValueError,'SMTP_FROM'): configure.main()
                    write.assert_not_called()
                else:
                    configure.main()
                    synapse = json.loads(write.call_args_list[0].args[1])
                    self.assertEqual(synapse['email']['notif_from'], sender or 'VoiceChat <noreply@univc.duckdns.org>')
                    self.assertTrue(synapse['email']['require_transport_security'])

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

    def test_backup_only_resumes_current_without_changing_release_records(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'runtime').mkdir()
            (root/'runtime/stand.env').write_text("PUBLIC_URL='https://chat.example.com'\n")
            release = root/'releases'/('a'*40)
            (release/'infra').mkdir(parents=True)
            value = {'commit':'a'*40, 'schema':1, 'origin':'https://chat.example.com',
                     'control':'ghcr.io/owner/chat/control@sha256:'+'b'*64,
                     'web':'ghcr.io/owner/chat/web@sha256:'+'c'*64}
            (release/'release.json').write_text(json.dumps(value))
            current = json.dumps({'release':str(release), 'manifest':value})
            (root/'current.json').write_text(current)
            (root/'previous.json').write_text('previous release')
            config = json.dumps({'services':{'configure':{'environment':{'PUBLIC_URL':value['origin']}}}}).encode()
            for failure in (None, OSError('backup failed')):
                with self.subTest(failure=failure), \
                     patch.object(sys,'argv',['deploy.py','--root',str(root),'--backup-only']), \
                     patch.object(deploy.subprocess,'check_output',side_effect=[config,b'postgres']), \
                     patch.object(deploy,'execute') as execute, \
                     patch.object(deploy,'backup',side_effect=failure) as backup:
                    if failure:
                        with self.assertRaisesRegex(OSError,'backup failed'): deploy.main()
                    else:
                        deploy.main()
                    backup.assert_called_once()
                    self.assertEqual(backup.call_args.args[1], release)
                    calls = [call.args[0] for call in execute.call_args_list]
                    stop = next(i for i, args in enumerate(calls) if 'stop' in args)
                    resume = next(i for i, args in enumerate(calls) if 'up' in args)
                    self.assertLess(stop, resume)
                    self.assertFalse(any('compose' in args and 'pull' in args for args in calls))
                    self.assertEqual((root/'current.json').read_text(), current)
                    self.assertEqual((root/'previous.json').read_text(), 'previous release')

    def test_backup_includes_identity_sqlite_certificates_and_release_without_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'runtime').mkdir()
            release = root/'releases'/('a'*40)
            with patch.object(deploy,'execute') as execute:
                deploy.backup(root, release, {})
            commands = [call.args[0] for call in execute.call_args_list]
            snapshot = next(args for args in commands if 'backup' in args)
            for mount in ('voicechat_control:/snapshot/control:ro',
                          'voicechat_synapse:/snapshot/synapse:ro',
                          'voicechat_media-config:/snapshot/media-config:ro',
                          'voicechat_certificates:/snapshot/certificates:ro',
                          f'{release}:/snapshot/release:ro',
                          f'{root}/current.json:/snapshot/current.json:ro',
                          f'{root}/runtime/stand.env:/snapshot/runtime/stand.env:ro'):
                self.assertIn(mount, snapshot)
            self.assertNotIn(f'{root}/runtime:/snapshot/runtime:ro', snapshot)
            self.assertEqual(commands[-1][-1], 'check')
            self.assertEqual((root/'runtime/backup-password').stat().st_mode & 0o777, 0o600)
            (root/'runtime/backup-password').unlink()
            with self.assertRaisesRegex(RuntimeError,'key is missing'):
                deploy.backup(root, release, {})

if __name__=='__main__': unittest.main()
