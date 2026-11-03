// Additional audio-only fault for the synthetic encrypted A/V marker fixture.
// The original order observer retains all its frame ordinals and counters.
const audioFault = {operation:'none', delayed:false, matchedCalls:0};
let activeAudioFrame = false;
const AudioTransformStream = self.TransformStream;
self.TransformStream = class extends AudioTransformStream {
  constructor(transformer, writableStrategy, readableStrategy) {
    const observed = typeof transformer?.transform !== 'function' ? transformer : {
      ...transformer,
      transform(frame, controller) {
        const previous = activeAudioFrame;
        activeAudioFrame = frame instanceof RTCEncodedAudioFrame;
        try { return transformer.transform.call(transformer, frame, controller); }
        finally { activeAudioFrame = previous; }
      },
    };
    super(observed, writableStrategy, readableStrategy);
  }
};
for (const operation of ['encrypt', 'decrypt']) {
  const original = crypto.subtle[operation].bind(crypto.subtle);
  crypto.subtle[operation] = (...args) => {
    const result = original(...args);
    if (!activeAudioFrame || audioFault.operation !== operation) return result;
    audioFault.matchedCalls++;
    if (audioFault.delayed) return result;
    audioFault.delayed = true;
    return result.then(value => new Promise(resolve => setTimeout(() => resolve(value), 500)));
  };
}
self.addEventListener('message', event => {
  const request = event.data;
  if (request?.msgType !== 'fixture-av-control') return;
  event.stopImmediatePropagation();
  let data;
  if (request.command === 'arm' && audioFault.operation === 'none' &&
      ['encrypt', 'decrypt'].includes(request.operation)) {
    audioFault.operation = request.operation;
    data = {armed:true};
  } else if (request.command === 'summary') {
    data = {...audioFault, delayMs:audioFault.operation === 'none' ? 0 : 500};
  } else data = {error:'Invalid or repeated audio fault command'};
  self.postMessage({msgType:'fixture-av-result', msgId:request.msgId, data});
});
importScripts('../cryptor_order_worker.js');
