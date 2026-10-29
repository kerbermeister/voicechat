from copy import deepcopy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'infra'))
import managed_probe
import managed_release
import managed_state
import role_release
import test_managed_journal
import test_managed_release


class ManagedProbeTests(unittest.TestCase):
    def setUp(self):
        self.fixture=test_managed_journal.ManagedJournalTests();self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups);self.root=self.fixture.root

    def test_typed_hints_preserve_baseline_digest_and_never_read_runtime(self):
        before={p:p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        value=managed_probe.hints(self.root)
        self.assertEqual(value['baseline'],role_release.json_digest(self.fixture.baseline))
        self.assertEqual(value['control'],self.fixture.baseline['core']['images']['control'])
        self.assertIsNone(value['pending'])
        self.assertEqual({p:p.read_bytes() for p in self.root.rglob('*') if p.is_file()},before)

    def test_initial_pointer_is_read_only_after_completed_adoption(self):
        baseline=self.fixture.baseline;identifier=next(iter(baseline['edges']))
        target={'root':str(self.root),'backend_sha256':baseline['backend'],'public':baseline['public'],
                'inventory':baseline['inventory'],'subnet':baseline['subnet'],'core':baseline['core'],'edge':baseline['edges'][identifier]}
        managed_state.persist(self.root/'current.json',{'schema':1,'kind':'roles','target':target})
        managed_state.persist(self.root/'initial.json',{'phase':'complete','target':target})
        self.assertEqual(managed_probe.hints(self.root)['web'],{identifier:baseline['edges'][identifier]['images']['web']})
        managed_state.persist(self.root/'initial.json',{'phase':'edge','target':target})
        with self.assertRaisesRegex(ValueError,'Complete initial'):managed_probe.hints(self.root)

    def test_active_attempt_is_reported_for_frozen_resume_without_health_claim(self):
        self.fixture.begin();value=managed_probe.hints(self.root)
        self.assertEqual(value['pending'],{'attempt':self.fixture.attempt,'phase':'fencing','source':'d'*64})
        self.assertNotIn('healthy',value)

    def test_maximum_edge_baseline_is_still_a_bounded_response(self):
        baseline=test_managed_release.baseline_32(self.fixture.baseline)
        pointer=deepcopy(self.fixture.before);pointer['baseline']=managed_release.store_baseline(self.root,baseline)
        managed_state.persist(self.root/'current.json',pointer)
        value=managed_probe.hints(self.root)
        self.assertEqual(len(value['web']),32);self.assertLess(len(json.dumps(value).encode()),65536)
        self.assertEqual(value['baseline'],role_release.json_digest(baseline))

    def test_tampered_object_symlink_or_legacy_pointer_cannot_supply_build_digests(self):
        pointer=managed_state.read(self.root/'current.json');index=managed_state.read(self.root/'baselines'/(pointer['baseline']+'.json'))
        path=self.root/'baselines'/(index['core']+'.json');original=path.read_bytes()
        path.write_text('{}')
        with self.assertRaisesRegex(ValueError,'object changed'):managed_probe.hints(self.root)
        path.unlink();outside=self.fixture.base/'outside';outside.write_bytes(original);outside.chmod(0o600);path.symlink_to(outside)
        with self.assertRaises(OSError):managed_probe.hints(self.root)
        managed_state.persist(self.root/'current.json',{'schema':1,'manifest':{}})
        with self.assertRaisesRegex(ValueError,'Finish migration'):managed_probe.hints(self.root)

    def test_pointer_change_is_rejected_instead_of_mixing_two_releases(self):
        actual=managed_probe.read;count=0
        def changed(path):
            nonlocal count
            value=actual(path)
            if path==self.root/'current.json':
                count+=1
                if count==2:return b'changed',value[1]
            return value
        with patch.object(managed_probe,'read',side_effect=changed):
            with self.assertRaisesRegex(ValueError,'pointer changed'):managed_probe.hints(self.root)
