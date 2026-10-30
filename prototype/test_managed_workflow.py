import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'infra'))
from test_node_inventory import fixture


def step(name):
    text=(ROOT/'.github/workflows/deploy.yml').read_text()
    body=text.split('      - name: '+name+'\n',1)[1].split('\n      - ',1)[0]
    return body


def python_source(name):
    body=step(name)
    return textwrap.dedent(re.search(r"python3 - <<'PY'\n(.*?)\n          PY",body,re.S).group(1))


class ManagedWorkflowTests(unittest.TestCase):
    def manifest(self,mode,kind='managed'):
        source=python_source('Write immutable release manifest and public source package')
        image='ghcr.io/fixture'
        values={'/tmp/control-image.json':{'containerimage.digest':'sha256:'+'3'*64},
                '/tmp/web-image.json':{'containerimage.digest':'sha256:'+'4'*64},
                '/tmp/current-managed.json':{'control':image+'/control@sha256:'+'1'*64,
                    'web':{'c':image+'/web@sha256:'+'5'*64,'b':image+'/web@sha256:'+'2'*64}},
                '/tmp/current-release.json':{'manifest':{'control':image+'/control@sha256:'+'1'*64}}}
        output=io.StringIO()
        def opened(path,mode='r'):
            if path=='release.json':self.assertEqual(mode,'w');return output
            return io.StringIO(json.dumps(values[path]))
        env={'IMAGE_REPOSITORY':image,'RELEASE_MODE':mode,'ROLLOUT_KIND':kind,'GITHUB_SHA':'a'*40,
             'PUBLIC_URL':'https://chat.fixture.invalid'}
        with patch.dict(os.environ,env),patch('builtins.open',side_effect=opened):
            exec(compile(source,'workflow-manifest','exec'),{})
        return json.loads(output.getvalue())

    def test_modes_reuse_only_the_unbuilt_immutable_image(self):
        for mode,control,web in (('full','3','4'),('web','1','4'),('edge','1','4'),('core','3','2')):
            with self.subTest(mode=mode):
                value=self.manifest(mode)
                self.assertTrue(value['control'].endswith(control*64))
                self.assertTrue(value['web'].endswith(web*64))
                self.assertEqual(value['commit'],'a'*40)
        self.assertTrue(self.manifest('web','legacy')['control'].endswith('1'*64))

    def test_selective_builds_keep_server_and_client_checks(self):
        for name in ('Restore generated crypto assets','Validate generated assets','Build ordinary web application','Build web image'):
            self.assertIn("inputs.mode != 'core'",step(name))
        self.assertIn("inputs.mode == 'full' || inputs.mode == 'core'",step('Build control image for full or core release'))
        checks=step('Test server and client')
        for required in ('unittest discover','test_mobile_web.cjs','flutter analyze','flutter test'):
            self.assertIn(required,checks)
        self.assertNotIn('if:',checks)

    def install_keys(self,keys,*,core='synthetic-core-key',endpoints=None):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        home=Path(temporary.name);(home/'.ssh').mkdir(mode=0o700)
        source=python_source('Set up pinned SSH identity')
        actual_open=os.open
        def opened(path,*args,**kwargs):
            return actual_open(home/'identities.json' if str(path)=='/tmp/voicechat-node-identities.json' else path,*args,**kwargs)
        env={'SERVER_ROLE_CONFIG':json.dumps({'inventory':fixture()}),'SSH_KEY':core,
             'DEPLOY_NODE_SSH_KEYS':json.dumps(keys),
             'DEPLOY_NODE_SSH_CONNECTIONS':json.dumps(endpoints or {})}
        with patch.dict(os.environ,env),patch('pathlib.Path.home',return_value=home),patch.object(os,'open',side_effect=opened):
            exec(compile(source,'workflow-identities','exec'),{})
        return home,json.loads((home/'identities.json').read_text())

    def test_physical_nodes_receive_distinct_private_identity_files(self):
        home,identities=self.install_keys({'edge-b':'synthetic-b-key','edge-c':'synthetic-c-key'})
        self.assertEqual(set(identities),{'core','edge-b','edge-c'})
        for node,path in identities.items():
            path=Path(path)
            self.assertEqual(path.stat().st_mode&0o777,0o600)
            self.assertTrue(path.read_text().endswith('\n'))
            self.assertIn(home,path.parents)
        self.assertEqual((home/'identities.json').stat().st_mode&0o777,0o600)

    def test_public_endpoint_overrides_keep_generated_identity_and_pinned_trust(self):
        home,identities=self.install_keys({'edge-b':'key-b','edge-c':'key-c'},
            endpoints={'edge-b':{'host':'ssh.example.com','port':2207,'user':'root'}})
        self.assertEqual(identities['edge-b'],{'identity_file':str(home/'.ssh/voicechat-nodes/edge-b'),
            'host':'ssh.example.com','port':2207,'user':'root'})
        self.assertIsInstance(identities['core'],str)

    def test_endpoint_configuration_cannot_inject_key_paths_or_ssh_options(self):
        for endpoints in ({'missing':{}},{'core':{'identity_file':'/other'}},
                          {'core':{'ProxyCommand':'unsafe'}},{'core':{'port':True}},
                          {'core':{'host':'-oUnsafe'}}):
            with self.subTest(endpoints=endpoints),self.assertRaises(ValueError):
                self.install_keys({'edge-b':'key-b','edge-c':'key-c'},endpoints=endpoints)

    def test_missing_unknown_and_duplicate_node_credentials_fail_before_deploy(self):
        for keys in ({},{'unknown':'synthetic-key'},
                     {'edge-b':'synthetic-core-key','edge-c':'different'}):
            with self.subTest(nodes=list(keys)),self.assertRaises(ValueError):self.install_keys(keys)

    def test_resume_and_reuse_are_guarded_by_deploy_and_managed_scope(self):
        self.assertIn("inputs.deploy && inputs.rollout == 'managed'",step('Resume the frozen managed release before preparing new artifacts'))
        self.assertIn("inputs.rollout == 'managed' && inputs.mode != 'full'",step('Read managed artifact reuse baseline without changing VPS'))
        self.assertIn("inputs.deploy && inputs.rollout == 'managed'",step('Deploy the ordinary managed release using per-host pinned identities'))
        self.assertIn("inputs.deploy && inputs.rollout == 'legacy'",step('Deploy legacy installation using pinned host identity'))
