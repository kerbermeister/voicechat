/* AudioContext is resumed synchronously by a trusted gesture on iOS. */
(() => {
  let context;
  const buffers = new Map();
  const sources = new Map();
  const wanted = new Map();
  const duplicateAudio = new WeakSet();
  const callLevels = new Map();
  const callGraphs = new Map();
  let callDestination, outputElement;
  let outputId = '';
  function audioContext() {
    const AudioContext = window.AudioContext || window.webkitAudioContext;
    if (!AudioContext) throw new Error('Web Audio unavailable');
    return context ??= new AudioContext();
  }
  async function load(name) {
    if (!['sent', 'received', 'ringtone', 'ringback', 'ended', 'deleted'].includes(name)) throw new Error('Unknown sound');
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
    const elements = [...document.querySelectorAll('audio,video')];
    // A microphone can move from an audio player to a video tile, or LiveKit
    // can also attach it. Keep exactly one audible path across those transitions.
    const candidates = elements.filter(e => e.srcObject &&
      (!e.muted || callGraphs.has(e) || duplicateAudio.has(e)));
    const priority = e => e.id?.startsWith('livekit_audio_') ? 0 : e.tagName === 'VIDEO' ? 1 : 2;
    candidates.sort((a, b) => priority(a) - priority(b));
    const owners = new Map();
    for (const element of candidates) {
      const tracks = element.srcObject.getAudioTracks?.() ?? [];
      const duplicate = tracks.length > 0 && tracks.every(t => owners.has(t.id));
      if (duplicate) {
        const graph = callGraphs.get(element);
        if (graph) releaseCallGraph(element, graph);
        element.muted = true;
        duplicateAudio.add(element);
      } else {
        for (const track of tracks) owners.set(track.id, element);
        if (duplicateAudio.has(element)) {
          duplicateAudio.delete(element);
          element.muted = false;
        }
      }
    }
    return elements.filter(e => e.srcObject && (!e.muted || callGraphs.has(e)));
  }
  function releaseCallGraph(element, graph) {
    graph.source.disconnect(); graph.gain.disconnect();
    callGraphs.delete(element);
    element.muted = false;
  }
  async function syncCallVolumes() {
    for (const [element, graph] of callGraphs) {
      if (element.isConnected === false || !callLevels.has(graph.track.id) ||
          !element.srcObject?.getAudioTracks?.().includes(graph.track)) {
        releaseCallGraph(element, graph);
      }
    }
    for (const element of callElements()) {
      const track = element.srcObject.getAudioTracks?.().find(t => callLevels.has(t.id));
      if (!track) continue;
      const ctx = audioContext();
      let graph = callGraphs.get(element);
      if (!graph) {
        // iOS ignores element.volume, and MediaElementSource can be silent for
        // srcObject streams. Read the remote track directly for the whole range.
        const source = ctx.createMediaStreamSource(new window.MediaStream([track]));
        const gain = ctx.createGain();
        gain.gain.value = callLevels.get(track.id);
        source.connect(gain);
        const output = callDestination ?? ctx.destination;
        gain.connect(output);
        graph = {source, gain, track, output}; callGraphs.set(element, graph);
      }
      element.muted = true; // Exactly one audible path; video keeps its A/V stream.
      graph.gain.gain.setTargetAtTime(callLevels.get(track.id), ctx.currentTime, 0.02);
      if (ctx.state !== 'running') await ctx.resume();
    }
    if (outputElement && callGraphs.size && outputElement.paused) await outputElement.play();
  }
  async function selectOutput(id) {
    if (typeof id !== 'string' || id.length > 1024) throw new Error('Invalid output');
    const ctx = audioContext();
    if (typeof ctx.setSinkId === 'function') {
      await ctx.setSinkId(id);
      if (ctx.sinkId !== id) throw new Error('Output selection was not applied');
    } else {
      if (typeof window.HTMLMediaElement?.prototype.setSinkId !== 'function') {
        throw new Error('Browser does not expose output selection');
      }
      // Some Safari versions route media elements, but not AudioContext.
      // A generated stream preserves participant gain and avoids routing the
      // raw single-track WebRTC stream through Safari's affected sink path.
      if (!outputElement) {
        const destination = ctx.createMediaStreamDestination();
        const element = document.createElement('audio');
        element.id = 'voicechat_call_output';
        element.autoplay = true;
        element.srcObject = destination.stream;
        document.body.append(element);
        try {
          await element.setSinkId(id);
          if (element.sinkId !== id) throw new Error('Output selection was not applied');
          await element.play();
        } catch (error) {
          element.srcObject = null; element.remove();
          for (const track of destination.stream.getTracks()) track.stop();
          throw error;
        }
        outputElement = element;
        callDestination = destination;
      } else {
        await outputElement.setSinkId(id);
        if (outputElement.sinkId !== id) throw new Error('Output selection was not applied');
        await outputElement.play();
      }
      for (const graph of callGraphs.values()) {
        if (graph.output === callDestination) continue;
        graph.gain.disconnect(graph.output);
        graph.gain.connect(callDestination);
        graph.output = callDestination;
      }
    }
    outputId = id;
  }
  async function outputDevices() {
    const ctx = audioContext();
    const supported = typeof ctx.setSinkId === 'function' ||
        typeof window.HTMLMediaElement?.prototype.setSinkId === 'function';
    const devices = supported ? await window.navigator.mediaDevices.enumerateDevices() : [];
    return JSON.stringify({supported,
      systemPicker: supported && typeof window.navigator.mediaDevices.selectAudioOutput === 'function',
      devices: devices.filter(d => d.kind === 'audiooutput').map((d, i) => ({
        id: d.deviceId, label: d.label || `Аудиовыход ${i + 1}`,
        selected: d.deviceId === outputId || (!outputId && d.deviceId === 'default'),
      })),
    });
  }
  async function resumeCalls() {
    const results = await Promise.allSettled(callElements().filter(e => e.paused !== false).map(e => e.play()));
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
    outputDevices,
    selectOutput,
    async chooseSystemOutput() {
      const device = await window.navigator.mediaDevices.selectAudioOutput();
      await selectOutput(device.deviceId);
    },
    prepare() { for (const name of ['sent', 'received', 'ringtone', 'ringback', 'ended', 'deleted']) void load(name).catch(() => {}); },
    async play(channel, name, loop) {
      const ok = await play(channel, name, loop);
      const request = wanted.get(channel);
      if (!ok && loop && request) request.retry = () => { void play(channel, name, loop).catch(() => {}); };
      return ok;
    },
    stop,
    async setCallVolume(id, level) {
      if (typeof id !== 'string' || !Number.isFinite(level) || level < 0 || level > 3) throw new Error('Invalid receiver volume');
      callLevels.set(id, level);
      await syncCallVolumes();
    },
    forgetCallVolume(id) {
      callLevels.delete(id);
      for (const [element, graph] of callGraphs) {
        if (graph.track.id === id) releaseCallGraph(element, graph);
      }
    },
    async resume() { unlock(); return resumeCalls(); },
    close() { stop('ring'); stop('effect'); },
  };
  document.addEventListener('pointerdown', unlock, true);
  // Touch activation is available on release; click also covers VoiceOver controls.
  document.addEventListener('pointerup', unlock, true);
  document.addEventListener('click', unlock, true);
  document.addEventListener('keydown', unlock, true);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && callLevels.size) {
      unlock();
      void syncCallVolumes().catch(() => {});
    }
  });
  document.addEventListener('loadedmetadata', event => {
    if (['AUDIO', 'VIDEO'].includes(event.target.tagName) && event.target.srcObject && (!event.target.muted || callGraphs.has(event.target))) {
      void resumeCalls();
      void syncCallVolumes().catch(() => {});
    }
  }, true);
  new MutationObserver(() => { void resumeCalls(); void syncCallVolumes().catch(() => {}); }).observe(document.body, {childList: true, subtree: true});
})();
