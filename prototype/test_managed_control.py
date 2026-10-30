import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'infra'))
import managed_control
import managed_journal
import role_release
import test_managed_journal


class ManagedControlTests(unittest.TestCase):
    def setUp(self):
        self.fixture=test_managed_journal.ManagedJournalTests();self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups);self.root=self.fixture.root

    def test_preflight_is_bounded_cas_and_does_not_begin_journal(self):
        before=(self.root/'current.json').read_bytes()
        first=managed_control.prepare(self.root,'d'*64,scope='web',edges=['c'])
        self.assertEqual(first['count'],2)
        self.assertEqual(first['peer']['request']['operation'],'preflight')
        second=managed_control.prepare(self.root,'d'*64,scope='web',edges=['c'],position=1,expected_baseline=first['baseline'])
        self.assertEqual(second['peer']['request']['before']['edge_id'],'c')
        self.assertLess(len(json.dumps(second).encode()),65536)
        self.assertEqual((self.root/'current.json').read_bytes(),before)
        self.assertFalse((self.root/'rollout.json').exists())
        with self.assertRaisesRegex(ValueError,'baseline changed'):
            managed_control.prepare(self.root,'d'*64,expected_baseline='0'*64)

    def test_forward_instructions_use_exact_role_and_core_target(self):
        self.fixture.begin()
        first=managed_control.next_operation(self.root)
        self.assertEqual(first['phase'],'fencing');self.assertEqual(first['peer']['request']['operation'],'claim')
        self.fixture.through('applying')
        core=managed_control.next_operation(self.root)
        self.assertEqual(core['peer']['request']['operation'],'apply')
        self.assertIsNone(core['peer']['request']['scope'])
        self.fixture.acknowledge()
        edge=managed_control.next_operation(self.root)
        self.assertEqual(edge['peer']['request']['scope'],'edge')
        self.assertEqual(edge['peer']['request']['core'],core['peer']['request']['target'])
        self.fixture.through('committing')
        self.assertIsNone(managed_control.next_operation(self.root)['peer'])
        managed_journal.commit(self.root,self.fixture.attempt)
        self.assertEqual(managed_control.next_operation(self.root)['peer']['request']['operation'],'release')
        self.fixture.through('complete')
        self.assertIsNone(managed_control.next_operation(self.root)['peer'])

    def test_rollback_verification_retargets_even_untouched_roles(self):
        self.fixture.begin();self.fixture.through('applying')
        managed_journal.start_rollback(self.root,self.fixture.attempt)
        rollback=managed_control.next_operation(self.root)
        self.assertEqual(rollback['phase'],'rolling-back')
        self.assertEqual(rollback['peer']['request']['operation'],'rollback')
        self.fixture.journal=managed_journal.read(self.root)
        self.fixture.through('rollback-verifying')
        self.fixture.acknowledge()
        edge=managed_control.next_operation(self.root)
        self.assertEqual(edge['phase'],'rollback-verifying')
        self.assertEqual(edge['peer']['request']['operation'],'rollback')
        self.assertIsNone(edge['peer']['request']['manifest'])

    def test_preparing_another_release_during_active_attempt_is_rejected(self):
        self.fixture.begin()
        with self.assertRaisesRegex(ValueError,'Resume the existing release'):
            managed_control.prepare(self.root,'e'*64)

    def test_wrong_position_does_not_create_operation(self):
        for position in (-1,True,999):
            with self.subTest(position=position),self.assertRaises(ValueError):
                managed_control.prepare(self.root,'d'*64,position=position)
        self.assertFalse((self.root/'rollout.json').exists())
