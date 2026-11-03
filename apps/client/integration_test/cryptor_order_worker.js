// Loopback fixture bootstrap; never included in the production worker assets.
// Delay the result of real WebCrypto, retaining its exact cipher/plaintext bytes.
const fixture = {
  operation: 'none',
  delayMs: 0,
  delayed: false,
  calls: {encrypt: 0, decrypt: 0},
  controllers: new WeakMap(),
  frames: new WeakMap(),
  summaries: [],
};

function countsFor(controller) {
  let row = fixture.controllers.get(controller);
  if (!row) {
    if (fixture.summaries.length >= 8) throw Error('Fixture controller limit');
    row = {
      reads: 0, writes: 0, backwardSteps: 0, largestBackwardOrdinal: 0,
      backwardInputTimestamps: 0, backwardOutputTimestamps: 0,
      returnedPromises: 0, returnedNonPromises: 0,
      lastInputTimestamp: null, lastOutputTimestamp: null, lastOutputOrdinal: 0,
    };
    fixture.controllers.set(controller, row);
    fixture.summaries.push(row);
  }
  return row;
}

// Assign order at the transform input. Receiver RTP timestamps may already be
// out of order, so output timestamps alone cannot identify a crypto race.
const NativeTransformStream = self.TransformStream;
self.TransformStream = class extends NativeTransformStream {
  constructor(transformer, writableStrategy, readableStrategy) {
    let observed = transformer;
    if (typeof transformer?.transform === 'function') {
      observed = {
        ...transformer,
        transform(frame, controller) {
          let row;
          if (frame && Number.isFinite(frame.timestamp)) {
            row = countsFor(controller);
            row.reads++;
            if (row.lastInputTimestamp !== null && frame.timestamp < row.lastInputTimestamp) {
              row.backwardInputTimestamps++;
            }
            row.lastInputTimestamp = frame.timestamp;
            fixture.frames.set(frame, {row, ordinal: row.reads});
          }
          const completion = transformer.transform.call(transformer, frame, controller);
          if (row) {
            if (completion && typeof completion.then === 'function') row.returnedPromises++;
            else row.returnedNonPromises++;
          }
          return completion;
        },
      };
    }
    super(observed, writableStrategy, readableStrategy);
  }
};

for (const operation of ['encrypt', 'decrypt']) {
  const original = crypto.subtle[operation].bind(crypto.subtle);
  crypto.subtle[operation] = (...args) => {
    const result = original(...args);
    const first = ++fixture.calls[operation] === 1;
    if (first && fixture.operation === operation && fixture.delayMs) {
      fixture.delayed = true;
      const delayMs = fixture.delayMs;
      return result.then(value => new Promise(resolve => {
        setTimeout(() => resolve(value), delayMs);
      }));
    }
    return result;
  };
}

const originalEnqueue = TransformStreamDefaultController.prototype.enqueue;
TransformStreamDefaultController.prototype.enqueue = function(frame) {
  if (frame && Number.isFinite(frame.timestamp)) {
    const row = countsFor(this);
    const arrival = fixture.frames.get(frame);
    if (!arrival || arrival.row !== row) throw Error('Fixture frame input is missing');
    if (arrival.ordinal < row.lastOutputOrdinal) {
      row.backwardSteps++;
      row.largestBackwardOrdinal = Math.max(row.largestBackwardOrdinal,
          row.lastOutputOrdinal - arrival.ordinal);
    }
    if (row.lastOutputTimestamp !== null && frame.timestamp < row.lastOutputTimestamp) {
      row.backwardOutputTimestamps++;
    }
    row.lastOutputOrdinal = arrival.ordinal;
    row.lastOutputTimestamp = frame.timestamp;
    row.writes++;
  }
  return originalEnqueue.call(this, frame);
};

self.addEventListener('message', event => {
  const request = event.data;
  if (request?.msgType !== 'fixture-order-control') return;
  event.stopImmediatePropagation();
  let data;
  if (request.command === 'configure' &&
      ['none', 'encrypt', 'decrypt'].includes(request.operation) &&
      [0, 500].includes(request.delayMs)) {
    fixture.operation = request.operation;
    fixture.delayMs = request.delayMs;
    fixture.delayed = false;
    fixture.calls = {encrypt: 0, decrypt: 0};
    fixture.controllers = new WeakMap();
    fixture.frames = new WeakMap();
    fixture.summaries = [];
    data = {configured: true};
  } else if (request.command === 'summary') {
    data = {
      operation: fixture.operation,
      delayMs: fixture.delayMs,
      delayed: fixture.delayed,
      calls: fixture.calls,
      // No frame bodies, keys, SSRCs, track IDs or absolute timestamps.
      controllers: fixture.summaries.map(({
        lastInputTimestamp, lastOutputTimestamp, lastOutputOrdinal, ...counts
      }) => counts),
    };
  } else {
    data = {error: 'Invalid fixture command'};
  }
  self.postMessage({msgType: 'fixture-order-result', msgId: request.msgId, data});
});

importScripts('../e2ee.worker.dart.js');
