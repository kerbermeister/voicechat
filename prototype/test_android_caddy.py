"""Opt-in real Caddy routing check; never connects to production services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid


@unittest.skipUnless(os.environ.get('VOICECHAT_DOCKER_TESTS') == '1', 'Requires local Docker')
class AndroidCaddyTests(unittest.TestCase):
    def test_apk_route_is_separate_from_spa_and_private_files(self):
        repo = Path(__file__).resolve().parents[1]
        image = (repo/'infra/web.Dockerfile').read_text().splitlines()[0].split()[1]
        name = 'voicechat-update-check-'+uuid.uuid4().hex[:10]
        with tempfile.TemporaryDirectory(dir=repo/'.prototype') as temporary:
            root = Path(temporary)
            (root/'updates/2').mkdir(parents=True)
            (root/'updates/2/voicechat.apk').write_text('test-apk')
            (root/'updates/latest.json').write_text('{"versionCode":2}')
            (root/'updates/previous.json').write_text('private-pointer')
            (root/'web').mkdir()
            (root/'web/index.html').write_text('SPA')
            try:
                subprocess.run(['docker','run','-d','--name',name,'--network','none',
                    '-e','SITE=http://:80','-v',f'{repo}/infra/Caddyfile:/etc/caddy/Caddyfile:ro',
                    '-v',f'{root}/updates:/updates/android:ro','-v',f'{root}/web:/srv:ro',image], check=True, capture_output=True)
                import time
                for _ in range(30):
                    probe = subprocess.run(['docker','exec',name,'wget','-q','-O','-','http://localhost:8080/health'],capture_output=True)
                    if probe.returncode == 0: break
                    time.sleep(.1)
                else:
                    raise AssertionError(subprocess.check_output(['docker','logs',name],stderr=subprocess.STDOUT).decode())
                def get(path):
                    return subprocess.run(['docker','exec',name,'wget','-S','-O','-','http://localhost'+path],capture_output=True,text=True)
                apk = get('/updates/android/2/voicechat.apk')
                self.assertEqual(apk.returncode,0,apk.stderr)
                self.assertEqual(apk.stdout,'test-apk')
                self.assertIn('application/vnd.android.package-archive',apk.stderr)
                self.assertIn('immutable',apk.stderr)
                latest=get('/updates/android/latest.json')
                self.assertIn('no-cache',latest.stderr)
                for path in ('/updates/android/missing.apk','/updates/android/previous.json','/updates/android/.publish.lock'):
                    response=get(path)
                    self.assertNotEqual(response.returncode,0)
                    self.assertIn('404',response.stderr)
                    self.assertNotIn('SPA',response.stdout)
                self.assertEqual(get('/some-client-route').stdout,'SPA')
            finally:
                subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)


if __name__=='__main__': unittest.main()
