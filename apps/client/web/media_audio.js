/* AudioContext is resumed synchronously by a trusted gesture on iOS. */
(() => {
  let context;
  const buffers = new Map();
  const sources = new Map();
  const wanted = new Map();
  function audioContext() {
    const AudioContext = window.AudioContext || window.webkitAudioContext;
    if (!AudioContext) throw new Error('Web Audio unavailable');
    return context ??= new AudioContext();
  }
  async function load(name) {
    if (!['sent', 'received', 'ringtone', 'ringback'].includes(name)) throw new Error('Unknown sound');
    if (!buffers.has(name)) buffers.set(name, (async () => {
      const response = await fetch(new URL(`assets/assets/sounds/${name}.wav`, document.baseURI));
      if (!response.ok) throw new Error('Sound unavailable');
      return audioContext().decodeAudioData(await response.arrayBuffer());
    })().catch(error => { buffers.delete(name); throw error; }));
    return buffers.get(name);
  }
  function stop(channel) {
    wanted.delete(channel);
    const source = sources.get(channel);
    if (source) { source.stop(); source.disconnect(); sources.delete(channel); }
  }
  async function play(channel, name, loop) {
    stop(channel);
    const request = {};
    wanted.set(channel, request);
    const buffer = await load(name);
    if (wanted.get(channel) !== request) return true;
    const ctx = audioContext();
    if (ctx.state !== 'running') return false;
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.loop = loop;
    source.connect(ctx.destination);
    sources.set(channel, source);
    source.start();
    return true;
  }
  function callElements() {
    return [...document.querySelectorAll('audio')].filter(e => e.srcObject && !e.muted);
  }
  async function resumeCalls() {
    const results = await Promise.allSettled(callElements().map(e => e.play()));
    return results.every(r => r.status === 'fulfilled');
  }
  function unlock() {
    try {
      const ctx = audioContext();
      // Do not await before resume/play: the trusted activation must still be active.
      const resumed = ctx.resume();
      const silent = ctx.createBufferSource();
      silent.buffer = ctx.createBuffer(1, 1, ctx.sampleRate);
      silent.connect(ctx.destination);
      silent.start();
      Promise.resolve(resumed).then(() => {
        for (const [channel, request] of wanted) {
          if (!sources.has(channel) && request.retry) request.retry();
        }
      }).catch(() => {});
    } catch (_) { /* The settings screen reports unavailable audio. */ }
    void resumeCalls();
  }
  window.VoiceChatAudio = {
    prepare() { for (const name of ['sent', 'received', 'ringtone', 'ringback']) void load(name).catch(() => {}); },
    async play(channel, name, loop) {
      const ok = await play(channel, name, loop);
      const request = wanted.get(channel);
      if (!ok && loop && request) request.retry = () => { void play(channel, name, loop).catch(() => {}); };
      return ok;
    },
    stop,
    async resume() { unlock(); return resumeCalls(); },
    close() { stop('ring'); stop('effect'); },
  };
  document.addEventListener('pointerdown', unlock, true);
  // Touch activation is available on release; click also covers VoiceOver controls.
  document.addEventListener('pointerup', unlock, true);
  document.addEventListener('click', unlock, true);
  document.addEventListener('keydown', unlock, true);
  document.addEventListener('loadedmetadata', event => {
    if (event.target.tagName === 'AUDIO' && event.target.srcObject && !event.target.muted) void resumeCalls();
  }, true);
  new MutationObserver(() => { void resumeCalls(); }).observe(document.body, {childList: true, subtree: true});
})();
