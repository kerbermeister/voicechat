"""Known browser receipts, counter resets and an unavailable comparison path."""
import json
from pathlib import Path
import unittest

from summarize_av_markers import summarize

EVIDENCE = Path(__file__).resolve().parents[3] / 'docs/iterations/call-av-markers-2026-11-03'


class MarkerSummaryTest(unittest.TestCase):
    def receipt(self, name='rtp60.json'):
        return json.loads((EVIDENCE / name).read_text())

    def test_recorded_intervals_use_counter_deltas(self):
        result = summarize(self.receipt())
        self.assertEqual((result['markers'], result['rtp_snapshots'], result['rtp_errors']), (26, 26, 0))
        self.assertEqual(result['rows'][1]['audio_jb_ms'], 53.8)
        self.assertEqual(result['rows'][1]['video_jb_ms'], 9.5)
        self.assertEqual(result['rows'][1]['snapshot_after_audio_output_ms'], 468.4)
        self.assertEqual(result['initial_p95_abs_ms'], 102)

    def test_reset_missing_and_zero_count_never_fabricate_a_delay(self):
        report = self.receipt()
        row = report['result']['rtp_diagnostics'][1]
        row[3][3] = 0
        row[3][4] = 0
        row[4][4] = None
        result = summarize(report)['rows'][1]
        for name in ('audio_jb_ms', 'audio_target_ms', 'video_jb_ms', 'video_target_ms'):
            self.assertIsNone(result[name])
        report['result']['rtp_diagnostics_requested'] = False
        with self.assertRaises(ValueError):
            summarize(report)

    def test_recorded_video_stamp_distance_and_codec_times_are_preserved(self):
        result = summarize(self.receipt('rtp120.json'))
        self.assertEqual(result['rtp_snapshots'], 57)
        self.assertEqual(result['rows'][1]['video_stamp_delta_ms'], 4.7)
        self.assertEqual(result['rows'][1]['video_decode_ms'], 0.8)
        self.assertEqual(result['rows'][1]['video_encode_ms'], 1.5)

    def test_unavailable_element_control_has_no_invented_timings(self):
        result = summarize(self.receipt('element60.json'))
        self.assertEqual(result['playout_path'], 'element_source_baseline')
        self.assertEqual(result['outcome'], 'insufficient_markers')
        self.assertEqual(result['rows'], [])
        self.assertIsNone(result['max_get_stats_ms'])
        self.assertIsNone(result['initial_p95_abs_ms'])


if __name__ == '__main__':
    unittest.main()
