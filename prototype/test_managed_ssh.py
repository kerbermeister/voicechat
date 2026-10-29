from contextlib import contextmanager
import json
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'infra'))
import managed_control
import managed_journal
import managed_ssh
import role_release
import test_managed_journal


class ManagedSshTests(unittest.TestCase):
    def setUp(self):
        self.fixture=test_managed_journal.ManagedJournalTests();self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups);self.root=self.fixture.root
        self.coordinator=self.enterContext(patch.object(managed_ssh,'_coordinator',side_effect=self.control))
        self.peer=self.enterContext(patch.object(managed_ssh,'invoke',side_effect=self.proof))
        self.fail_peer=False;self.uncertain=False;self.preflight_failure=False
        self.receives=self.enterContext(patch('ssh_deploy.receive',return_value={
            'schema':1,'path':str(self.root/'bundles'/('d'*64)),'archive_sha256':'d'*64}))
        self.connected=[]

    @contextmanager
    def connect(self,peer,identity):
        self.connected.append(peer['host']);yield ['ssh','pinned-'+peer['host']]

    def control(self,ssh,root,source,action,**kw):
        if action=='status':
            if not (root/'rollout.json').exists():return {'attempt':None}
            journal=managed_journal.read(root)
            return {'attempt':journal['attempt'],'active_source':journal['request']['source']}
        if action=='prepare':
            return managed_control.prepare(root,source,scope=kw['scope'],edges=kw['edges'],
                position=kw['position'],expected_baseline=kw['baseline'])
        if action=='begin':
            managed_journal.begin(root,source,kw['baseline'],scope=kw['scope'],edges=kw['edges'],retry=kw['retry'])
        elif action=='ack':managed_journal.acknowledge(root,kw['attempt'],kw['phase'],kw['position'],kw['proof'])
        elif action=='commit':managed_journal.commit(root,kw['attempt'])
        elif action=='rollback':managed_journal.start_rollback(root,kw['attempt'])
        elif action=='finish':
            journal=managed_journal.read(root,kw['attempt'])
            self.assertIn(journal['phase'],('complete','rolled-back'))
            return {'phase':journal['phase'],'maintenance_ready':True,
                    'scope':journal['request']['scope'],'selected_edges':journal['request']['edges']}
        return managed_control.next_operation(root,kw.get('attempt'))

    def proof(self,ssh,root,source,entry,value):
        self.assertEqual(entry,'managed_peer')
        if value['operation']=='preflight':
            if self.preflight_failure:raise managed_ssh.RemoteFailure('Unavailable preflight host')
            return {'facts':{'manifest':value['before'],'data_identity':value['data_identity']},'fence':None}
        journal=managed_journal.read(root)
        if self.uncertain and journal['phase']=='applying':raise RuntimeError('Uncertain SSH outcome')
        if self.fail_peer and journal['phase']=='applying' and value['target']['role']=='edge':
            self.fail_peer=False;raise managed_ssh.RemoteFailure('Known edge apply failure')
        self.fixture.journal=journal;self.fixture.attempt=journal['attempt']
        step={key:value['target'][key] for key in ('role','edge_id')}
        restoring=journal['phase'].startswith('rollback') or journal['phase']=='rolling-back'
        before=journal['phase']=='fencing' or restoring
        return self.fixture.proof(step,value['before'] if before else value['target'],restored=restoring,
                                  released=journal['phase'] in ('releasing','rollback-releasing'))

    def release(self,**kw):
        return managed_ssh.release(['ssh','pinned-core'],self.root,self.fixture.candidate['commit'],
            '/fixture/public-archive','/fixture/identity',connect=self.connect,**kw)

    def test_preflight_stages_each_physical_host_before_begin_then_finishes_release(self):
        result=self.release()
        self.assertEqual(result['phase'],'complete')
        self.assertEqual(self.receives.call_count,3)
        self.assertEqual(managed_journal.read(self.root)['phase'],'complete')
        self.assertTrue(result['maintenance_ready'])

    def test_preflight_failure_does_not_begin_or_fence_any_role(self):
        self.preflight_failure=True;before=(self.root/'current.json').read_bytes()
        with self.assertRaises(managed_ssh.RemoteFailure):self.release()
        self.assertFalse((self.root/'rollout.json').exists())
        self.assertEqual((self.root/'current.json').read_bytes(),before)
        self.assertFalse(any(call.args[3]=='begin' for call in self.coordinator.call_args_list))

    def test_known_edge_failure_rolls_back_and_preserves_original_pointer(self):
        self.fail_peer=True;before=(self.root/'current.json').read_bytes()
        with self.assertRaisesRegex(managed_ssh.RemoteFailure,'rolled back'):self.release()
        self.assertEqual(managed_journal.read(self.root)['phase'],'rolled-back')
        self.assertEqual((self.root/'current.json').read_bytes(),before)

    def test_uncertain_ssh_result_is_preserved_without_starting_rollback(self):
        self.uncertain=True
        with self.assertRaisesRegex(RuntimeError,'Uncertain SSH outcome'):self.release()
        self.assertEqual(managed_journal.read(self.root)['phase'],'applying')
        self.assertFalse(any(call.args[3]=='rollback' for call in self.coordinator.call_args_list))
        self.uncertain=False
        result=managed_ssh.drive(['ssh','pinned-core'],self.root,'d'*64,'/fixture/identity',connect=self.connect)
        self.assertEqual(result['phase'],'complete')

    def test_same_finished_artifact_does_not_create_another_attempt(self):
        self.release();attempt=managed_journal.read(self.root)['attempt'];self.release()
        self.assertEqual(managed_journal.read(self.root)['attempt'],attempt)

    def test_selected_web_scope_stages_only_core_and_selected_edge(self):
        self.fixture.candidate['control']=self.fixture.baseline['core']['images']['control']
        self.fixture.receipt['manifest']=self.fixture.candidate
        result=self.release(scope='web',edges=['c'])
        self.assertEqual(result['phase'],'complete');self.assertEqual(self.receives.call_count,2)
        journal=managed_journal.read(self.root)
        self.assertEqual(journal['steps'],[{'role':'edge','edge_id':'c'}])


class ManagedTransportTests(unittest.TestCase):
    def test_busy_and_lost_connection_retry_without_exposing_private_progress(self):
        outputs=[SimpleNamespace(returncode=75,stdout=b'',stderr=b'busy'),
                 SimpleNamespace(returncode=255,stdout=b'',stderr=b'connection lost'),
                 SimpleNamespace(returncode=0,stdout=b'private backup progress\n{"schema":1}\n',stderr=b'')]
        with patch.object(managed_ssh.subprocess,'run',side_effect=outputs) as run, \
             patch.object(managed_ssh.time,'sleep'):
            result=managed_ssh.invoke(['ssh','pinned'],'/srv/managed','a'*64,'managed_entry',{'schema':1,'action':'status'})
        self.assertEqual(result,{'schema':1});self.assertEqual(run.call_count,3)
        self.assertEqual(json.loads(run.call_args.kwargs['input']),{'schema':1,'action':'status'})
        self.assertIn('--source-sha '+ 'a'*64,run.call_args.args[0][-1])

    def test_remote_failure_differs_from_uncertain_ssh_outcome(self):
        with patch.object(managed_ssh.subprocess,'run',return_value=SimpleNamespace(returncode=1,stdout=b'',stderr=b'private failure')):
            with self.assertRaises(managed_ssh.RemoteFailure):
                managed_ssh.invoke(['ssh'],'/srv/managed','a'*64,'managed_entry',{'schema':1,'action':'status'})
        with patch.object(managed_ssh.subprocess,'run',return_value=SimpleNamespace(returncode=255,stdout=b'',stderr=b'')), \
             patch.object(managed_ssh.time,'sleep'):
            with self.assertRaises(RuntimeError) as caught:
                managed_ssh.invoke(['ssh'],'/srv/managed','a'*64,'managed_entry',{'schema':1,'action':'status'})
        self.assertNotIsInstance(caught.exception,managed_ssh.RemoteFailure)

    def test_connection_pins_host_and_removes_its_temporary_known_hosts(self):
        from test_node_inventory import key
        with tempfile.TemporaryDirectory() as folder:
            identity=Path(folder)/'identity';identity.write_text('synthetic fixture identity');identity.chmod(0o600)
            peer={'host':'192.0.2.10','host_key':key(1),'user':'root','port':2222}
            with managed_ssh.connection(peer,identity) as ssh:
                name=next(item.split('=',1)[1] for item in ssh if item.startswith('UserKnownHostsFile='))
                known=Path(name);self.assertEqual(known.read_text(),'[192.0.2.10]:2222 '+key(1)+'\n')
                self.assertIn('StrictHostKeyChecking=yes',ssh);self.assertIn('ForwardAgent=no',ssh)
                self.assertIn('/dev/null',ssh);self.assertEqual(known.stat().st_mode&0o777,0o600)
            self.assertFalse(known.exists())
