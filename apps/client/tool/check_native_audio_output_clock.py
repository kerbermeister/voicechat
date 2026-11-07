"""Supplement decoded-sink A/V with the observed AudioTrack presentation clock."""
import bisect
import gzip
import json
import math
from pathlib import Path
import sys


def marker_presentations(markers, audio_markers):
    chunks = markers['audio']
    clocks = markers['audio_output_clock']
    if not chunks or not clocks:
        raise ValueError('Decoded audio and AudioTrack clock are required')
    if any(len(row) != 5 or not all(type(v) in (int, float) and math.isfinite(v)
                                   for v in row) or row[1] < 0 or row[2] <= 0 or row[3] < 0
           for row in clocks):
        raise ValueError('Invalid AudioTrack clock row')
    if any(b[0] <= a[0] or b[1] <= a[1] or b[3] < a[3]
           for a, b in zip(clocks, clocks[1:])):
        raise ValueError('AudioTrack clock or frame position restarted')
    chunk_starts = []
    frame_count = 0
    for chunk in chunks:
        if (type(chunk['frames']) is not int or chunk['frames'] <= 0 or
                type(chunk['rate']) is not int or chunk['rate'] <= 0 or
                type(chunk['time']) not in (int, float) or not math.isfinite(chunk['time'])):
            raise ValueError('Invalid decoded audio chunk')
        chunk_starts.append(frame_count)
        frame_count += chunk['frames']
    if any(b['time'] <= a['time'] for a, b in zip(chunks, chunks[1:])):
        raise ValueError('Decoded audio clock must advance')
    clock_times = [row[0] for row in clocks]
    result = {}
    for marker in audio_markers:
        chunk_index = bisect.bisect_right(chunk_starts, marker['pcm_frame']) - 1
        if not 0 <= marker['pcm_frame'] < frame_count:
            raise ValueError('Audio marker lies outside captured PCM')
        chunk = chunks[chunk_index]
        offset = (marker['pcm_frame'] - chunk_starts[chunk_index]) / chunk['rate']
        if abs(marker['time'] - chunk['time'] - offset) > .000002:
            raise ValueError('Decoded audio marker clock does not match PCM')
        clock_index = bisect.bisect_left(clock_times, chunk['time'])
        if clock_index == len(clocks):
            continue
        now, written, rate, position, timestamp = clocks[clock_index]
        # The callback is made after AudioTrack.write. A missing clock must
        # not accidentally attach this chunk to the next mixed PCM block.
        if (chunk_index + 1 < len(chunks) and
                now >= chunks[chunk_index + 1]['time']):
            continue
        if not 0 <= now - timestamp < .1:
            continue
        presentation = timestamp + (written + offset * rate - position) / rate
        if not -.002 <= presentation - marker['time'] <= 2:
            continue
        if marker['id'] in result:
            raise ValueError('Duplicate audio marker identity')
        result[marker['id']] = {'time': presentation,
                                'sink_to_presentation_ms': 1000 * (presentation - marker['time'])}
    return result


def analyze(data, report):
    presentations = marker_presentations(data['markers'], report['audio_markers'])
    phases = data['phases']
    windows = {'clean': (phases[0][1] + 5, phases[1][1], 4),
               'recovery': ((phases[2] if data.get('delay_only') else phases[3])[1] + 5,
                            float('inf'), 12)}
    results = {}
    for name, (start, stop, minimum) in windows.items():
        pairs = [pair for pair in report['pairs'] if start <= pair['video_time'] < stop]
        missing = [pair['id'] for pair in pairs if pair['id'] not in presentations]
        raw = [1000 * (pair['video_time'] - presentations[pair['id']]['time'])
               for pair in pairs if pair['id'] in presentations]
        corrected = [1000 * (pair['video_time'] - presentations[pair['id']]['time'])
                     - pair['source_skew_ms']
                     for pair in pairs if pair['id'] in presentations]
        results[name] = {'count': len(pairs), 'missing_output_markers': missing,
                         'max_abs_ms': max(map(abs, raw), default=None),
                         'max_source_corrected_abs_ms': max(map(abs, corrected), default=None),
                         'pass': len(pairs) >= minimum and not missing and
                         max(map(abs, raw), default=float('inf')) <= 80 and
                         max(map(abs, corrected), default=float('inf')) <= 80}
    return {'schema': 1, 'pass': report['outcome'] == 'pass' and
            all(row['pass'] for row in results.values()),
            'decoded_sink_outcome': report['outcome'],
            'audio_device_timestamp_observed': True,
            'physical_speaker_measured': False,
            'video_sink_before_display': True,
            'phases': results, 'audio_presentations': presentations}


if __name__ == '__main__':
    capture, report, output = map(Path, sys.argv[1:])
    with (gzip.open(capture, 'rt') if capture.suffix == '.gz' else capture.open()) as stream:
        result = analyze(json.load(stream), json.loads(report.read_text()))
    with output.open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps({key: value for key, value in result.items()
                      if key != 'audio_presentations'}))
    raise SystemExit(0 if result['pass'] else 1)
