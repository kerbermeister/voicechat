"""Separate intentional synchronization buffering from late video decoding."""
import gzip
import json
from pathlib import Path
import sys


def analyze(media, report):
    assert media['p2p'] and media['separate_native_sender'] and media['synthetic_media_only']
    assert media['markers']['test_output_silenced'] and media['impaired_media_kind'] == 'video'
    assert [name for name, _ in media['phases']] == ['clean', 'delay', 'offline', 'clean']
    assert report['recovery_transport']['pass'] is True
    resume = media['phases'][-1][1]
    assert len(media['video_recovery_timing']) >= 30
    decoded = {}
    for sample in media['video_recovery_timing']:
        if sample['time'] < resume:
            continue
        video = next(row for row in sample['streams'] if row['kind'] == 'video')
        if 'googTimingFrameInfo' not in video:
            continue
        fields = list(map(int, video['googTimingFrameInfo'].split(',')))
        assert len(fields) == 15
        rtp, *_, first, last, decode, done, deadline, _, _ = fields
        if first >= resume * 1000 and first <= last <= decode <= done:
            decoded.setdefault((rtp, last), {
                'assembled_wait_ms': decode - last,
                'deadline_from_arrival_ms': deadline - last,
                'decode_ms': done - decode,
                'late_completion_ms': max(0, done - max(last, deadline)),
            })
    assert len(decoded) >= 8
    pause = report['recovery_transport']['longest_active_video_decode_pause_ms']
    assert type(pause) in (int, float) and 0 <= pause < float('inf')
    worst_wait = max(decoded.values(), key=lambda row: row['assembled_wait_ms'])
    worst_late = max(decoded.values(), key=lambda row: row['late_completion_ms'])
    # Waiting for the paired audio queue is intentional. A fixed 250 ms wait
    # limit would reject a frame decoded on time for a legitimate 400 ms queue.
    return {'pass': pause <= 1100 and worst_late['late_completion_ms'] <= 80,
            'max_active_decode_pause_ms': pause,
            'observed_decoded_frames': len(decoded),
            'worst_assembled_frame': worst_wait,
            'worst_late_completion_frame': worst_late,
            'timing_locus': 'decode_completion_vs_scheduled_render',
            'does_not_replace_av_or_speech_gates': True}


if __name__ == '__main__':
    prefix = Path(sys.argv[1])
    capture = Path(f'{prefix}.media.json')
    with (capture.open('rb') if capture.is_file() else gzip.open(f'{capture}.gz')) as stream:
        media = json.load(stream)
    result = analyze(media, json.loads(Path(f'{prefix}.analysis.json').read_bytes()))
    print(json.dumps(result))
    raise SystemExit(0 if result['pass'] else 1)
