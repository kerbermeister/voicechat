// Uses the same checksum-protected audio decoder as the browser qualification.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
import {gunzipSync} from 'node:zlib';
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
  const report = analyzeTiming(data);
  if (data.coherent_source && report.max_all_source_offset_ms > 20) report.outcome = 'invalid_source_timing';
  return report;
}

export function recoveryTransport(data) {
  const samples = data.stats;
  const kinds = data.audio_only === true ? ['audio'] : ['audio', 'video'];
  const counts = {};
  for (const kind of kinds) {
    const first = samples?.at(-11)?.find(row => row.kind === kind)?.packetsReceived;
    const last = samples?.at(-1)?.find(row => row.kind === kind)?.packetsReceived;
    counts[kind] = Number.isFinite(first) && Number.isFinite(last) ? last - first : 0;
  }
  const decodedFirst = samples?.at(-11)?.find(row => row.kind === 'video')?.framesDecoded;
  const decodedLast = samples?.at(-1)?.find(row => row.kind === 'video')?.framesDecoded;
  const decoded = Number.isFinite(decodedFirst) && Number.isFinite(decodedLast) ? decodedLast - decodedFirst : 0;
  return {pass: Object.values(counts).every(count => count > 30) && (data.audio_only === true || decoded > 0),
    packet_deltas: counts, decoded_video_frames: decoded};
}

export function analyzeP2P(data) {
  assert.equal(data.synthetic_media_only, true);
  assert.equal(data.p2p, true);
  const control = data.crypto_control;
  assert.equal(control.protocol, 'DTLS-SRTP');
  assert.equal(control.negative_dtls_failed, true);
  assert.equal(control.negative_received_media_packets, 0);
  assert.equal(control.positive_dtls_connected, true);
  assert.ok(new Set(['AES_CM_128_HMAC_SHA1_80', 'SRTP_AES128_CM_SHA1_80',
    'AEAD_AES_128_GCM', 'AEAD_AES_256_GCM', 'SRTP_AEAD_AES_128_GCM', 'SRTP_AEAD_AES_256_GCM'])
    .has(control.srtp_cipher));
  const report = analyzeTiming(data);
  if (data.coherent_source && report.max_all_source_offset_ms > 20) report.outcome = 'invalid_source_timing';
  return report;
}

function analyzeTiming(data) {
  const markers = data.markers, rate = 48000;
  const audio = decodeAudioChunks(markers.audio);
  const received = new Map(audio.map(marker => [marker.id, marker.time]));
  const sentAudio = new Map(markers.source_audio), sentVideo = new Map(markers.source_video);
  const emittedVideo = new Map(sentVideo);
  const sourceFramesVerified = markers.source_video_frames !== undefined || markers.received_video_frames !== undefined;
  if (sourceFramesVerified) {
    assert.ok(Array.isArray(markers.source_video_frames) && Array.isArray(markers.received_video_frames));
    const frames = new Map();
    const firstFrames = new Map();
    for (const [id, frame, time] of markers.source_video_frames) {
      assert.ok(Number.isInteger(id) && id >= 0 && id <= 4095 &&
        Number.isInteger(frame) && frame >= 0 && frame < 16 && Number.isFinite(time));
      const key = `${id}:${frame}`;
      assert.ok(!frames.has(key), 'Ambiguous emitted marker frame');
      frames.set(key, time);
      firstFrames.set(id, Math.min(firstFrames.get(id) ?? Infinity, time));
    }
    for (const [id, time] of emittedVideo) {
      assert.equal(firstFrames.get(id), time, 'Source onset must match its first generated frame');
    }
    assert.equal(markers.received_video_frames.length, markers.video.length);
    for (const [index, [id, frame]] of markers.received_video_frames.entries()) {
      assert.equal(id, markers.video[index][0]);
      assert.ok(frames.has(`${id}:${frame}`), 'Received marker lacks its exact source frame');
      sentVideo.set(id, frames.get(`${id}:${frame}`));
    }
  }
  const pairs = markers.video.filter(([id]) => received.has(id) && sentAudio.has(id) && sentVideo.has(id))
    .map(([id, time]) => {
      const skew = 1000 * (time - received.get(id));
      const sourceSkew = 1000 * (sentVideo.get(id) - sentAudio.get(id));
      return {id, skew_ms: skew, source_skew_ms: sourceSkew,
        transport_skew_ms: skew - sourceSkew, video_time: time, audio_time: received.get(id)};
    });
  assert.equal(data.phases.length, 4);
  const [initial, delay, interruption, recovery] = data.phases;
  function phase(start, end) {
    const values = pairs.filter(pair => pair.video_time >= start && pair.video_time < end);
    const raw = values.map(pair => Math.abs(pair.skew_ms));
    const corrected = values.map(pair => Math.abs(pair.transport_skew_ms));
    return {count: values.length, max_abs_ms: Math.max(...raw),
      max_source_corrected_abs_ms: Math.max(...corrected)};
  }
  const clean = phase(initial[1] + 5, delay[1]);
  const recovered = phase((data.delay_only === true ? interruption : recovery)[1] + 5, Infinity);
  const sourceMax = Math.max(...pairs.map(pair => Math.abs(pair.source_skew_ms)));
  // Source coherence is measured before the encoder/network can drop an onset.
  // Exact delivered-frame timing remains in pairs; raw playout still includes
  // the complete cost of any dropped onset and must meet the unchanged budget.
  const allSourceMax = Math.max(...[...emittedVideo].filter(([id]) => sentAudio.has(id))
    .map(([id, time]) => Math.abs(time - sentAudio.get(id)) * 1000));
  const sourceValidationMax = sourceFramesVerified ? allSourceMax : sourceMax;
  const enough = clean.count >= 4 && recovered.count >= 12;
  const withinBudget = [clean, recovered].every(phase =>
    phase.max_abs_ms <= 80 && phase.max_source_corrected_abs_ms <= 80);
  const transport = recoveryTransport(data);
  const outcome = enough && withinBudget && sourceValidationMax <= 75 ? 'pass' :
    !enough ? 'insufficient_markers' : sourceValidationMax > 75 ? 'invalid_source_timing' : 'budget_exceeded';
  return {schema: 1, outcome: outcome === 'pass' && !transport.pass ? 'stalled_transport' : outcome,
    recovery_transport: transport,
    audio_checksum_markers: audio.length, matched_pairs: pairs.length,
    shared_group: data.shared_group, source_frame_identity_verified: sourceFramesVerified, clean, recovery: recovered,
    max_source_offset_ms: sourceMax, max_all_source_offset_ms: allSourceMax,
    source_validation_max_ms: sourceValidationMax, physical_latency_measured: false,
    decoder_window_ms: 1024 / rate * 1000, recovery_guard_after_seconds: 5, audio_markers: audio, pairs};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const result = analyze(JSON.parse(process.argv[2].endsWith('.gz') ? gunzipSync(readFileSync(process.argv[2])).toString('utf8') : readFileSync(process.argv[2], 'utf8')));
  if (process.argv[3]) writeFileSync(process.argv[3], JSON.stringify(result, null, 2) + '\n');
  const {pairs, audio_markers, ...summary} = result;
  console.log(JSON.stringify(summary, null, 2));
  process.exitCode = result.outcome === 'pass' ? 0 : 1;
}
