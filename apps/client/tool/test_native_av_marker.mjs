import test from 'node:test';
import assert from 'node:assert/strict';
import {analyze, analyzeP2P, decodeAudioChunks, recoveryTransport} from './score_native_av_marker.mjs';
import {markerDigits, lowTones, highTones} from '../integration_test/call_av_marker.js';

test('native markers keep exact PCM positions when callback times arrive in batches', () => {
  const rate = 48000, pcm = new Float32Array(rate * 6);
  for (let id = 0; id < 3; id++) for (const [index, digit] of markerDigits(id).entries()) {
    const first = Math.round((id * 2 + index * .15) * rate);
    for (let i = 0; i < Math.round(.105 * rate); i++) {
      const time = (first + i) / rate;
      pcm[first + i] = .14 * (Math.sin(2 * Math.PI * lowTones[digit >> 2] * time) +
        Math.sin(2 * Math.PI * highTones[digit & 3] * time));
    }
  }
  function chunks(batch) {
    return Array.from({length: pcm.length / 480}, (_, index) => ({
      time: 10 + Math.floor(index / batch) * batch / 100,
      frames: 480, rate, pcm: Buffer.from(pcm.subarray(index * 480, (index + 1) * 480).buffer,
        pcm.byteOffset + index * 480 * 4, 480 * 4).toString('base64'),
    }));
  }
  const normal = decodeAudioChunks(chunks(1)), batched = decodeAudioChunks(chunks(12));
  assert.deepEqual(normal.map(marker => marker.id), [0, 1, 2]);
  assert.deepEqual(batched.map(marker => [marker.id, marker.pcm_frame]), normal.map(marker => [marker.id, marker.pcm_frame]));
  assert.throws(() => decodeAudioChunks([{rate: 16000, frames: 0, pcm: '', time: 0}]));
});


test('P2P timing requires authenticated encrypted media controls', () => {
  const control = {protocol: 'DTLS-SRTP', negative_dtls_failed: true,
    negative_received_media_packets: 0, positive_dtls_connected: true,
    srtp_cipher: 'AES_CM_128_HMAC_SHA1_80'};
  const data = {synthetic_media_only: true, p2p: true, crypto_control: control,
    markers: {audio: [], video: [], source_audio: [], source_video: []},
    phases: [['clean', 0], ['delay', 20], ['offline', 50], ['clean', 62]]};
  assert.equal(analyzeP2P(data).outcome, 'insufficient_markers');
  for (const changed of [{protocol: 'RTP'}, {negative_dtls_failed: false},
    {negative_received_media_packets: 1}, {positive_dtls_connected: false},
    {srtp_cipher: 'NULL'}]) {
    assert.throws(() => analyzeP2P({...data, crypto_control: {...control, ...changed}}));
  }
  assert.throws(() => analyzeP2P({...data, synthetic_media_only: false}));
  const unseenSource = {...data, coherent_source: true, markers: {...data.markers,
    source_audio: [[9, 0]], source_video: [[9, .03]]}};
  assert.equal(analyzeP2P(unseenSource).max_all_source_offset_ms, 30);
  assert.equal(analyzeP2P(unseenSource).outcome, 'invalid_source_timing');
});


test('native P2P recovery requires both live streams at capture end', () => {
  const stats = Array.from({length: 120}, (_, i) => [
    {kind: 'audio', packetsReceived: i * 50}, {kind: 'video', packetsReceived: i * 20, framesDecoded: i * 20}]);
  assert.equal(recoveryTransport({stats}).pass, true);
  const stopped = stats.map((rows, i) => i < 109 ? rows : stats[108]);
  assert.equal(recoveryTransport({stats: stopped}).pass, false);
  assert.equal(recoveryTransport({stats: stats.map(rows => rows.slice(0, 1)), audio_only: true}).pass, true);
  assert.equal(recoveryTransport({}).pass, false);
  const undecodable = stats.map(rows => [rows[0], {...rows[1], framesDecoded: 0}]);
  assert.equal(recoveryTransport({stats: undecodable}).pass, false);
  const missingVideo = stats.map(rows => rows.slice(0, 1));
  assert.equal(recoveryTransport({stats: missingVideo}).pass, false);
});

test('both native SFU and P2P reject good early timing followed by a frozen decoder', () => {
  const rate = 48000, times = [6, 8, 10, 12, 56, 58, ...Array.from({length: 12}, (_, i) => 68 + 2 * i)];
  const audio = times.map((time, id) => {
    const pcm = new Float32Array(rate);
    for (const [index, digit] of markerDigits(id).entries()) {
      // Omitted silence separates chunks; keep each tone window inside its chunk.
      const first = Math.round((.1 + index * .15) * rate);
      for (let i = 0; i < Math.round(.105 * rate); i++) {
        const t = (first + i) / rate;
        pcm[first + i] = .14 * (Math.sin(2 * Math.PI * lowTones[digit >> 2] * t) +
          Math.sin(2 * Math.PI * highTones[digit & 3] * t));
      }
    }
    return {time, frames: rate, rate, pcm: Buffer.from(pcm.buffer).toString('base64')};
  });
  const points = times.map((time, id) => [id, time + .1]);
  const stats = Array.from({length: 120}, (_, i) => [
    {kind: 'audio', packetsReceived: i * 50},
    {kind: 'video', packetsReceived: i * 20, framesDecoded: i * 20}]);
  const data = {synthetic_media_only: true, p2p: true,
    missing_key_gate: {content: {video_markers: 0, audio_peak: 0}},
    crypto_control: {protocol: 'DTLS-SRTP', negative_dtls_failed: true,
      negative_received_media_packets: 0, positive_dtls_connected: true,
      srtp_cipher: 'AES_CM_128_HMAC_SHA1_80'},
    markers: {audio, video: points, source_audio: points, source_video: points},
    phases: [['clean', 0], ['delay', 20], ['offline', 50], ['clean', 62]], stats};
  const frozen = stats.map((rows, i) => [rows[0], {...rows[1], framesDecoded: Math.min(i, 100) * 20}]);
  for (const score of [analyze, analyzeP2P]) {
    const result = score(data);
    assert.equal(result.outcome, 'pass', JSON.stringify({clean: result.clean, recovery: result.recovery, first: result.pairs[0]}));
    assert.equal(score({...data, stats: frozen}).outcome, 'stalled_transport');
    const earlyLag = {...data, markers: {...data.markers,
      video: points.map(([id, time]) => [id, time + (id === 4 ? .12 : 0)])}};
    assert.equal(score(earlyLag).outcome, 'pass');
    const delayOnly = {...earlyLag, delay_only: true,
      phases: [['clean', 0], ['delay', 20], ['clean', 50], ['clean', 62]]};
    assert.equal(score(delayOnly).outcome, 'budget_exceeded');
    assert.equal(score({...delayOnly, markers: data.markers}).outcome, 'pass');
  }
});
