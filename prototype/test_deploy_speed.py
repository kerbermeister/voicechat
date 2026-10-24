"""Web-only deployment must preserve backend, data and recoverable release records."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'infra'))
import deploy
import ssh_deploy
from release_source import backend_fingerprint


class DeploySpeedTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory).resolve()
        (root/'runtime').mkdir()
        (root/'runtime/stand.env').write_text("PUBLIC_URL='https://chat.example.com'\n")
        previous, release = [root/'releases'/(char*40) for char in ('a', 'b')]
        for path in (previous, release):
            (path/'infra').mkdir(parents=True)
            (path/'backend.sha256').write_text('c'*64)
        target = {'commit':'b'*40, 'schema':1, 'origin':'https://chat.example.com',
                  'control':'ghcr.io/owner/chat/control@sha256:'+'d'*64,
                  'web':'ghcr.io/owner/chat/web@sha256:'+'e'*64}
        configuration = {'services': {
            'configure': {'environment': {'PUBLIC_URL':target['origin']}},
            'synapse': {'volumes': [{'source': str(release/'prototype/policy.py')}]},
            'web': {'image':target['web']}}}
        prior_config = copy.deepcopy(configuration)
        prior_config['services']['synapse']['volumes'][0]['source'] = str(previous/'prototype/policy.py')
        old = deploy.release_record(previous, {**target, 'commit':'a'*40, 'web':target['web'].replace('e'*64,'f'*64)}, prior_config)
        (release/'release.json').write_text(json.dumps(target))
        (root/'current.json').write_text(json.dumps(old))
        (root/'previous.json').write_text('original rollback')
        return root, release, old, target, configuration

    def test_only_web_is_recreated_and_previous_release_remains_available(self):
        with tempfile.TemporaryDirectory() as directory:
            root, release, old, target, configuration = self.fixture(directory)
            with patch.object(deploy, 'compose') as compose, patch.object(deploy, 'backup') as backup:
                deploy.web_deploy(root, release, old, target, {}, configuration)
            commands = [call.args[2:] for call in compose.call_args_list]
            self.assertEqual(commands[0], ('pull', 'web'))
            self.assertEqual(commands[1], ('up','-d','--no-deps','--wait','--wait-timeout','180','web'))
            backup.assert_not_called()
            self.assertEqual(json.loads((root/'previous.json').read_text()), old)
            current = json.loads((root/'current.json').read_text())
            self.assertEqual(current['manifest'], target)
            self.assertEqual(current['backend_config'], old['backend_config'])
            self.assertEqual(current['backend'], old['backend'])

    def test_changed_backend_runtime_config_or_missing_baseline_cannot_use_web_mode(self):
        for change in ('source', 'control', 'config', 'missing', 'web-image'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root, release, old, target, configuration = self.fixture(directory)
                if change == 'source': (release/'backend.sha256').write_text('0'*64)
                if change == 'control': target['control'] = target['control'].replace('d'*64,'1'*64)
                if change == 'config': configuration['services']['configure']['environment']['NEW_SETTING'] = 'changed'
                if change == 'missing': old.pop('backend_config')
                if change == 'web-image': configuration['services']['web']['image'] = 'unexpected:latest'
                before = (root/'current.json').read_bytes()
                with patch.object(deploy, 'compose') as compose, self.assertRaisesRegex(SystemExit, 'full deployment'):
                    deploy.web_deploy(root, release, old, target, {}, configuration)
                compose.assert_not_called()
                self.assertEqual((root/'current.json').read_bytes(), before)

    def test_failed_web_healthcheck_rolls_back_only_web_without_advancing_records(self):
        with tempfile.TemporaryDirectory() as directory:
            root, release, old, target, configuration = self.fixture(directory)
            before = (root/'current.json').read_bytes()
            with patch.object(deploy, 'compose', side_effect=[None, RuntimeError('health failed'), None]) as compose:
                with self.assertRaisesRegex(RuntimeError, 'health failed'):
                    deploy.web_deploy(root, release, old, target, {}, configuration)
            restored = compose.call_args_list[-1]
            self.assertEqual(restored.args[0], Path(old['release']))
            self.assertEqual(restored.args[1]['WEB_IMAGE'], old['manifest']['web'])
            self.assertIn('--no-deps', restored.args)
            self.assertEqual(restored.args[-1], 'web')
            self.assertEqual((root/'current.json').read_bytes(), before)
            self.assertEqual((root/'previous.json').read_text(), 'original rollback')

    def test_full_update_after_web_still_backs_up(self):
        with tempfile.TemporaryDirectory() as directory:
            root, release, old, target, configuration = self.fixture(directory)
            with patch.object(deploy, 'compose'):
                deploy.web_deploy(root, release, old, target, {}, configuration)
            current = json.loads((root/'current.json').read_text())
            with patch.object(deploy.subprocess, 'check_output', side_effect=[json.dumps(configuration).encode(), b'postgres']), \
                 patch.object(deploy, 'execute'), patch.object(deploy, 'backup') as backup:
                deploy.deploy(root, release, current)
            self.assertEqual(backup.call_args.args[1], release)
            self.assertEqual(json.loads((root/'current.json').read_text())['backend'], 'c'*64)

    def test_source_fingerprint_ignores_only_explicitly_frontend_and_docs_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.STDOUT)
            git('init','-q')
            git('config','user.name','Test')
            git('config','user.email','test@example.invalid')
            def commit(name):
                path = root/name
                path.parent.mkdir(parents=True,exist_ok=True)
                path.write_text('change')
                git('add','.')
                git('commit','-qm','fixture')
                return backend_fingerprint(root)
            initial = commit('infra/compose.yaml')
            self.assertEqual(commit('apps/client/lib/main.dart'), initial)
            self.assertEqual(commit('docs/notes.md'), initial)
            self.assertEqual(commit('infra/Caddyfile'), initial)
            backend = commit('prototype/screen_schema.sql')
            self.assertNotEqual(backend, initial)
            self.assertNotEqual(commit('unknown-runtime-file'), backend)

    def test_ssh_target_validation_rejects_shell_and_path_injection(self):
        values = {'DEPLOY_HOST':'84.200.80.13', 'DEPLOY_USER':'root', 'DEPLOY_ROOT':'/srv/voicechat'}
        with patch.dict(ssh_deploy.os.environ, values):
            ssh, target, root = ssh_deploy.connection()
            self.assertEqual(target,'root@84.200.80.13')
            self.assertIn('StrictHostKeyChecking=yes',ssh)
            self.assertEqual(root,'/srv/voicechat')
        for key, value in [('DEPLOY_HOST','host; touch /tmp/file'), ('DEPLOY_USER','root@elsewhere'),
                           ('DEPLOY_ROOT','/srv/../etc'), ('DEPLOY_ROOT','/srv/voice chat')]:
            with self.subTest(key=key,value=value), patch.dict(ssh_deploy.os.environ,{**values,key:value}):
                with self.assertRaises(ValueError): ssh_deploy.connection()

    def test_cache_keys_cover_pinned_inputs_not_application_ui(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root/'.github/workflows/deploy.yml').read_text()
        keys = [line for line in workflow.splitlines() if 'key: crypto-' in line]
        self.assertEqual(len(keys), 2)
        for key in keys:
            self.assertIn('runner.os', key)
            self.assertIn('runner.arch', key)
            self.assertIn('infra/crypto-tools.json', key)
            self.assertNotIn('apps/client/lib/', key)
        assets = keys[0]
        for path in ('prototype/build_web_assets.py', 'prototype/build_qr_assets.py', 'apps/client/pubspec.lock', 'vendor/matrix/lib/**'):
            self.assertIn(path, assets)
        config = json.loads((root/'infra/crypto-tools.json').read_text())
        self.assertIn("flutter-version: '"+config['flutter']+"'", workflow)
        self.assertRegex(config['nightly'], r'^nightly-\d{4}-\d{2}-\d{2}$')


if __name__ == '__main__':
    unittest.main()
