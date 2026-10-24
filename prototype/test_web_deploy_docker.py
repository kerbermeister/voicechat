"""Opt-in real Compose health/rollback check, isolated from production and other projects."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'infra'))
import deploy


@unittest.skipUnless(os.environ.get('VOICECHAT_DOCKER_DEPLOY_TEST') == '1', 'Explicit isolated Docker check only')
class WebDeployDockerTests(unittest.TestCase):
    def test_health_rollback_preserves_backend_and_release_records(self):
        source = Path(__file__).resolve().parents[1]
        image = (source/'infra/web.Dockerfile').read_text().splitlines()[0].split()[1]
        subprocess.run(['docker', 'pull', image], check=True, stdout=subprocess.DEVNULL)
        with tempfile.TemporaryDirectory(prefix='voicechat-speed-') as directory:
            root = Path(directory).resolve()
            (root/'runtime').mkdir()
            project = 'voicechat-speed-'+uuid.uuid4().hex[:12]
            (root/'runtime/stand.env').write_text('TEST_PROJECT='+project+'\n')
            compose = {
                'name':'${TEST_PROJECT}',
                'services':{
                    'backend':{'image':image, 'entrypoint':['/bin/sh','-c','sleep 600']},
                    'web':{'image':image, 'command':['caddy','file-server','--root','/srv','--listen',':8080'],
                           'volumes':['../public:/srv:ro'],
                           'healthcheck':{'test':['CMD-SHELL','wget -q -O - http://localhost:8080/health | grep -qx ok'],
                                          'interval':'1s','timeout':'1s','retries':2}}}}
            releases = []
            for n, health in enumerate(('ok','ok','broken')):
                release = root/'releases'/(str(n)*40)
                (release/'infra').mkdir(parents=True)
                (release/'infra/runtime').symlink_to(root/'runtime', target_is_directory=True)
                (release/'infra/compose.yaml').write_text(json.dumps(compose))
                (release/'backend.sha256').write_text('a'*64)
                (release/'public').mkdir()
                (release/'public/health').write_text(health+'\n')
                (release/'public/version').write_text(str(n))
                releases.append(release)
            previous, good, bad = releases
            target = {'commit':'0'*40,'schema':1,'origin':'https://chat.example.com','control':image,'web':image}
            def config(release):
                return json.loads(subprocess.check_output(deploy.compose_command(release,'config','--format','json')))
            def container(service):
                return subprocess.check_output(deploy.compose_command(previous,'ps','-q',service)).decode().strip()
            original_compose = deploy.compose
            def checked_compose(release, env, *args, **kwargs):
                # Real health checks, bounded to 8 seconds for the deliberately bad image content.
                args = tuple('8' if arg=='180' else arg for arg in args)
                return original_compose(release,env,*args,**kwargs)
            try:
                deploy.compose(previous,os.environ.copy(),'up','-d','--wait','--wait-timeout','30')
                backend = container('backend')
                started = subprocess.check_output(['docker','inspect','--format','{{.State.StartedAt}}',backend])
                old = deploy.release_record(previous,target,config(previous))
                (root/'current.json').write_text(json.dumps(old))
                with patch.object(deploy,'compose',side_effect=checked_compose):
                    deploy.web_deploy(root,good,old,{**target,'commit':'1'*40},os.environ.copy(),config(good))
                self.assertEqual(container('backend'),backend)
                current = (root/'current.json').read_bytes()
                rollback = (root/'previous.json').read_bytes()
                with patch.object(deploy,'compose',side_effect=checked_compose):
                    with self.assertRaises(subprocess.CalledProcessError):
                        deploy.web_deploy(root,bad,json.loads(current),{**target,'commit':'2'*40},os.environ.copy(),config(bad))
                self.assertEqual((root/'current.json').read_bytes(),current)
                self.assertEqual((root/'previous.json').read_bytes(),rollback)
                self.assertEqual(container('backend'),backend)
                self.assertEqual(subprocess.check_output(['docker','inspect','--format','{{.State.StartedAt}}',backend]),started)
                self.assertEqual(subprocess.check_output(['docker','exec',container('web'),'wget','-q','-O','-','http://localhost:8080/version']),b'1')
                print('REAL COMPOSE: healthy web update, failed health rollback, unchanged backend ID/start time and release records: PASS')
            finally:
                deploy.compose(previous,os.environ.copy(),'down','--remove-orphans')


if __name__ == '__main__':
    unittest.main()
