from copy import deepcopy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import managed_journal
import managed_release
import managed_state
import role_release
REAL_DELIVERY = managed_journal._delivery
import test_managed_release as baseline_tests


class ManagedJournalTests(unittest.TestCase):
    def setUp(self):
        baseline_tests.ManagedReleaseTests.setUp(self)
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / 'managed'; self.root.mkdir(mode=0o700)
        self.identity = {'postgres_system_identifier': '123456789', 'signing_sha256': 'f' * 64}
        self.before = {'schema': 1, 'kind': 'managed',
                       'baseline': managed_release.store_baseline(self.root, self.baseline),
                       'data_identity': self.identity, 'legacy_root': str(self.base / 'legacy'),
                       'shared_root': str(self.base / 'shared')}
        managed_state.persist(self.root / 'current.json', self.before)
        self.receipt = {'manifest': self.candidate, 'backend': self.baseline['backend']}
        mock = patch.object(managed_journal, '_delivery', return_value=self.receipt)
        mock.start(); self.addCleanup(mock.stop)

    def begin(self, **kwargs):
        self.journal = managed_journal.begin(self.root, 'd' * 64, role_release.json_digest(self.baseline), **kwargs)
        self.attempt = self.journal['attempt']
        return self.journal

    def proof(self, step, manifest, *, restored=False, released=False):
        count = 3 if step['role'] == 'core' else len(set(manifest['images']) - {'configure'})
        facts = {'schema': 1, **step, 'manifest': manifest,
                 'processes': [format(n+1, '064x') + ' true 2026-10-29T00:00:00Z 0' for n in range(count)]}
        if step['role'] == 'core':
            facts.update(data_identity=self.identity, runtime_sha256='e' * 64)
        target = self.baseline if restored else managed_release.load_baseline(self.root, self.journal['target'])
        fenced = target['core'] if step['role'] == 'core' else target['edges'][step['edge_id']]
        return {'facts': facts, 'fence': None if released else
                {'attempt': self.attempt, 'target': role_release.json_digest(fenced)}}

    def acknowledge(self):
        journal = managed_journal.read(self.root, self.attempt)
        phase, position = journal['phase'], journal['position']
        if phase in ('fencing', 'verifying', 'releasing'):
            sequence = journal['participants']
        elif phase == 'applying':
            sequence = journal['steps']
        elif phase == 'rolling-back':
            before = journal['rollback_from']
            count = before['position']+1 if before['phase'] == 'applying' else len(journal['steps'])
            sequence = list(reversed(journal['steps'][:count]))
        else:
            count = journal['rollback_from']['position']+1 if journal['rollback_from']['phase']=='fencing' else len(journal['participants'])
            sequence = journal['participants'][:count]
        step = sequence[position]
        restored = phase.startswith('rollback') or phase == 'rolling-back'
        baseline = self.baseline if phase == 'fencing' or restored else managed_release.load_baseline(self.root, journal['target'])
        manifest = baseline['core'] if step['role'] == 'core' else baseline['edges'][step['edge_id']]
        proof = self.proof(step, manifest, restored=restored, released=phase in ('releasing','rollback-releasing'))
        self.journal = managed_journal.acknowledge(self.root, self.attempt, phase, position, proof)
        return phase, position, proof

    def through(self, phase):
        for _ in range(100):
            if self.journal['phase'] == phase: return
            self.acknowledge()
        self.fail('Journal failed to reach '+phase)

    def test_maximum_edge_count_fits_each_managed_document_and_first_proof(self):
        self.baseline = baseline_tests.baseline_32(self.baseline)
        self.before['baseline'] = managed_release.store_baseline(self.root,self.baseline)
        managed_state.persist(self.root/'current.json',self.before)
        journal = self.begin()
        self.assertEqual(len(journal['participants']),33)
        self.assertEqual(len(journal['steps']),33)
        self.assertGreater(len(json.dumps(self.baseline).encode()),65536)
        self.acknowledge()
        for path in self.root.rglob('*.json'):
            self.assertLessEqual(path.stat().st_size,65536)
        self.assertEqual(managed_state.read(self.root/'current.json'),self.before)

    def test_completed_history_is_not_re_rendered_by_the_next_release(self):
        self.begin();self.through('committing');self.journal=managed_journal.commit(self.root,self.attempt)
        self.through('complete')
        with patch.object(managed_release,'plan',side_effect=AssertionError('New renderer used on historical intent')):
            self.assertEqual(managed_journal.read(self.root),self.journal)
            self.assertEqual(managed_journal.begin(self.root,'d'*64,role_release.json_digest(self.baseline)),self.journal)

    def test_completed_initial_pointer_is_read_without_rewriting_it(self):
        public = deepcopy(self.baseline['public']);public['edges']=[{'id':'a','origin':public['canonical_origin'],'turn_host':'turn.example.com'}]
        inventory = deepcopy(self.baseline['inventory']);inventory['edges']=[{'id':'a','host':'core'}]
        target = {'public':public,'inventory':inventory,'subnet':'10.241.0.0/28','backend_sha256':'f'*64,
                  'root':str(self.root),'legacy_root':self.before['legacy_root'],'shared_root':self.before['shared_root'],
                  'core':role_release.make(public,inventory,'core','a'*40,self.image('1')),
                  'edge':role_release.make(public,inventory,'edge','a'*40,self.image('2'),'a')}
        pointer = {'schema':1,'kind':'roles','target':target,'core_root':str(self.root/'core'),
                   'edge_root':str(self.root/'edges/a'),'legacy_root':self.before['legacy_root'],'data_identity':self.identity}
        managed_state.persist(self.root/'current.json',pointer)
        managed_state.persist(self.root/'initial.json',{'phase':'complete','target':target})
        original = (self.root/'current.json').read_bytes()
        actual,baseline,_ = managed_journal.current(self.root)
        self.assertEqual(actual,pointer);self.assertEqual(set(baseline['edges']),{'a'})
        self.assertEqual((self.root/'current.json').read_bytes(),original)
        managed_state.persist(self.root/'initial.json',{'phase':'activate','target':target})
        with self.assertRaisesRegex(ValueError,'Finish initial adoption'):managed_journal.current(self.root)

    def test_real_source_guard_rejects_path_escape_and_symlinked_delivery(self):
        for invalid in ('../other','A'*64,None):
            with self.assertRaisesRegex(ValueError,'Immutable source delivery'):
                REAL_DELIVERY(self.root,invalid)
        directory=self.root/'bundles';directory.mkdir(mode=0o700)
        other=self.base/'other';other.mkdir(mode=0o700)
        (directory/('d'*64)).symlink_to(other)
        with self.assertRaisesRegex(ValueError,'cannot traverse symlinks'):
            REAL_DELIVERY(self.root,'d'*64)

    def test_foreign_pointer_change_cannot_be_overwritten_by_acknowledgement(self):
        self.begin();step=self.journal['participants'][0];proof=self.proof(step,self.baseline['core'])
        managed_state.persist(self.root/'current.json',{**self.before,'shared_root':str(self.base/'other')})
        with self.assertRaisesRegex(ValueError,'pointer changed outside'):
            managed_journal.acknowledge(self.root,self.attempt,'fencing',0,proof)
        self.assertFalse((self.root/('attempt-'+self.attempt)/'fencing-0.json').exists())

    def test_tampered_proof_cannot_commit_even_after_all_steps_were_recorded(self):
        self.begin();self.through('committing')
        path=self.root/('attempt-'+self.attempt)/'fencing-0.json';proof=managed_state.read(path)
        proof['facts']['data_identity']={**self.identity,'signing_sha256':'0'*64}
        managed_state.persist(path,proof)
        with self.assertRaisesRegex(ValueError,'Core data or runtime proof changed'):
            managed_journal.commit(self.root,self.attempt)
        self.assertEqual(managed_state.read(self.root/'current.json'),self.before)
        self.assertFalse((self.root/'previous.json').exists())

    def test_stale_preflight_baseline_cannot_start_a_release(self):
        with self.assertRaisesRegex(ValueError,'baseline changed since release preparation'):
            managed_journal.begin(self.root,'d'*64,'0'*64)
        self.assertFalse((self.root/'rollout.json').exists())
        self.assertEqual(managed_state.read(self.root/'current.json'),self.before)

    def test_full_release_commits_only_after_ordered_role_proofs(self):
        journal = self.begin()
        self.assertEqual(journal['steps'], [{'role':'core','edge_id':None},
                                           {'role':'edge','edge_id':'b'}, {'role':'edge','edge_id':'c'}])
        with self.assertRaisesRegex(ValueError, 'Verify all'):
            managed_journal.commit(self.root, self.attempt)
        self.through('committing')
        self.assertEqual(managed_state.read(self.root/'current.json'), self.before)
        self.journal = managed_journal.commit(self.root, self.attempt)
        after = managed_state.read(self.root/'current.json')
        self.assertEqual(after['data_identity'], self.identity)
        self.assertEqual(managed_state.read(self.root/'previous.json'), self.before)
        target = managed_release.load_baseline(self.root, after['baseline'])
        self.assertEqual(target['core']['commit'], self.candidate['commit'])
        self.through('complete')
        self.assertEqual(managed_journal.begin(self.root, 'd'*64, role_release.json_digest(self.baseline)), self.journal)

    def test_lost_ack_reply_is_idempotent_and_other_attempt_cannot_advance(self):
        self.begin(); phase, position, proof = self.acknowledge()
        expected = deepcopy(self.journal)
        self.assertEqual(managed_journal.acknowledge(self.root,self.attempt,phase,position,proof),expected)
        with self.assertRaisesRegex(ValueError, 'Another managed release'):
            managed_journal.acknowledge(self.root,'0'*64,phase,position,proof)
        changed = deepcopy(proof); changed['facts']['processes'][0] = '9'*64+' true now 0'
        with self.assertRaisesRegex(ValueError, 'proof changed'):
            managed_journal.acknowledge(self.root,self.attempt,phase,position,changed)
        self.assertEqual(managed_journal.read(self.root),expected)
        with self.assertRaisesRegex(ValueError, 'same pending'):
            managed_journal.begin(self.root,'a'*64,role_release.json_digest(self.baseline))

    def test_crash_between_proof_and_phase_write_resumes_once(self):
        self.begin(); step=self.journal['participants'][0]
        proof=self.proof(step,self.baseline['core'])
        persist=managed_state.persist
        def crash(path,value):
            if path == self.root/'rollout.json':raise InterruptedError('lost journal write')
            return persist(path,value)
        with patch.object(managed_state,'persist',side_effect=crash):
            with self.assertRaises(InterruptedError):
                managed_journal.acknowledge(self.root,self.attempt,'fencing',0,proof)
        self.assertEqual(managed_journal.read(self.root)['position'],0)
        self.journal=managed_journal.acknowledge(self.root,self.attempt,'fencing',0,proof)
        self.assertEqual(self.journal['position'],1)

    def test_commit_crash_after_current_pointer_is_forward_recoverable(self):
        self.begin();self.through('committing');persist=managed_state.persist
        def crash(path,value):
            if path == self.root/'rollout.json':raise InterruptedError('lost commit reply')
            return persist(path,value)
        with patch.object(managed_state,'persist',side_effect=crash):
            with self.assertRaises(InterruptedError):managed_journal.commit(self.root,self.attempt)
        self.assertEqual(managed_state.read(self.root/'current.json')['baseline'],self.journal['target'])
        self.assertEqual(managed_journal.read(self.root)['phase'],'committing')
        with self.assertRaisesRegex(ValueError,'forward-only'):
            managed_journal.start_rollback(self.root,self.attempt)
        self.journal=managed_journal.commit(self.root,self.attempt);self.through('complete')

    def test_web_selection_preserves_core_and_unselected_edge(self):
        self.begin(scope='web',edges=['c'])
        self.assertEqual(self.journal['participants'],[{'role':'core','edge_id':None},{'role':'edge','edge_id':'c'}])
        self.through('verifying')
        proof=self.proof(self.journal['participants'][0],self.baseline['core'])
        proof['facts']['processes'][0]='9'*64+' true changed 1'
        with self.assertRaisesRegex(ValueError,'changed core processes'):
            managed_journal.acknowledge(self.root,self.attempt,'verifying',0,proof)
        self.through('committing');self.journal=managed_journal.commit(self.root,self.attempt);self.through('complete')
        _,target,_=managed_journal.current(self.root)
        self.assertEqual(target['core'],self.baseline['core'])
        self.assertEqual(target['edges']['b'],self.baseline['edges']['b'])
        self.assertEqual(target['edges']['c']['commit'],self.candidate['commit'])

    def test_bad_identity_missing_fence_and_out_of_order_cannot_commit(self):
        self.begin();step=self.journal['participants'][0];proof=self.proof(step,self.baseline['core'])
        for changed in ({**proof,'fence':None},
                        {**proof,'facts':{**proof['facts'],'data_identity':{**self.identity,'signing_sha256':'0'*64}}},
                        {**proof,'facts':{**proof['facts'],'processes':[]}}):
            with self.assertRaises(ValueError):managed_journal.acknowledge(self.root,self.attempt,'fencing',0,changed)
        with self.assertRaisesRegex(ValueError,'Out-of-order'):
            managed_journal.acknowledge(self.root,self.attempt,'verifying',0,proof)
        self.assertEqual(managed_state.read(self.root/'current.json'),self.before)

    def test_failed_edge_rolls_back_in_reverse_without_replacing_data_or_pointer(self):
        self.begin();self.through('applying');self.acknowledge() # core completed; edge b may have applied before losing its reply
        self.journal=managed_journal.start_rollback(self.root,self.attempt)
        self.assertEqual(self.journal['rollback_from'],{'phase':'applying','position':1})
        phase,_,proof=self.acknowledge();self.assertEqual(phase,'rolling-back')
        self.assertEqual(proof['facts']['edge_id'],'b')
        self.through('rolled-back')
        self.assertEqual(managed_state.read(self.root/'current.json'),self.before)
        self.assertFalse((self.root/'previous.json').exists())
        with self.assertRaisesRegex(ValueError,'Explicit retry'):
            managed_journal.begin(self.root,'d'*64,role_release.json_digest(self.baseline))
        original=(self.root/'rollout.json').read_bytes()
        self.journal=managed_journal.begin(self.root,'d'*64,role_release.json_digest(self.baseline),retry=True)
        self.assertNotEqual(self.journal['attempt'],self.attempt)
        archived=self.root/('attempt-'+self.attempt)/'managed-rollout.json'
        self.assertEqual(managed_state.read(archived)['phase'],'rolled-back')
        self.assertEqual(archived.read_bytes(),original)

    def test_rollback_during_first_fence_does_not_require_unstarted_role_operations(self):
        self.begin();self.journal=managed_journal.start_rollback(self.root,self.attempt)
        self.assertEqual(self.journal['phase'],'rollback-verifying')
        self.through('rolled-back')
        self.assertEqual(managed_state.read(self.root/'current.json'),self.before)

    def test_symlinked_or_public_attempt_directory_is_refused(self):
        self.begin();directory=self.root/('attempt-'+self.attempt)
        directory.chmod(0o755)
        with self.assertRaisesRegex(ValueError,'owner-only'):managed_journal.read(self.root)
        directory.chmod(0o700)
        moved=self.root/'moved';directory.rename(moved);directory.symlink_to(moved)
        with self.assertRaisesRegex(ValueError,'private attempt directory'):managed_journal.read(self.root)

    def test_changed_baseline_snapshot_or_target_proof_is_refused(self):
        self.begin();directory=self.root/('attempt-'+self.attempt)
        managed_state.persist(directory/'before.json',{**self.before,'shared_root':str(self.base/'other')})
        with self.assertRaisesRegex(ValueError,'Original production pointer changed'):
            managed_journal.read(self.root)
