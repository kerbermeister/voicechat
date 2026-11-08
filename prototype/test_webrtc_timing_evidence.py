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
        self.manifest.update(video_recovery_test_count=2,
                             video_recovery_regressions=['VideoRecoveryTest.FreshKeyframe'])
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

        self.video_tests = ET.Element('testsuites', tests='2', failures='0', errors='0')
        video_suite = ET.SubElement(self.video_tests, 'testsuite')
        for name in ('FreshKeyframe', 'Other'):
            ET.SubElement(video_suite, 'testcase', classname='VideoRecoveryTest',
                          name=name, status='run')
        ET.ElementTree(self.video_tests).write(self.directory / 'video-resume-tests.xml')
        (self.directory / 'video-resume-before.log').write_text(
            '[  FAILED  ] VideoRecoveryTest.FreshKeyframe')

    def save_xml(self):
        ET.ElementTree(self.tests).write(self.directory / 'timing-tests.xml')

    def test_exact_complete_evidence_passes(self):
        evidence.verify(self.directory, self.manifest)

    def test_presentation_refresh_requires_former_receive_guard_failure(self):
        self.manifest['receive_presentation_regressions'] = ['VCMTimingTest.Getter']
        with self.assertRaisesRegex(ValueError, 'Former receive guard'):
            evidence.verify_tests(self.directory, self.manifest)
        control = self.directory / 'before-receive-presentation.log'
        control.write_text('[  PASSED  ] VCMTimingTest.Getter')
        with self.assertRaisesRegex(ValueError, 'Former receive guard'):
            evidence.verify_tests(self.directory, self.manifest)
        control.write_text('[  FAILED  ] VCMTimingTest.Getter')
        evidence.verify_tests(self.directory, self.manifest)

    def test_audio_queue_bound_requires_old_policy_failure(self):
        self.manifest['audio_queue_sync_regressions'] = ['VCMTimingTest.Getter']
        with self.assertRaisesRegex(ValueError, 'audio queue render-bound'):
            evidence.verify_tests(self.directory, self.manifest)
        control = self.directory / 'before-audio-queue-sync.log'
        control.write_text('[  PASSED  ] VCMTimingTest.Getter')
        with self.assertRaisesRegex(ValueError, 'audio queue render-bound'):
            evidence.verify_tests(self.directory, self.manifest)
        control.write_text('[  FAILED  ] VCMTimingTest.Getter')
        evidence.verify_tests(self.directory, self.manifest)

    def test_audio_queue_control_must_match_an_executed_test(self):
        self.manifest['audio_queue_sync_regressions'] = ['VCMTimingTest.NotExecuted']
        (self.directory / 'before-audio-queue-sync.log').write_text(
            '[  FAILED  ] VCMTimingTest.NotExecuted')
        with self.assertRaisesRegex(ValueError, 'audio queue render-bound'):
            evidence.verify_tests(self.directory, self.manifest)

    def test_texture_copy_requires_actual_old_ownership_failure(self):
        case = 'IncomingVideoStreamTest.CopiesDelayedTextureWithoutPixelOrMetadataLoss'
        self.manifest['video_recovery_regressions'].append(case)
        self.receipt['video_recovery_regressions'] = self.manifest['video_recovery_regressions']
        (self.directory / 'build-receipt.json').write_text(json.dumps(self.receipt))
        testcase = self.video_tests.findall('.//testcase')[-1]
        classname, name = case.split('.')
        testcase.attrib.update(classname=classname, name=name)
        ET.ElementTree(self.video_tests).write(self.directory / 'video-resume-tests.xml')
        with self.assertRaisesRegex(ValueError, 'video recovery'):
            evidence.verify(self.directory, self.manifest)
        control = self.directory / 'video-resume-before.log'
        control.write_text(control.read_text() + '\n[  FAILED  ] ' + case)
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

    def test_previous_macos_timing_manifest_remains_supported(self):
        for field in ('video_recovery_test_count', 'video_recovery_regressions'):
            del self.manifest[field]
            del self.receipt[field]
        (self.directory / 'build-receipt.json').write_text(json.dumps(self.receipt))
        (self.directory / 'video-resume-tests.xml').unlink()
        evidence.verify(self.directory, self.manifest)

    def test_missing_video_evidence_is_rejected(self):
        (self.directory / 'video-resume-tests.xml').unlink()
        with self.assertRaises(FileNotFoundError):
            evidence.verify(self.directory, self.manifest)

    def test_duplicate_video_cases_cannot_replace_missing_tests(self):
        cases = self.video_tests.findall('.//testcase')
        cases[-1].attrib.update(cases[0].attrib)
        ET.ElementTree(self.video_tests).write(self.directory / 'video-resume-tests.xml')
        with self.assertRaisesRegex(ValueError, 'video recovery'):
            evidence.verify(self.directory, self.manifest)

    def test_skipped_video_test_rejected_with_success_counters(self):
        ET.SubElement(self.video_tests.find('.//testcase'), 'skipped')
        ET.ElementTree(self.video_tests).write(self.directory / 'video-resume-tests.xml')
        with self.assertRaisesRegex(ValueError, 'video recovery'):
            evidence.verify(self.directory, self.manifest)

    def test_video_requires_original_failure_proof(self):
        (self.directory / 'video-resume-before.log').write_text('[  PASSED  ] 2 tests')
        with self.assertRaisesRegex(ValueError, 'video recovery'):
            evidence.verify(self.directory, self.manifest)
