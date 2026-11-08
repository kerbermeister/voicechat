import copy
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'output_clock', Path(__file__).resolve().parents[1] /
    'apps/client/tool/check_native_audio_output_clock.py')
clock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clock)


class OutputClockTests(unittest.TestCase):
    def setUp(self):
        self.markers = {'audio': [{'time': 1.0, 'frames': 480, 'rate': 48000},
                                 {'time': 1.01, 'frames': 480, 'rate': 48000}],
                        'audio_output_clock': [[1.005, 0, 8000, 0, 1.005],
                                               [1.015, 80, 8000, 0, 1.015]]}
        self.audio = [{'id': 1, 'pcm_frame': 240, 'time': 1.005}]

    def report(self, pairs, outcome='pass'):
        return {'outcome': outcome, 'pairs': pairs, 'audio_markers': [],
                'source_frame_identity_verified': True,
                'source_validation_max_ms': 0, 'recovery_transport': {'pass': True}}

    def test_output_sample_rate_conversion(self):
        result = clock.marker_presentations(self.markers, self.audio)
        self.assertAlmostEqual(result[1]['time'], 1.010)
        self.assertAlmostEqual(result[1]['sink_to_presentation_ms'], 5)

    def test_missing_clock_does_not_use_next_chunk_write(self):
        self.markers['audio_output_clock'].pop(0)
        self.assertEqual(clock.marker_presentations(self.markers, self.audio), {})

    def test_stale_clock_is_not_a_valid_presentation(self):
        self.markers['audio_output_clock'][0][4] = .5
        self.assertEqual(clock.marker_presentations(self.markers, self.audio), {})

    def test_clock_in_the_future_is_rejected(self):
        self.markers['audio_output_clock'][0][4] = 1.006
        self.assertEqual(clock.marker_presentations(self.markers, self.audio), {})

    def test_frame_position_restart_is_rejected(self):
        self.markers['audio_output_clock'][0][3] = 10
        with self.assertRaisesRegex(ValueError, 'restarted'):
            clock.marker_presentations(self.markers, self.audio)

    def test_marker_outside_pcm_is_rejected(self):
        self.audio[0]['pcm_frame'] = 960
        with self.assertRaisesRegex(ValueError, 'outside'):
            clock.marker_presentations(self.markers, self.audio)

    def test_marker_time_must_match_its_pcm_frame(self):
        self.audio[0]['time'] += .01
        with self.assertRaisesRegex(ValueError, 'does not match'):
            clock.marker_presentations(self.markers, self.audio)

    def test_duplicate_identity_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            clock.marker_presentations(self.markers, self.audio * 2)

    def test_output_over_budget_cannot_pass_a_decoded_sink_pass(self):
        pairs = [{'id': i, 'video_time': 10 if i < 4 else 80,
                  'source_skew_ms': 0} for i in range(16)]
        data = {'phases': [['clean', 0], ['delay', 20], ['offline', 50], ['clean', 60]],
                'markers': copy.deepcopy(self.markers)}
        with patch.object(clock, 'marker_presentations', return_value={
            p['id']: {'time': p['video_time'] + .1} for p in pairs}):
            result = clock.analyze(data, self.report(pairs))
        self.assertFalse(result['pass'])
        self.assertGreater(result['phases']['recovery']['max_abs_ms'], 80)

    def test_complete_output_clock_within_budget_passes(self):
        pairs = [{'id': i, 'video_time': 10 if i < 4 else 80,
                  'source_skew_ms': 0} for i in range(16)]
        data = {'phases': [['clean', 0], ['delay', 20], ['offline', 50], ['clean', 60]],
                'markers': self.markers}
        with patch.object(clock, 'marker_presentations', return_value={
            p['id']: {'time': p['video_time'] + .01} for p in pairs}):
            result = clock.analyze(data, self.report(pairs))
        self.assertTrue(result['pass'])
        self.assertFalse(result['physical_speaker_measured'])

    def test_missing_output_marker_cannot_be_excluded(self):
        pairs = [{'id': i, 'video_time': 10 if i < 4 else 80,
                  'source_skew_ms': 0} for i in range(16)]
        data = {'phases': [['clean', 0], ['delay', 20], ['offline', 50], ['clean', 60]],
                'markers': self.markers}
        with patch.object(clock, 'marker_presentations', return_value={
            p['id']: {'time': p['video_time']} for p in pairs if p['id'] != 15}):
            result = clock.analyze(data, self.report(pairs))
        self.assertFalse(result['pass'])
        self.assertEqual(result['phases']['recovery']['missing_output_markers'], [15])

    def test_source_corrected_output_must_also_meet_budget(self):
        pairs = [{'id': i, 'video_time': 10 if i < 4 else 80,
                  'source_skew_ms': -70} for i in range(16)]
        data = {'phases': [['clean', 0], ['delay', 20], ['offline', 50], ['clean', 60]],
                'markers': self.markers}
        with patch.object(clock, 'marker_presentations', return_value={
            p['id']: {'time': p['video_time'] - .02} for p in pairs}):
            result = clock.analyze(data, self.report(pairs))
        self.assertFalse(result['pass'])
        self.assertLess(result['phases']['clean']['max_abs_ms'], 80)
        self.assertGreater(result['phases']['clean']['max_source_corrected_abs_ms'], 80)


    def test_measured_device_queue_can_correct_a_decoded_sink_budget_failure(self):
        # A 100 ms device queue needs video 100 ms after decoded PCM for sync.
        chunks, clocks, audio, pairs = [], [], [], []
        for index in range(16):
            now = 10 + index if index < 4 else 80 + index - 4
            chunks.append({'time': now, 'frames': 480, 'rate': 48000})
            clocks.append([now + .001, 4800 + index * 480, 48000,
                           index * 480, now])
            audio.append({'id': index, 'pcm_frame': index * 480 + 240,
                          'time': now + .005})
            pairs.append({'id': index, 'video_time': now + .105,
                          'source_skew_ms': 0})
        data = {'phases': [['clean', 0], ['delay', 20], ['offline', 50], ['clean', 60]],
                'markers': {'audio': chunks, 'audio_output_clock': clocks}}
        report = self.report(pairs, 'budget_exceeded')
        report['audio_markers'] = audio
        result = clock.analyze(data, report)
        self.assertTrue(result['pass'])
        self.assertEqual(result['decoded_sink_outcome'], 'budget_exceeded')
        self.assertLess(result['phases']['clean']['max_abs_ms'], .001)
        self.assertLess(result['phases']['recovery']['max_abs_ms'], .001)

    def test_output_alignment_cannot_hide_invalid_source_or_stalled_transport(self):
        pairs = [{'id': i, 'video_time': 10 if i < 4 else 80,
                  'source_skew_ms': 0} for i in range(16)]
        data = {'phases': [['clean', 0], ['delay', 20], ['offline', 50], ['clean', 60]],
                'coherent_source': True, 'markers': self.markers}
        invalid = [
            {'outcome': 'insufficient_markers'}, {'outcome': 'invalid_source_timing'},
            {'outcome': 'stalled_transport'}, {'outcome': 'unknown'},
            {'source_frame_identity_verified': False},
            {'source_validation_max_ms': 21}, {'source_validation_max_ms': float('nan')},
            {'source_validation_max_ms': None}, {'recovery_transport': {'pass': False}},
            {'recovery_transport': {}},
        ]
        with patch.object(clock, 'marker_presentations', return_value={
            p['id']: {'time': p['video_time']} for p in pairs}):
            for fields in invalid:
                with self.subTest(fields=fields):
                    report = {**self.report(pairs, 'budget_exceeded'), **fields}
                    self.assertFalse(clock.analyze(data, report)['pass'])

    def test_decoded_failure_still_requires_full_output_coverage_and_80ms(self):
        pairs = [{'id': i, 'video_time': 10 if i < 4 else 80,
                  'source_skew_ms': 0} for i in range(16)]
        data = {'phases': [['clean', 0], ['delay', 20], ['offline', 50], ['clean', 60]],
                'markers': self.markers}
        for missing, extra_delay in ((15, 0), (None, .081)):
            with self.subTest(missing=missing, extra_delay=extra_delay), patch.object(
                    clock, 'marker_presentations', return_value={
                        p['id']: {'time': p['video_time'] + extra_delay}
                        for p in pairs if p['id'] != missing}):
                self.assertFalse(clock.analyze(data, self.report(pairs, 'budget_exceeded'))['pass'])


if __name__ == '__main__':
    unittest.main()
