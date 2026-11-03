// Test-only marker decoder. Retains one PCM window, never records media.
export const lowTones = [697, 770, 852, 941];
export const highTones = [1209, 1336, 1477, 1633];

export function markerDigits(id) {
  if (!Number.isInteger(id) || id < 0 || id > 4095) throw new Error('Invalid marker');
  const digits = [id >> 8, (id >> 4) & 15, id & 15];
  return [...digits, digits[0] ^ digits[1] ^ digits[2]];
}

export class ToneDecoder {
  constructor(sampleRate, onMarker) {
    this.sampleRate = sampleRate;
    this.onMarker = onMarker;
    this.window = new Float32Array(1024);
    this.filled = 0;
    this.armed = true;
    this.previous = null;
    this.stable = 0;
    this.digits = [];
    this.coefficients = [...lowTones, ...highTones].map(f => 2 * Math.cos(2 * Math.PI * f / sampleRate));
  }

  push(input, startTime) {
    for (let i = 0; i < input.length; i++) {
      if (!this.filled) this.windowStart = startTime + i / this.sampleRate;
      this.window[this.filled++] = input[i];
      if (this.filled === this.window.length) {
        this.readWindow(this.windowStart + this.window.length / this.sampleRate / 2);
        this.filled = 0;
      }
    }
  }

  readWindow(time) {
    let energy = 0;
    for (const value of this.window) energy += value * value;
    const powers = this.coefficients.map(coefficient => {
      let first = 0, second = 0;
      for (const value of this.window) {
        const next = value + coefficient * first - second;
        second = first; first = next;
      }
      return first * first + second * second - coefficient * first * second;
    });
    const low = powers.slice(0, 4), high = powers.slice(4);
    const row = low.indexOf(Math.max(...low)), column = high.indexOf(Math.max(...high));
    const meaningful = energy / this.window.length > .00001 &&
      low[row] > .72 * low.reduce((a, b) => a + b, 0) &&
      high[column] > .72 * high.reduce((a, b) => a + b, 0) &&
      low[row] > .08 * energy * this.window.length &&
      high[column] > .08 * energy * this.window.length;
    const digit = meaningful ? row * 4 + column : null;
    if (digit === null) {
      this.armed = true;
      this.previous = null;
      this.stable = 0;
      return;
    }
    if (digit !== this.previous) {
      this.previous = digit;
      this.candidateTime = time;
      this.stable = 0;
    }
    if (++this.stable < 2 || !this.armed) return;
    this.armed = false;
    const previousTime = this.digits.at(-1)?.time;
    if (previousTime !== undefined &&
        (this.candidateTime - previousTime < .10 || this.candidateTime - previousTime > .23)) {
      this.digits = [];
    }
    this.digits.push({digit, time:this.candidateTime});
    if (this.digits.length !== 4) return;
    const [a, b, c, checksum] = this.digits;
    if ((a.digit ^ b.digit ^ c.digit) === checksum.digit) {
      this.onMarker({id:(a.digit << 8) | (b.digit << 4) | c.digit, time:a.time});
    }
    this.digits = [];
  }
}

export function stampBits(milliseconds) {
  const value = milliseconds >>> 0;
  const bytes = [0xa5, value >>> 24, (value >>> 16) & 255, (value >>> 8) & 255, value & 255];
  bytes.push(stampChecksum(bytes));
  return bytes.flatMap(byte => Array.from({length:8}, (_, i) => (byte >> (7 - i)) & 1));
}

function stampChecksum(bytes) {
  let crc = 0;
  for (const byte of bytes) {
    crc ^= byte;
    for (let i = 0; i < 8; i++) crc = ((crc << 1) ^ ((crc & 128) ? 7 : 0)) & 255;
  }
  return crc;
}

export function readStamp(bits) {
  if (bits.length !== 48 || bits.some(bit => bit !== 0 && bit !== 1)) return null;
  const bytes = Array.from({length:6}, (_, index) =>
    bits.slice(index * 8, index * 8 + 8).reduce((value, bit) => (value << 1) | bit, 0));
  if (bytes[0] !== 0xa5 || stampChecksum(bytes.slice(0, 5)) !== bytes[5]) return null;
  return ((bytes[1] << 24) | (bytes[2] << 16) | (bytes[3] << 8) | bytes[4]) >>> 0;
}
