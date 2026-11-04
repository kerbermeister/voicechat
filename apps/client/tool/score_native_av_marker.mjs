// Uses the same checksum-protected audio decoder as the browser qualification.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {ToneDecoder} from '../integration_test/call_av_marker.js';

export function decodeAudioChunks(chunks) {
  const audio = [], blocks = [], rate = 48000;
  const decoder = new ToneDecoder(rate, marker => audio.push({id: marker.id, pcm_frame: Math.round(marker.time * rate)}));
  let frames = 0;
  for (const chunk of chunks) {
    assert.equal(chunk.rate, rate);
    const bytes = Buffer.from(chunk.pcm, 'base64');
    assert.equal(bytes.length, chunk.frames * 4);
    const samples = new Float32Array(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    assert.ok(samples.every(Number.isFinite));
    blocks.push({frame: frames, count: samples.length, time: chunk.time});
    decoder.push(samples, frames / rate);
    frames += samples.length;
  }
  let block = 0;
  for (const marker of audio) {
    while (block + 1 < blocks.length && blocks[block + 1].frame <= marker.pcm_frame) block++;
    marker.time = blocks[block].time + (marker.pcm_frame - blocks[block].frame) / rate;
  }
  return audio;
}

export function analyze(data) {
  assert.equal(data.synthetic_media_only, true);
  assert.equal(data.missing_key_gate.content.video_markers, 0);
  assert.ok(data.missing_key_gate.content.audio_peak < .001);
  const markers = data.markers, rate = 48000;
  const audio = decodeAudioChunks(markers.audio);
  const received = new Map(audio.map(marker => [marker.id, marker.time]));
  const sentAudio = new Map(markers.source_audio), sentVideo = new Map(markers.source_video);
  const pairs = markers.video.filter(([id]) => received.has(id) && sentAudio.has(id) && sentVideo.has(id))
    .map(([id, time]) => {
      const skew = 1000 * (time - received.get(id));
      const sourceSkew = 1000 * (sentVideo.get(id) - sentAudio.get(id));
      return {id, skew_ms: skew, source_skew_ms: sourceSkew,
        transport_skew_ms: skew - sourceSkew, video_time: time, audio_time: received.get(id)};
    });
  assert.equal(data.phases.length, 4);
  const [initial, delay, , recovery] = data.phases;
  function phase(start, end) {
    const values = pairs.filter(pair => pair.video_time >= start && pair.video_time < end);
    const raw = values.map(pair => Math.abs(pair.skew_ms));
    const corrected = values.map(pair => Math.abs(pair.transport_skew_ms));
    return {count: values.length, max_abs_ms: Math.max(...raw),
      max_source_corrected_abs_ms: Math.max(...corrected)};
  }
  const clean = phase(initial[1] + 5, delay[1]);
  const recovered = phase(recovery[1] + 5, Infinity);
  const sourceMax = Math.max(...pairs.map(pair => Math.abs(pair.source_skew_ms)));
  const enough = clean.count >= 4 && recovered.count >= 12;
  const withinBudget = [clean, recovered].every(phase =>
    phase.max_abs_ms <= 80 && phase.max_source_corrected_abs_ms <= 80);
  return {schema: 1, outcome: enough && withinBudget && sourceMax <= 75 ? 'pass' :
    !enough ? 'insufficient_markers' : sourceMax > 75 ? 'invalid_source_timing' : 'budget_exceeded',
    audio_checksum_markers: audio.length, matched_pairs: pairs.length,
    shared_group: data.shared_group, clean, recovery: recovered,
    max_source_offset_ms: sourceMax, physical_latency_measured: false,
    decoder_window_ms: 1024 / rate * 1000, recovery_guard_after_seconds: 5, audio_markers: audio, pairs};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const result = analyze(JSON.parse(readFileSync(process.argv[2], 'utf8')));
  if (process.argv[3]) writeFileSync(process.argv[3], JSON.stringify(result, null, 2) + '\n');
  const {pairs, audio_markers, ...summary} = result;
  console.log(JSON.stringify(summary, null, 2));
  process.exitCode = result.outcome === 'pass' ? 0 : 1;
}
