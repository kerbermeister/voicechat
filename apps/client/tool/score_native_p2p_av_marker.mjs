import {readFileSync, writeFileSync} from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {analyzeP2P} from './score_native_av_marker.mjs';
const report = analyzeP2P(JSON.parse(process.argv[2].endsWith('.gz') ? gunzipSync(readFileSync(process.argv[2])).toString('utf8') : readFileSync(process.argv[2], 'utf8')));
if (process.argv[3]) writeFileSync(process.argv[3], JSON.stringify(report, null, 2) + '\n');
const {audio_markers, pairs, ...summary} = report;
console.log(JSON.stringify(summary, null, 2));
process.exitCode = report.outcome === 'pass' ? 0 : 1;
