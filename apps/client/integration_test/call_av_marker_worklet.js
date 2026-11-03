import {ToneDecoder} from './call_av_marker.js';

class MarkerSink extends AudioWorkletProcessor {
  constructor() {
    super();
    this.decoder = new ToneDecoder(sampleRate, marker => this.port.postMessage(marker));
  }
  process(inputs, outputs) {
    const input = inputs[0]?.[0];
    if (input) this.decoder.push(input, currentFrame / sampleRate);
    // Observe the real product gain output, but never play the synthetic tone.
    for (const channels of outputs) for (const channel of channels) channel.fill(0);
    return true;
  }
}
registerProcessor('voicechat-marker-sink', MarkerSink);
