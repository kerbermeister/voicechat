from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'infra'))
import managed_finish
import managed_journal
import test_managed_journal


class ManagedFinishTests(unittest.TestCase):
    def setUp(self):
        self.fixture=test_managed_journal.ManagedJournalTests();self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups);self.root=self.fixture.root
        self.ready=self.enterContext(patch('role_bootstrap.ready'))
        self.inspect=self.enterContext(patch('managed_release.inspect_role'))
        self.backup=self.enterContext(patch('core_backup_bootstrap.install'))
        self.manager=self.enterContext(patch('shared_update.install'))
        self.tls=self.enterContext(patch('cohost_tls_bootstrap.install'))

    def test_finish_keeps_backup_delegate_and_does_not_touch_dedicated_edge_sources(self):
        self.fixture.begin();self.fixture.through('committing')
        managed_journal.commit(self.root,self.fixture.attempt);self.fixture.through('complete')
        result=managed_finish.finish(self.root,self.fixture.attempt)
        self.assertTrue(result['maintenance_ready'])
        self.assertEqual(result['core_commit'],self.fixture.candidate['commit'])
        self.backup.assert_called_once();self.manager.assert_not_called();self.tls.assert_not_called()
        self.assertEqual(self.ready.call_args.args,(self.root/'core','core'))

    def test_pending_release_never_changes_schedulers(self):
        self.fixture.begin()
        with self.assertRaisesRegex(ValueError,'Release all role fences'):
            managed_finish.finish(self.root,self.fixture.attempt)
        self.ready.assert_not_called();self.backup.assert_not_called()

    def test_failed_operator_verification_cannot_rewrite_timer(self):
        self.fixture.begin();self.fixture.through('committing')
        managed_journal.commit(self.root,self.fixture.attempt);self.fixture.through('complete')
        self.ready.side_effect=ValueError('Unowned boot source')
        with self.assertRaisesRegex(ValueError,'Unowned boot source'):
            managed_finish.finish(self.root,self.fixture.attempt)
        self.backup.assert_not_called();self.manager.assert_not_called()

    def test_cohost_delegates_update_only_for_participating_shared_edge(self):
        self.fixture.begin();self.fixture.through('committing')
        managed_journal.commit(self.root,self.fixture.attempt);self.fixture.through('complete')
        loaded=managed_journal._load(self.root,self.fixture.attempt)
        with patch.object(managed_journal,'_load',return_value=loaded), \
             patch('node_inventory.shared_tls_profile',side_effect=lambda inventory,identifier:{} if identifier=='c' else None):
            managed_finish.finish(self.root,self.fixture.attempt)
        self.manager.assert_called_once_with(self.fixture.base/'shared')
        self.tls.assert_called_once_with(self.fixture.base/'shared')
        self.assertEqual(self.ready.call_count,2)
