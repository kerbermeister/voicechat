import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'video_recovery', Path(__file__).resolve().parents[1] /
    'apps/client/tool/check_native_video_recovery.py')
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class NativeVideoRecoveryTests(unittest.TestCase):
    def evidence(self, wait=395, deadline=420, decode=10):
        rows = []
        for i in range(32):
            arrival = 61000 + i * 500
            timing = [i, 0, 0, 0, 0, 0, 0, 0, arrival, arrival,
                      arrival + wait, arrival + wait + decode,
                      arrival + deadline, 0, 0]
            rows.append({'time': arrival / 1000, 'streams': [
                {'kind': 'video', 'googTimingFrameInfo': ','.join(map(str, timing))}]})
        return ({'p2p': True, 'separate_native_sender': True, 'synthetic_media_only': True,
                 'markers': {'test_output_silenced': True}, 'impaired_media_kind': 'video',
                 'phases': [['clean', 0], ['delay', 20], ['offline', 40], ['clean', 60]],
                 'video_recovery_timing': rows},
                {'recovery_transport': {'pass': True, 'longest_active_video_decode_pause_ms': 0}})

    def test_on_time_decode_can_follow_a_long_natural_audio_queue(self):
        result = recovery.analyze(*self.evidence())
        self.assertTrue(result['pass'])
        self.assertGreater(result['worst_assembled_frame']['assembled_wait_ms'], 250)
        self.assertEqual(result['worst_late_completion_frame']['late_completion_ms'], 0)

    def test_actual_late_decode_cannot_hide_behind_a_long_wait(self):
        result = recovery.analyze(*self.evidence(deadline=30))
        self.assertFalse(result['pass'])
        self.assertEqual(result['worst_late_completion_frame']['late_completion_ms'], 375)

    def test_slow_decoder_is_rejected_even_if_its_queue_wait_was_short(self):
        self.assertFalse(recovery.analyze(*self.evidence(wait=10, deadline=30, decode=101))['pass'])

    def test_active_freeze_or_unrecovered_transport_is_rejected(self):
        data, report = self.evidence()
        report['recovery_transport']['longest_active_video_decode_pause_ms'] = 1101
        self.assertFalse(recovery.analyze(data, report)['pass'])
        report['recovery_transport']['pass'] = False
        with self.assertRaises(AssertionError):
            recovery.analyze(data, report)

    def test_repeated_pre_outage_or_missing_frame_evidence_cannot_qualify(self):
        data, report = self.evidence()
        for rows in ([data['video_recovery_timing'][0]] * 32,
                     [{**row, 'time': 59} for row in data['video_recovery_timing']],
                     data['video_recovery_timing'][:7]):
            invalid = {**data, 'video_recovery_timing': rows}
            with self.subTest(rows=len(rows)), self.assertRaises(AssertionError):
                recovery.analyze(invalid, report)

    def test_invalid_timing_or_unmuted_fixture_is_rejected(self):
        data, report = self.evidence()
        invalid = copy.deepcopy(data)
        invalid['video_recovery_timing'][0]['streams'][0]['googTimingFrameInfo'] = '1,2,3'
        with self.assertRaises(AssertionError):
            recovery.analyze(invalid, report)
        data['markers']['test_output_silenced'] = False
        with self.assertRaises(AssertionError):
            recovery.analyze(data, report)


if __name__ == '__main__':
    unittest.main()
