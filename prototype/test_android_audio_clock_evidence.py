"""Require both real SDK/API variants of every output-clock regression."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
import build_webrtc_sdk as builder


class AndroidAudioClockEvidenceTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.report = Path(temporary.name) / 'results.json'
        names = [f'org.webrtc.audio.WebRtcAudioTrackDelayTest#{name}[{api}]'
                 for name in builder.MANIFEST['android_audio_clock_tests'] for api in (29, 36)]
        self.evidence = {'all_tests': names, 'disabled_tests': [], 'per_iteration_data': [
            {name: [{'status': 'SUCCESS'}] for name in names}]}

    def verify(self, evidence):
        self.report.write_text(json.dumps(evidence))
        builder.verify_android_audio_clock_tests(self.report)

    def test_complete_api_29_and_36_reports_pass(self):
        self.verify(self.evidence)

    def test_missing_variant_or_failure_or_skip_cannot_pass(self):
        name = self.evidence['all_tests'][0]
        for status in ('FAILURE', 'SKIPPED'):
            with self.subTest(status=status):
                evidence = copy.deepcopy(self.evidence)
                evidence['per_iteration_data'][0][name][0]['status'] = status
                with self.assertRaisesRegex(RuntimeError, 'regression'):
                    self.verify(evidence)
        evidence = copy.deepcopy(self.evidence)
        del evidence['per_iteration_data'][0][name]
        evidence['all_tests'].remove(name)
        with self.assertRaisesRegex(RuntimeError, 'coverage'):
            self.verify(evidence)

    def test_disabled_or_repeated_tests_cannot_pass(self):
        evidence = copy.deepcopy(self.evidence)
        evidence['disabled_tests'] = ['missing']
        with self.assertRaisesRegex(RuntimeError, 'skipped or repeated'):
            self.verify(evidence)
        evidence = copy.deepcopy(self.evidence)
        evidence['per_iteration_data'].append(evidence['per_iteration_data'][0])
        with self.assertRaisesRegex(RuntimeError, 'skipped or repeated'):
            self.verify(evidence)


if __name__ == '__main__':
    unittest.main()
