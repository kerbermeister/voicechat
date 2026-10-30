import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'infra'))
import release_delivery
import release_source
import ssh_deploy
import test_release_delivery


class SourceTransportTests(unittest.TestCase):
    def setUp(self):
        self.case=test_release_delivery.ImmutableSourceDeliveryTests();self.case.setUp()
        self.addCleanup(self.case.doCleanups)
        self.repo=self.case.base/'repository';self.repo.mkdir()
        self.git=['git','-C',str(self.repo)]
        subprocess.run([*self.git,'init','-q','-b','main'],check=True)
        for name,raw in self.case.files.items():
            if name in ('release.json','backend.sha256'):continue
            path=self.repo/name;path.parent.mkdir(exist_ok=True);path.write_bytes(raw)
        subprocess.run([*self.git,'add','infra','prototype'],check=True)
        subprocess.run([*self.git,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
            '-c','commit.gpgsign=false','commit','-q','-m','source fixture'],check=True)
        self.commit=subprocess.check_output([*self.git,'rev-parse','HEAD']).decode().strip()
        self.case.manifest['commit']=self.commit
        self.case.files['release.json']=json.dumps(self.case.manifest).encode()
        self.case.files['backend.sha256']=release_source.backend_fingerprint(self.repo).encode()
        self.archive=self.case.base/'source.tar.gz'
        self.ssh=['ssh-fixture','-o','StrictHostKeyChecking=yes','root@fixture']
        self.calls=[];self.output=subprocess.check_output;self.run=subprocess.run
        self.temporary='/tmp/voicechat-source.ABCDEFGHIJ'
        self.remote_response=None

    def prepare(self):
        self.raw,self.sha=self.case.archive();self.archive.write_bytes(self.raw)
        self.expected={'schema':1,'path':'/srv/voicechat-managed/bundles/'+self.sha,'archive_sha256':self.sha}

    def check_output(self,args,**kwargs):
        if args[0]=='git':return self.output(args,**kwargs)
        self.assertEqual(args[:-1],self.ssh);self.calls.append((args,kwargs))
        if 'mktemp -d' in args[-1]:
            self.assertEqual(kwargs['input'],self.case.files['infra/release_delivery.py'])
            return (self.temporary+'\n').encode()
        self.assertIn('python3 -B',args[-1]);self.assertEqual(kwargs['input'],self.raw)
        return json.dumps(self.expected if self.remote_response is None else self.remote_response).encode()

    def execute(self,args,**kwargs):
        if args[0]=='git':return self.run(args,**kwargs)
        self.assertEqual(args[:-1],self.ssh);self.calls.append((args,kwargs))
        self.assertEqual(args[-1],'rm -f /tmp/voicechat-source.ABCDEFGHIJ/receiver.py && rmdir /tmp/voicechat-source.ABCDEFGHIJ')
        self.assertTrue(kwargs['check']);return subprocess.CompletedProcess(args,0)

    def receive(self):
        with patch.object(ssh_deploy.subprocess,'check_output',side_effect=self.check_output), \
                patch.object(ssh_deploy.subprocess,'run',side_effect=self.execute):
            return ssh_deploy.receive(self.ssh,'/srv/voicechat-managed',self.commit,self.archive,checkout=self.repo)

    def test_clean_git_source_is_sent_as_bootstrap_then_archive_and_unique_directory_is_removed(self):
        self.prepare()
        self.assertEqual(self.receive(),self.expected)
        self.assertEqual(len(self.calls),3)
        self.assertTrue(all(args[:len(self.ssh)]==self.ssh for args,_ in self.calls))

    def test_dirty_checkout_is_refused_before_any_ssh(self):
        self.prepare();(self.repo/'infra/core_deploy.py').write_bytes(b'local changed source')
        with self.assertRaisesRegex(ValueError,'Commit reviewed'):self.receive()
        self.assertEqual(self.calls,[])

    def test_core_guard_is_verified_against_exact_git_tree_before_ssh(self):
        self.case.files['core-scope.sha256'] = release_source.core_scope_fingerprint(self.repo).encode()
        self.prepare()
        self.assertEqual(self.receive(), self.expected)
        self.calls.clear()
        self.case.files['core-scope.sha256'] = b'0' * 64
        self.prepare()
        with self.assertRaisesRegex(ValueError, 'Core source guard differs'):
            self.receive()
        self.assertEqual(self.calls, [])

    def test_unknown_source_bytes_and_wrong_backend_fingerprint_never_leave_runner(self):
        original=dict(self.case.files)
        for name,raw,error in (('infra/private.pem',b'synthetic fixture','file set'),
                              ('infra/core_deploy.py',b'changed archive source','bytes differ'),
                              ('backend.sha256',b'f'*64,'fingerprint')):
            with self.subTest(name=name):
                self.case.files={**original,name:raw};self.prepare()
                with self.assertRaisesRegex(ValueError,error):self.receive()
                self.assertEqual(self.calls,[])

    def test_unexpected_remote_path_does_not_execute_archive_or_cleanup_an_unknown_directory(self):
        self.prepare();self.temporary='/tmp/voicechat-source.ABCDEFGHIJ; touch /tmp/wrong'
        with self.assertRaisesRegex(ValueError,'bootstrap path'):self.receive()
        self.assertEqual(len(self.calls),1)

    def test_wrong_receiver_reply_still_cleans_only_its_known_bootstrap(self):
        self.prepare();self.remote_response={'schema':1,'path':'/etc','archive_sha256':self.sha}
        with self.assertRaisesRegex(ValueError,'unexpected artifact'):self.receive()
        self.assertEqual(len(self.calls),3)
        self.assertTrue(self.calls[-1][0][-1].startswith('rm -f /tmp/voicechat-source.'))


if __name__=='__main__':unittest.main()
