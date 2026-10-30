from copy import deepcopy
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import entry_journal
import test_entry_lifecycle


class EntryJournalTests(unittest.TestCase):
    def setUp(self):
        fixture = test_entry_lifecycle.EntryLifecycleTests(); fixture.setUp()
        self.request = {'baseline': fixture.baseline, 'public': fixture.public,
            'inventory': fixture.after, 'commit': '2' * 40, 'web_image': fixture.image, 'source': 'd' * 64}
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve() / 'journal'

    def receipt(self, value, position=None):
        position = value['position'] if position is None else position
        return {'schema': 1, 'attempt': value['attempt'], 'position': position,
                'step': value['steps'][position], 'result_sha256': 'e' * 64}

    def test_lost_begin_and_ack_replies_preserve_attempt_and_exact_receipt(self):
        value = entry_journal.begin(self.directory, self.request)
        self.assertEqual(entry_journal.begin(self.directory, self.request), value)
        proof = self.receipt(value)
        advanced = entry_journal.acknowledge(self.directory, proof)
        self.assertEqual(advanced['position'], 1)
        self.assertEqual(entry_journal.acknowledge(self.directory, proof), advanced)
        self.assertEqual(entry_journal.begin(self.directory, self.request), advanced)
        conflict = {**proof, 'result_sha256': 'f' * 64}
        with self.assertRaisesRegex(ValueError, 'Conflicting'):
            entry_journal.acknowledge(self.directory, conflict)

    def test_wrong_owner_skipped_steps_and_changed_request_fail_without_progress(self):
        value = entry_journal.begin(self.directory, self.request)
        for proof in (self.receipt(value, 1), {**self.receipt(value), 'attempt': 'f' * 64},
                      {**self.receipt(value), 'position': True}):
            with self.assertRaises(ValueError): entry_journal.acknowledge(self.directory, proof)
        changed = deepcopy(self.request); changed['source'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'Resume'):
            entry_journal.begin(self.directory, changed)
        self.assertEqual(entry_journal.load(self.directory), value)

    def test_changed_frozen_request_is_not_a_resume(self):
        import managed_state
        value = entry_journal.begin(self.directory, self.request)
        value['request']['source'] = 'f' * 64
        managed_state.persist(self.directory / 'current.json', value)
        with self.assertRaisesRegex(ValueError, 'intent changed'):
            entry_journal.load(self.directory)

    def test_normal_release_is_excluded_until_all_steps_acknowledged(self):
        value = entry_journal.begin(self.directory, self.request)
        with self.assertRaisesRegex(ValueError, 'active entry lifecycle'):
            entry_journal.require_idle(self.directory)
        while value['position'] < len(value['steps']):
            value = entry_journal.acknowledge(self.directory, self.receipt(value))
        # A later code release must not reinterpret historical completed steps.
        with patch.object(entry_journal.entry_lifecycle, 'plan', side_effect=AssertionError('historical renderer')):
            entry_journal.require_idle(self.directory)

    def test_every_step_required_and_completed_journal_archived_for_next_request(self):
        value = entry_journal.begin(self.directory, self.request)
        while value['position'] < len(value['steps']):
            value = entry_journal.acknowledge(self.directory, self.receipt(value))
        changed = deepcopy(self.request); changed['source'] = 'f' * 64
        next_value = entry_journal.begin(self.directory, changed)
        self.assertNotEqual(next_value['attempt'], value['attempt'])
        self.assertTrue((self.directory / (value['attempt'] + '.json')).is_file())
        self.assertEqual(next_value['position'], 0)


if __name__ == '__main__': unittest.main()
