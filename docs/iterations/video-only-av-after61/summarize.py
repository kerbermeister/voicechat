"""Derive intervals from this synthetic lab's recorded counter snapshots."""
import json
from pathlib import Path
from statistics import median
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'apps/client/tool'))
from summarize_av_markers import counter_delta, mean_ms
from call_network_lab import valid_marker_result

folder = Path(__file__).resolve().parent
results = {}
for name in ('02-video-only', '03-clean-control', '04-audio-only', '05-audio-clean', '06-video-repeat'):
    report, scope = folder / (name + '.json'), folder / (name + '-media-scope.json')
    if not (report.exists() and scope.exists()):
        continue
    raw, data = json.loads(report.read_text()), json.loads(scope.read_text())
    result = raw['result']
    assert valid_marker_result(result, result['duration_seconds'])
    recovery = result['phase_changes'][-1][1]
    intervals = []
    for a, b in zip(data['samples'], data['samples'][1:]):
        if a[1] != b[1]:
            continue
        row = {'time_ms': b[0], 'phase': 'recovery' if b[1] == 'clean' and b[0] >= recovery else b[1]}
        for kind, base in (('audio', 2), ('video', 6)):
            row[kind + '_packets'] = counter_delta(b[base], a[base])
            for field, offset in (('buffer_ms', 1), ('buffer_target_ms', 2)):
                row[kind + '_' + field] = (mean_ms(counter_delta(b[base + offset], a[base + offset]),
                    counter_delta(b[base + 3], a[base + 3])) if len(a) > base + 3 and len(b) > base + 3 else None)
        intervals.append(row)
    phases = {}
    for phase in ('clean', 'delay', 'loss', 'offline', 'recovery'):
        rows = [row for row in intervals if row['phase'] == phase]
        phases[phase] = {}
        for kind in ('audio', 'video'):
            for suffix in ('buffer_ms', 'buffer_target_ms'):
                field = kind + '_' + suffix
                values = sorted(row[field] for row in rows if row[field] is not None)
                phases[phase][field] = {'min': values[0], 'max': values[-1], 'median': median(values)} if values else None
    results[name] = {'outcome': result['outcome'], 'markers': len(result['markers']),
        'p95_initial_recovery_ms': [result['baseline_p95_abs_ms'], result['recovered_p95_abs_ms']],
        'codecs': data['codecs'], 'outage': data['outage'], 'phase_intervals': phases,
        'intervals': intervals, 'physical_lip_sync_proven': False}
(folder / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps({name: {key: value[key] for key in ('outcome', 'markers', 'p95_initial_recovery_ms', 'outage')}
                  for name, value in results.items()}, indent=2))
