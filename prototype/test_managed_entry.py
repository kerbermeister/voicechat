import json
from pathlib import Path
from types import SimpleNamespace
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'infra'))
import managed_entry
import managed_journal
import role_release
import test_managed_journal


class ManagedEntryTests(unittest.TestCase):
    def setUp(self):
        self.fixture=test_managed_journal.ManagedJournalTests();self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups);self.root=self.fixture.root
        self.sha='d'*64;self.source=self.root/'bundles'/self.sha
        self.source.mkdir(mode=0o700,parents=True)
        self.enterContext(patch.object(managed_entry.platform,'system',return_value='Linux'))
        self.enterContext(patch.object(managed_entry,'os',SimpleNamespace(geteuid=lambda:0)))
        host=self.fixture.baseline['inventory']['core']['ssh_host_key'].encode()
        self.host=self.enterContext(patch('network_bootstrap.existing',return_value=host))

    def operate(self,action,**kw):
        value=managed_entry.request(json.dumps({'schema':1,'action':action,**kw}).encode())
        return managed_entry.operate(value,self.root,self.sha,source=self.source)

    def begin(self):
        result=self.operate('begin',scope='full',edges=None,retry=False,
            baseline=role_release.json_digest(self.fixture.baseline))
        self.fixture.journal=managed_journal.read(self.root)
        self.fixture.attempt=result['attempt'];return result

    def test_status_and_preflight_do_not_start_release(self):
        status=self.operate('status');self.assertIsNone(status['attempt'])
        self.assertEqual(status['control'],self.fixture.baseline['core']['images']['control'])
        plan=self.operate('prepare',scope='web',edges=['c'],position=0,baseline=status['baseline'])
        self.assertEqual(plan['count'],2);self.assertEqual(plan['peer']['request']['operation'],'preflight')
        self.assertFalse((self.root/'rollout.json').exists())

    def test_entry_drives_real_journal_through_global_commit_and_release(self):
        result=self.begin()
        for _ in range(40):
            if result['phase']=='complete':break
            if result['phase']=='committing':
                result=self.operate('commit',attempt=result['attempt']);continue
            req=result['peer']['request'];step={key:req['target'][key] for key in ('role','edge_id')}
            manifest=req['before'] if result['phase']=='fencing' else req['target']
            proof=self.fixture.proof(step,manifest,released=result['phase']=='releasing')
            result=self.operate('ack',attempt=result['attempt'],phase=result['phase'],position=result['position'],proof=proof)
        self.assertEqual(result['phase'],'complete')
        self.assertEqual(managed_journal.current(self.root)[1]['core']['commit'],self.fixture.candidate['commit'])

    def test_new_source_redirects_status_but_cannot_mutate_old_active_journal(self):
        self.begin();before=(self.root/'rollout.json').read_bytes()
        self.sha='e'*64;self.source=self.root/'bundles'/self.sha;self.source.mkdir(mode=0o700)
        status=self.operate('status');self.assertEqual(status['active_source'],'d'*64)
        with self.assertRaisesRegex(ValueError,'original frozen source'):
            self.operate('next',attempt=self.fixture.attempt)
        self.assertEqual((self.root/'rollout.json').read_bytes(),before)

    def test_rollback_returns_restoring_instruction_and_cannot_undo_global_commit(self):
        self.begin();self.fixture.through('applying')
        result=self.operate('rollback',attempt=self.fixture.attempt)
        self.assertEqual(result['peer']['request']['operation'],'rollback')
        self.assertEqual(result['phase'],'rolling-back')
        self.fixture.journal=managed_journal.read(self.root);self.fixture.through('rolled-back')
        self.fixture.begin(retry=True);self.fixture.through('committing')
        with self.assertRaisesRegex(ValueError,'forward-only'):
            self.operate('rollback',attempt=self.fixture.attempt)

    def test_wrong_host_or_proof_does_not_advance_release(self):
        self.host.return_value=b'ssh-ed25519 invalid'
        with self.assertRaises(ValueError):self.operate('status')
        self.assertFalse((self.root/'rollout.json').exists())
        self.host.return_value=self.fixture.baseline['inventory']['core']['ssh_host_key'].encode()
        result=self.begin();before=(self.root/'rollout.json').read_bytes()
        with self.assertRaises(ValueError):
            self.operate('ack',attempt=result['attempt'],phase=result['phase'],position=0,proof={'facts':{},'fence':None})
        self.assertEqual((self.root/'rollout.json').read_bytes(),before)

    def test_request_rejects_unknown_actions_duplicate_fields_and_ambiguous_edges(self):
        for value in ({'schema':True,'action':'status'},{'schema':1,'action':[]},
                      {'schema':1,'action':'begin','scope':'web','edges':'c','baseline':'f'*64,'retry':False},
                      {'schema':1,'action':'next','attempt':None}):
            with self.subTest(value=value),self.assertRaises(ValueError):managed_entry.request(json.dumps(value).encode())
        with self.assertRaises(ValueError):managed_entry.request(b'{"schema":1,"schema":1,"action":"status"}')
        with self.assertRaises(ValueError):managed_entry.request(b' '*65537)
