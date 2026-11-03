"""Summarize synthetic A/V marker counters without inventing missing intervals."""
import argparse
import json
from pathlib import Path

from call_network_lab import valid_marker_result


def counter_delta(value, previous):
    return None if value is None or previous is None or value < previous else value - previous


def mean_ms(total, count):
    return None if total is None or not count else round(total / count * 1000, 1)


def summarize(report):
    data = report.get('result') if isinstance(report, dict) else None
    if (not isinstance(data, dict) or
            not valid_marker_result(data, data.get('duration_seconds', 0)) or
            data['schema'] != 2 or not data['rtp_diagnostics_requested']):
        raise ValueError('A valid synthetic RTP diagnostic report is required')
    markers = {marker[0]: marker for marker in data['markers']}
    rows = []
    previous = None
    for row in data['rtp_diagnostics']:
        marker = markers[row[0]]
        result = {'id': row[0], 'profile': marker[1], 'offset_ms': marker[2],
                  'snapshot_after_audio_output_ms': round(row[1] - marker[3], 1),
                  'get_stats_ms': row[2], 'sender_reason': row[7],
                  'video_stamp_delta_ms': row[8] if len(row) == 9 else None,
                  'rtt_ms': None if row[6][0] is None else round(row[6][0] * 1000, 1)}
        if previous is not None:
            for label, index in [('audio', 3), ('video', 4)]:
                current, prior = row[index], previous[index]
                emitted = counter_delta(current[4], prior[4])
                result[label + '_jb_ms'] = mean_ms(counter_delta(current[3], prior[3]), emitted)
                result[label + '_target_ms'] = mean_ms(counter_delta(current[5], prior[5]), emitted)
            for name, index in [('concealed', 6), ('deceleration_samples', 8),
                                ('acceleration_samples', 9), ('lost_audio_packets', 1)]:
                result[name] = counter_delta(row[3][index], previous[3][index])
            result['dropped_video_frames'] = counter_delta(row[4][11], previous[4][11])
            result['video_decode_ms'] = mean_ms(counter_delta(row[4][12], previous[4][12]),
                                                counter_delta(row[4][10], previous[4][10]))
            result['video_encode_ms'] = mean_ms(counter_delta(row[5][2], previous[5][2]),
                                                counter_delta(row[5][0], previous[5][0]))
        rows.append(result)
        previous = row
    return {'outcome': data['outcome'], 'playout_path': data.get('playout_path', 'product_gain'),
            'markers': len(markers), 'rtp_snapshots': len(rows),
            'rtp_errors': data['rtp_diagnostics_errors'],
            'initial_p95_abs_ms': data['baseline_p95_abs_ms'],
            'recovered_p95_abs_ms': data['recovered_p95_abs_ms'],
            'max_get_stats_ms': max((row['get_stats_ms'] for row in rows), default=None),
            'rows': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(json.loads(args.report.read_text())), indent=2))


if __name__ == '__main__':
    main()
