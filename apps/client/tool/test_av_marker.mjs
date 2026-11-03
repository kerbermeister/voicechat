import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs/promises';

// Import the browser module without changing the repository's Node module mode.
const source = await fs.readFile(new URL('../integration_test/call_av_marker.js', import.meta.url), 'utf8');
const {ToneDecoder, markerDigits, stampBits, readStamp} = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));

function decodeSignal(id, sampleRate, amplitude, invalidChecksum = false) {
  const decoded = [];
  const decoder = new ToneDecoder(sampleRate, marker => decoded.push(marker));
  const digits = [(id >> 8) & 15, (id >> 4) & 15, id & 15];
  digits.push(digits[0] ^ digits[1] ^ digits[2] ^ (invalidChecksum ? 1 : 0));
  const rows = [697, 770, 852, 941], columns = [1209, 1336, 1477, 1633];
  const samples = new Float32Array(Math.ceil(sampleRate * 1.5));
  let noise = 12345;
  for (let i = 0; i < samples.length; i++) {
    const t = i / sampleRate, symbol = Math.floor((t - .5) / .16);
    noise = (Math.imul(noise, 1664525) + 1013904223) >>> 0;
    samples[i] = (noise / 2 ** 32 - .5) * .002;
    if (symbol >= 0 && symbol < 4 && t - .5 - symbol * .16 < .1) {
      const digit = digits[symbol];
      samples[i] += amplitude * (Math.sin(2 * Math.PI * rows[digit >> 2] * t) +
        Math.sin(2 * Math.PI * columns[digit & 3] * t));
    }
  }
  for (let i = 0; i < samples.length; i += 128) decoder.push(samples.subarray(i, i + 128), i / sampleRate);
  return decoded;
}

test('DTMF marker identity and onset survive sample rate, gain, noise and repeated digits', () => {
  for (const sampleRate of [44100, 48000]) for (const amplitude of [.03, .12, .24]) {
    for (const id of [0, 15, 16, 255, 256, 1023, 4095]) {
      const decoded = decodeSignal(id, sampleRate, amplitude);
      assert.equal(decoded.length, 1, JSON.stringify({id, sampleRate, amplitude, decoded}));
      assert.equal(decoded[0].id, id);
      assert.ok(Math.abs(decoded[0].time - .5) < .035);
    }
  }
});

test('Wrong checksum, silence and a single-frequency tone cannot report a marker', () => {
  assert.deepEqual(decodeSignal(42, 48000, .12, true), []);
  assert.deepEqual(decodeSignal(42, 48000, 0), []);
  const decoded = [], decoder = new ToneDecoder(48000, marker => decoded.push(marker));
  for (let block = 0; block < 750; block++) {
    const samples = Float32Array.from({length:128}, (_, i) => .2 * Math.sin(2 * Math.PI * 697 * (block * 128 + i) / 48000));
    decoder.push(samples, block * 128 / 48000);
  }
  assert.deepEqual(decoded, []);
});

test('Visual clock stamps reject corrupted cells and preserve unsigned timestamps', () => {
  for (const time of [0, 1234, 1800000, 3600000, 0xffffffff]) {
    const bits = stampBits(time);
    assert.equal(readStamp(bits), time);
    for (let i = 0; i < bits.length; i++) {
      const corrupted = [...bits]; corrupted[i] ^= 1;
      assert.equal(readStamp(corrupted), null);
    }
  }
  assert.equal(readStamp([]), null);
  assert.equal(readStamp(Array(48).fill(2)), null);
  assert.deepEqual(markerDigits(0x123), [1, 2, 3, 0]);
  assert.throws(() => markerDigits(4096));
});
