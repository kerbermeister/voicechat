import test from 'node:test';
import assert from 'node:assert/strict';
import {decodeAudioChunks} from './score_native_av_marker.mjs';
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
