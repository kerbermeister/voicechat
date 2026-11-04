"""Compare synthetic native speech with its reference (NumPy/SciPy/pystoi)."""
import argparse
import base64
import json
from pathlib import Path

import numpy as np
from scipy.io import wavfile
from scipy.signal import correlate, resample_poly
from pystoi import stoi


def excerpts(media, analysis, reference):
    chunks = media['markers']['audio']
    assert all(chunk['rate'] == 48000 for chunk in chunks)
    pcm = np.concatenate([np.frombuffer(base64.b64decode(chunk['pcm']), '<f4') for chunk in chunks])
    result = {}
    source = dict(media['markers']['source_audio'])
    phases = media['phases']
    for marker in analysis['audio_markers']:
        index = marker['id']
        approximate = marker['pcm_frame'] + round(.75 * 48000)
        start, stop = approximate - 4800, approximate + 4800 + len(reference)
        if start < 0 or stop > len(pcm) or index not in source:
            continue
        window = pcm[start:stop].astype(float)
        offset = int(np.argmax(correlate(window, reference, mode='valid')))
        clip = window[offset:offset + len(reference)]
        when = marker['time']
        phase = ('clean' if phases[0][1] + 2 <= when < phases[1][1] - 2 else
                 'delay' if phases[1][1] + 2 <= when < phases[2][1] - 2 else
                 'pause' if phases[2][1] + 1 <= when < phases[3][1] - 1 else
                 'recovery' if when >= phases[3][1] + 6 else None)
        if phase:
            result[index] = (phase, clip)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--control', type=Path, action='append', required=True)
    parser.add_argument('--candidate', type=Path, action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if len(args.control) != len(args.candidate):
        parser.error('Match each complete control trial to one candidate trial')
    rate, wav = wavfile.read(args.reference)
    assert rate == 48000 and wav.dtype == np.int16 and wav.ndim == 1
    reference = wav.astype(float) / 32768
    def read(path):
        media = json.loads(path.read_text())
        report = json.loads(path.with_name(path.name.replace('.media.json', '.analysis.json')).read_text())
        return excerpts(media, report, reference)
    control = {(trial, index): value for trial, path in enumerate(args.control) for index, value in read(path).items()}
    candidate = {(trial, index): value for trial, path in enumerate(args.candidate) for index, value in read(path).items()}
    results = {}
    for phase in ('clean', 'delay', 'pause', 'recovery'):
        ids = [index for index in control if index in candidate and control[index][0] == candidate[index][0] == phase]
        for trial in range(len(args.control)):
            assert sum(index[0] == trial for index in ids) >= 4, (phase, trial, 'insufficient paired speech')
        x = resample_poly(np.tile(reference, len(ids)), 1, 3)
        metrics = {}
        for label, run in [('control', control), ('candidate', candidate)]:
            y = resample_poly(np.concatenate([run[index][1] for index in ids]), 1, 3)
            alpha = np.dot(x, y) / np.dot(x, x)
            target = alpha * x
            metrics[label] = {
                'stoi': float(stoi(x, y, 16000)),
                'si_sdr_db': float(10 * np.log10(np.dot(target, target) / np.sum((y - target) ** 2))),
                'rms_dbfs': float(20 * np.log10(np.sqrt(np.mean(y * y)))),
            }
        results[phase] = {'paired_clips': len(ids), **metrics}
    passed = all(row['candidate']['stoi'] >= row['control']['stoi'] - .005 and
                 abs(row['candidate']['rms_dbfs'] - row['control']['rms_dbfs']) <= .15
                 for row in results.values())
    report = {'schema': 1, 'outcome': 'pass' if passed else 'speech_regression',
              'synthetic_reference_only': True, 'physical_listening_test': False, 'paired_trials': len(args.control),
              'stoi_noninferiority_margin': .005, 'level_tolerance_db': .15, 'phases': results}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
