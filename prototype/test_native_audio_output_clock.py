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
            result = clock.analyze(data, {'outcome': 'pass', 'pairs': pairs, 'audio_markers': []})
        self.assertFalse(result['pass'])
        self.assertGreater(result['phases']['recovery']['max_abs_ms'], 80)

    def test_complete_output_clock_within_budget_passes(self):
        pairs = [{'id': i, 'video_time': 10 if i < 4 else 80,
                  'source_skew_ms': 0} for i in range(16)]
        data = {'phases': [['clean', 0], ['delay', 20], ['offline', 50], ['clean', 60]],
                'markers': self.markers}
        with patch.object(clock, 'marker_presentations', return_value={
            p['id']: {'time': p['video_time'] + .01} for p in pairs}):
            result = clock.analyze(data, {'outcome': 'pass', 'pairs': pairs, 'audio_markers': []})
        self.assertTrue(result['pass'])
        self.assertFalse(result['physical_speaker_measured'])

    def test_missing_output_marker_cannot_be_excluded(self):
        pairs = [{'id': i, 'video_time': 10 if i < 4 else 80,
                  'source_skew_ms': 0} for i in range(16)]
        data = {'phases': [['clean', 0], ['delay', 20], ['offline', 50], ['clean', 60]],
                'markers': self.markers}
        with patch.object(clock, 'marker_presentations', return_value={
            p['id']: {'time': p['video_time']} for p in pairs if p['id'] != 15}):
            result = clock.analyze(data, {'outcome': 'pass', 'pairs': pairs, 'audio_markers': []})
        self.assertFalse(result['pass'])
        self.assertEqual(result['phases']['recovery']['missing_output_markers'], [15])

    def test_source_corrected_output_must_also_meet_budget(self):
        pairs = [{'id': i, 'video_time': 10 if i < 4 else 80,
                  'source_skew_ms': -70} for i in range(16)]
        data = {'phases': [['clean', 0], ['delay', 20], ['offline', 50], ['clean', 60]],
                'markers': self.markers}
        with patch.object(clock, 'marker_presentations', return_value={
            p['id']: {'time': p['video_time'] - .02} for p in pairs}):
            result = clock.analyze(data, {'outcome': 'pass', 'pairs': pairs, 'audio_markers': []})
        self.assertFalse(result['pass'])
        self.assertLess(result['phases']['clean']['max_abs_ms'], 80)
        self.assertGreater(result['phases']['clean']['max_source_corrected_abs_ms'], 80)


if __name__ == '__main__':
    unittest.main()
