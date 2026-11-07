import json
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
import verify_webrtc_timing as evidence


class TimingEvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.manifest = {'patch_sha256': 'reviewed-source', 'webrtc_commit': 'pinned-revision',
                         'unit_test_count': 4, 'regressions': ['VCMTimingTest.Getter', 'RtpStreamsSynchronizerTest.Pause']}
        self.receipt = {**self.manifest, 'platform': 'test', 'source_files_verified': True,
                        'shallow_checkout': True}
        (self.directory / 'build-receipt.json').write_text(json.dumps(self.receipt))
        self.tests = ET.Element('testsuites', tests='4', failures='0', errors='0')
        suite = ET.SubElement(self.tests, 'testsuite')
        for full_name in [*self.manifest['regressions'], 'VCMTimingTest.Other', 'StreamSynchronizationTest.Other']:
            classname, name = full_name.split('.')
            ET.SubElement(suite, 'testcase', classname=classname, name=name, status='run')
        self.save_xml()
        (self.directory / 'before-fix.log').write_text('\n'.join(
            '[  FAILED  ] ' + name for name in self.manifest['regressions']))

    def save_xml(self):
        ET.ElementTree(self.tests).write(self.directory / 'timing-tests.xml')

    def test_exact_complete_evidence_passes(self):
        evidence.verify(self.directory, self.manifest)

    def test_changed_source_or_toolchain_cannot_reuse_evidence(self):
        with self.assertRaisesRegex(ValueError, 'pins'):
            evidence.verify(self.directory, {**self.manifest, 'webrtc_commit': 'different-source'})

    def test_skipped_test_rejected_even_with_success_counters(self):
        ET.SubElement(self.tests.find('.//testcase'), 'skipped')
        self.save_xml()
        with self.assertRaisesRegex(ValueError, 'run and passed'):
            evidence.verify(self.directory, self.manifest)

    def test_passing_new_tests_without_old_failure_proof_rejected(self):
        (self.directory / 'before-fix.log').write_text('[  PASSED  ] 3 tests')
        with self.assertRaisesRegex(ValueError, 'original timing/sync'):
            evidence.verify(self.directory, self.manifest)

    def test_duplicate_cases_cannot_replace_missing_tests(self):
        cases = self.tests.findall('.//testcase')
        cases[-1].attrib.update(cases[0].attrib)
        self.save_xml()
        with self.assertRaisesRegex(ValueError, 'run and passed'):
            evidence.verify(self.directory, self.manifest)

    def test_old_timing_only_suite_cannot_prove_stale_floor_regression(self):
        (self.directory / 'before-fix.log').write_text('[  FAILED  ] VCMTimingTest.Getter')
        with self.assertRaisesRegex(ValueError, 'original timing/sync'):
            evidence.verify(self.directory, self.manifest)
