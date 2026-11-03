import {lowTones, highTones, markerDigits, stampBits, readStamp} from './call_av_marker.js';
import {transportDiagnostics} from './call_transport_diagnostics.js';
import {mediaScopeCodecs, mediaScopeSample, singleStreamOutageProof, videoPlayoutSample} from './call_media_scope.js';

const result = document.querySelector('#result'), button = document.querySelector('#run');
const elementBaseline = new URLSearchParams(location.search).get('playout') === 'element';
const playoutPath = elementBaseline ? 'element_source_baseline' : 'product_gain';
if (elementBaseline) document.querySelector('#description').textContent =
  'CONTROL: combined media element audio source, bypassing product gain for comparison. Local synthetic media only; the final worklet sink is silent. No physical lip-sync measurement.';
const NativeAudioContext = window.AudioContext || window.webkitAudioContext;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
class FixtureError extends Error {}
const check = (condition, message) => { if (!condition) throw new FixtureError(message); };
async function bounded(promise, stage) {
  let timer;
  result.textContent = `Preparing: ${stage}`;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new FixtureError(`Deadline: ${stage}`)), 15000);
    })]);
  } finally { clearTimeout(timer); }
}
let receivingContext, sink, sinkReady;
const graphs = new Set();
let rebindSource, sourceCount = 0;

// Only the final destination is instrumented. The product source/gain and its
// clock run unchanged; no test tone can reach the speaker through this graph.
window.AudioContext = class extends NativeAudioContext {
  constructor(...args) {
    super(...args);
    receivingContext = this;
    sinkReady = this.audioWorklet.addModule('./call_av_marker_worklet.js').then(() => {
      sink = new AudioWorkletNode(this, 'voicechat-marker-sink');
      sink.connect(this.destination);
    });
  }
  createGain() {
    const gain = super.createGain();
    const connect = gain.connect.bind(gain), disconnect = gain.disconnect.bind(gain);
    gain.connect = (destination, ...args) => {
      if (destination === this.destination) {
        check(sink, 'Marker sink not ready');
        graphs.add(gain);
        return connect(sink, ...args);
      }
      return connect(destination, ...args);
    };
    gain.disconnect = (...args) => { graphs.delete(gain); return disconnect(...args); };
    return gain;
  }
  createMediaStreamSource(stream) {
    const original = super.createMediaStreamSource(stream);
    const connect = original.connect.bind(original), disconnect = original.disconnect.bind(original);
    let current = original, output;
    sourceCount++;
    original.connect = (target, ...args) => {
      output = target;
      return current === original ? connect(target, ...args) : current.connect(target, ...args);
    };
    original.disconnect = (...args) => current === original ? disconnect(...args) : current.disconnect(...args);
    rebindSource = () => {
      check(sourceCount === 1 && output && graphs.size === 1, 'Expected one product source');
      const next = NativeAudioContext.prototype.createMediaStreamSource.call(this, stream);
      original.disconnect();
      try { next.connect(output); }
      catch (error) {
        if (current === original) connect(output); else current.connect(output);
        next.disconnect();
        throw error;
      }
      current = next;
      // The product still owns the original handle; its disconnect now releases
      // the replacement too. No element unmute, new gain or extra audible path.
      return {performed:true, same_audio_track:next.mediaStream.getAudioTracks()[0] === stream.getAudioTracks()[0],
        graph_count:graphs.size, at_ms:performance.now()};
    };
    return original;
  }
};
await import('./media_audio.js');
// Optional lab-only encryption uses the SDK factory and exact compiled worker.
const encrypted = new URLSearchParams(location.search).get('e2ee') === '1';
if (encrypted) await import('./call_av_marker_e2ee.dart.js');
const e2ee = encrypted ? window.VoiceChatMarkerE2EE : null;
const useSfu = new URLSearchParams(location.search).get('sfu') === '1';
if (useSfu) {
  await import('./main.dart.js');
  await waitFor(() => window.VoiceChatMarkerSfu);
  document.querySelector('#description').textContent =
    'Local LiveKit SFU and SDK E2EE with synthetic audio and video. The audio sink is silent.';
}
const sfu = useSfu ? window.VoiceChatMarkerSfu : null;

async function connectSfu(source, splitSync) {
  const connections = [];
  const NativeConnection = window.RTCPeerConnection;
  window.RTCPeerConnection = class extends NativeConnection {
    constructor(config) {
      super(config);
      connections.push(this);
    }
  };
  try {
    const remote = await bounded(sfu.connect(source, splitSync), 'LiveKit E2EE subscriptions');
    const sender = connections.find(pc => pc.getSenders().some(sender =>
      sender.track === source.getVideoTracks()[0]));
    const receiver = connections.find(pc => pc.getReceivers().some(receiver =>
      receiver.track === remote.getVideoTracks()[0]));
    check(sender && receiver && sender !== receiver && sfu.missingKeyBlocked(),
      'Expected distinct LiveKit transports and missing-key proof');
    return {sender, receiver, remote};
  } finally {
    window.RTCPeerConnection = NativeConnection;
  }
}

async function waitFor(condition) {
  const deadline = performance.now() + 15000;
  while (!condition()) {
    check(performance.now() < deadline, 'Media setup deadline');
    await delay(50);
  }
}

function percentile95(values) {
  if (!values.length) return null;
  const sorted = values.map(Math.abs).sort((a, b) => a - b);
  return sorted[Math.ceil(sorted.length * .95) - 1];
}

button.disabled = false;
result.textContent = 'Ready: synthetic media only; output is silent';
button.onclick = async () => {
  button.disabled = true;
  const sourceContext = new NativeAudioContext();
  const sourceReady = sourceContext.resume(); // Preserve the trusted activation.
  void VoiceChatAudio.resume();
  let config, source, remote, video, painter, progress, frameRequest, sender, receiver, baselineSource, baselineGain;
  const oscillators = [], phaseChanges = [], markers = [], pending = [], frames = [], rtp = [];
  const seen = new Set();
  let invalidFrames = 0, unmatched = 0, stopped = false, level = 1, sourceStart, maxCallbackLateness = 0;
  let outcome = 'setup_failed', setupFailure = '';
  let recordRtp = false, rtpBusy = false, rtpErrors = 0;
  const mediaSamples = [];
  const videoPlayout = [];
  let mediaCodecs, mediaErrors = 0;
  let sourceRebindProof = {performed:false};
  const receiverStreamIds = new Set();
  const iceExchange = {sender:{added:0, rejected:0, errors:[]}, receiver:{added:0, rejected:0, errors:[]}};
  const control = new URLSearchParams(location.search).get('control') ?? 'none';
  const audioFault = new URLSearchParams(location.search).get('audio_fault') ?? 'none';
  const sourceRebind = new URLSearchParams(location.search).get('source_rebind') ?? '0';
  const splitSync = new URLSearchParams(location.search).get('split_sync') === '1';
  const round = value => Math.round(value * 10) / 10;
  const phaseAt = time => phaseChanges.findLast(phase => phase[1] <= time)?.[0] ?? 'clean';
  try {
    check(location.hostname === '127.0.0.1', 'Loopback fixture required');
    check(['none', 'audio200', 'video200'].includes(control), 'Unknown calibration control');
    check(['0', '1'].includes(sourceRebind) && !(elementBaseline && sourceRebind === '1'), 'Unknown source rebind control');
    check(['none', 'encrypt', 'decrypt'].includes(audioFault) &&
      (encrypted || audioFault === 'none'), 'Unknown audio crypto fault');
    result.textContent = 'Preparing real WebRTC and the product audio graph';
    const response = await bounded(fetch('/turn.json'), 'lab configuration');
    check(response.ok, 'Lab configuration rejected');
    config = await response.json();
    check(Number.isInteger(config.marker_seconds), 'Marker lab required');
    check(sourceRebind !== '1' || config.media_payload_types, 'Source rebind requires single-stream counters');
    check(!splitSync || (config.impaired_media === 'video' && sourceRebind === '0' && !elementBaseline),
      'Split sync requires the video-only gain control');
    if (config.media_payload_types) document.querySelector('#media-scope-summary').textContent =
      `Network scope: ${config.impaired_media}; payload types: ${config.media_payload_types.join(',')}; ` +
      (config.network_clean_only ? 'clean control' : config.delay_then_pause
        ? '150 ms delay / immediate 12 s outage' : '150 ms delay / 2% loss / 12 s outage');
    const requestedRtp = new URLSearchParams(location.search).get('rtp') === '1';
    check(!requestedRtp || config.marker_seconds <= 300, 'RTP diagnostics require at most 300 seconds');
    recordRtp = requestedRtp;
    await bounded(sourceReady, 'source audio activation');
    await bounded(sinkReady, 'receiver worklet');
    if (encrypted) {
      check(e2ee, 'SDK encryption bridge unavailable');
      await bounded(e2ee.initialize(), 'SDK encryption keys');
    }
    check(typeof receivingContext.getOutputTimestamp === 'function', 'Output clock unavailable');
    const destination = sourceContext.createMediaStreamDestination();
    const toneGains = [...lowTones, ...highTones].map(frequency => {
      const oscillator = sourceContext.createOscillator(), gain = sourceContext.createGain();
      oscillator.frequency.value = frequency; gain.gain.value = 0;
      oscillator.connect(gain); gain.connect(destination); oscillator.start();
      oscillators.push(oscillator);
      return gain.gain;
    });
    const canvas = document.createElement('canvas'); canvas.width = 640; canvas.height = 360;
    const drawing = canvas.getContext('2d');
    function paint() {
      const milliseconds = Math.max(0, Math.floor(sourceContext.currentTime * 1000) - (control === 'video200' ? 200 : 0));
      drawing.fillStyle = `hsl(${milliseconds % 360} 70% 45%)`;
      drawing.fillRect(0, 0, 640, 360);
      for (let i = 0; i < 12; i++) {
        drawing.fillStyle = `hsl(${(milliseconds / 3 + i * 29) % 360} 85% 65%)`;
        drawing.fillRect((milliseconds / 5 + i * 71) % 640, 40 + i * 24, 80, 18);
      }
      stampBits(milliseconds).forEach((bit, i) => {
        drawing.fillStyle = bit ? '#fff' : '#000';
        drawing.fillRect(i * 12, 0, 12, 24);
      });
    }
    paint(); painter = setInterval(paint, 50);
    source = canvas.captureStream(20);
    source.addTrack(destination.stream.getAudioTracks()[0]);
    if (sfu) {
      ({sender, receiver, remote} = await connectSfu(source, splitSync));
    } else {
      const rtcConfig = {iceTransportPolicy:'relay', iceServers:config.iceServers,
        ...(encrypted ? {encodedInsertableStreams:true} : {})};
      sender = new RTCPeerConnection(rtcConfig);
      receiver = new RTCPeerConnection({...rtcConfig, iceServers:config.peer_ice_servers ?? config.iceServers});
      for (const [name, peer] of [['sender', sender], ['receiver', receiver]]) {
        peer.onicecandidateerror = event => {
          if (iceExchange[name].errors.length < 8 && Number.isInteger(event.errorCode) && event.errorCode >= 300 && event.errorCode <= 799)
            iceExchange[name].errors.push(event.errorCode);
        };
      }
      async function addCandidate(name, peer, candidate) {
        try { await peer.addIceCandidate(candidate); iceExchange[name].added++; }
        catch (_) { iceExchange[name].rejected++; }
      }
      const candidatesForSender = [], candidatesForReceiver = [];
      sender.onicecandidate = event => {
        if (stopped || !event.candidate) return;
        if (receiver.remoteDescription) void addCandidate('receiver', receiver, event.candidate);
        else candidatesForReceiver.push(event.candidate);
      };
      receiver.onicecandidate = event => {
        if (stopped || !event.candidate) return;
        if (sender.remoteDescription) void addCandidate('sender', sender, event.candidate);
        else candidatesForSender.push(event.candidate);
      };
      if (splitSync) remote = new MediaStream();
      receiver.ontrack = event => {
        if (splitSync) {
          remote.addTrack(event.track);
          for (const stream of event.streams) receiverStreamIds.add(stream.id);
        } else {
          remote = event.streams[0];
        }
      };
      for (const track of source.getTracks()) {
        const rtpSender = sender.addTrack(track, splitSync ? new MediaStream([track]) : source);
        if (encrypted || config.media_payload_types) {
          if (track.kind === 'video') {
            const codecs = RTCRtpSender.getCapabilities('video').codecs.filter(row =>
              row.mimeType === 'video/VP8' || (config.media_payload_types && row.mimeType === 'video/rtx'));
            check(codecs.length > 0, 'VP8 control unavailable');
            sender.getTransceivers().find(row => row.sender === rtpSender).setCodecPreferences(codecs);
          }
          if (encrypted) await bounded(e2ee.prepareSender(rtpSender), 'SDK sender encryption');
        }
      }
      await bounded(sender.setLocalDescription(await sender.createOffer()), 'sender description');
      let offer = sender.localDescription;
      if (encrypted) {
        // The worker indexes cryptors by track ID; emulate a separate receiver.
        let sdp = offer.sdp;
        for (const track of source.getTracks()) {
          check(/^[a-zA-Z0-9-]+$/.test(track.id), 'Unexpected synthetic track identifier');
          const next = sdp.replaceAll(new RegExp(` ${track.id}(?=\\r?\\n)`, 'g'), ` receiver-${track.id}`);
          check(next !== sdp, 'Offer track msid missing');
          sdp = next;
        }
        offer = {type:offer.type, sdp};
      }
      await bounded(receiver.setRemoteDescription(offer), 'receiver description');
      if (encrypted) {
        const receivers = receiver.getReceivers();
        check(receivers.length === 2, 'Expected audio and video receivers');
        for (const rtpReceiver of receivers) {
          check(!source.getTracks().some(track => track.id === rtpReceiver.track.id), 'Cryptor track collision');
          await bounded(e2ee.prepareReceiver(rtpReceiver), 'SDK receiver encryption');
        }
      }
      for (const candidate of candidatesForReceiver) await addCandidate('receiver', receiver, candidate);
      await bounded(receiver.setLocalDescription(await receiver.createAnswer()), 'receiver answer');
      await bounded(sender.setRemoteDescription(receiver.localDescription), 'sender answer');
      for (const candidate of candidatesForSender) await addCandidate('sender', sender, candidate);
      await waitFor(() => remote?.getAudioTracks().length === 1 && remote?.getVideoTracks().length === 1);
      check(!splitSync || receiverStreamIds.size === 2, 'Expected separate receiver sync groups');
    }
    video = document.createElement('video'); video.playsInline = true;
    video.srcObject = remote; document.querySelector('#view').append(video);
    if (elementBaseline) {
      if (sfu) {
        for (const element of document.querySelectorAll('audio[id^="livekit_audio_"]')) {
          element.muted = true;
        }
      }
      // Redirect element audio before play() so the control cannot reach hardware.
      baselineSource = receivingContext.createMediaElementSource(video);
      baselineGain = receivingContext.createGain();
      baselineSource.connect(baselineGain); baselineGain.connect(receivingContext.destination);
    } else {
      await VoiceChatAudio.setCallVolume(remote.getAudioTracks()[0].id, 1);
    }
    check((elementBaseline || video.muted) && graphs.size === 1, 'Expected one silent instrumented gain path');
    await bounded(video.play(), 'video playout');
    check(iceExchange.sender.rejected === 0 && iceExchange.receiver.rejected === 0, 'ICE candidate rejected');
    check(typeof video.requestVideoFrameCallback === 'function', 'Video presentation clock unavailable');
    await waitFor(() => video.videoWidth > 0);
    let reports, pair;
    const statsDeadline = performance.now() + 15000;
    do {
      reports = await receiver.getStats();
      const transport = [...reports.values()].find(report => report.type === 'transport' && report.selectedCandidatePairId);
      pair = reports.get(transport?.selectedCandidatePairId);
      if (pair || performance.now() >= statsDeadline) break;
      await delay(50);
    } while (true);
    check(pair && (sfu || reports.get(pair.localCandidateId)?.candidateType === 'relay'),
      'Expected selected media route');
    if (config.media_payload_types) {
      const codecs = receiver.getReceivers().find(row => row.track.kind === 'video').getParameters().codecs;
      const deadline = performance.now() + 15000;
      do {
        if (sfu) {
          const vp8 = codecs.find(row => row.mimeType?.toLowerCase() === 'video/vp8');
          config.media_payload_types = [vp8.payloadType, ...codecs.filter(row =>
            row.mimeType?.toLowerCase() === 'video/rtx' &&
            row.sdpFmtpLine === 'apt=' + vp8.payloadType).map(row => row.payloadType)];
        }
        mediaCodecs = mediaScopeCodecs(reports, codecs, config.media_payload_types, config.impaired_media);
        if (mediaCodecs.audio_payload_type !== null && mediaCodecs.video_payload_type !== null) break;
        await delay(50);
        reports = await receiver.getStats();
      } while (performance.now() < deadline);
      check(mediaCodecs.valid, 'Media payload classifier does not match negotiated codecs');
    }
    const sample = document.createElement('canvas'); sample.width = 640; sample.height = 24;
    const reader = sample.getContext('2d', {willReadFrequently:true});

    const inboundFields = ['packetsReceived', 'packetsLost', 'jitter', 'jitterBufferDelay',
      'jitterBufferEmittedCount', 'jitterBufferTargetDelay', 'concealedSamples', 'totalSamplesReceived',
      'insertedSamplesForDeceleration', 'removedSamplesForAcceleration', 'framesDecoded', 'framesDropped',
      'totalDecodeTime', 'totalProcessingDelay'];
    const outboundFields = ['framesEncoded', 'framesSent', 'totalEncodeTime',
      'frameWidth', 'frameHeight', 'framesPerSecond'];
    const values = (report, fields) => fields.map(field =>
      Number.isFinite(report?.[field]) ? report[field] : null);
    async function sampleRtp(id, stampDelta) {
      if (!recordRtp || stopped || rtpBusy || rtp.length >= 150) return;
      rtpBusy = true;
      const started = performance.now();
      try {
        const [received, sent] = await Promise.all([receiver.getStats(), sender.getStats()]);
        if (stopped) return;
        const inbound = kind => [...received.values()].find(row => row.type === 'inbound-rtp' && row.kind === kind);
        const outbound = [...sent.values()].find(row => row.type === 'outbound-rtp' && row.kind === 'video');
        const transport = [...sent.values()].find(row => row.type === 'transport' && row.selectedCandidatePairId);
        const pair = sent.get(transport?.selectedCandidatePairId);
        const reason = outbound?.qualityLimitationReason;
        rtp.push([id, round(started), round(performance.now() - started),
          values(inbound('audio'), inboundFields), values(inbound('video'), inboundFields),
          values(outbound, outboundFields), values(pair, ['currentRoundTripTime', 'availableOutgoingBitrate']),
          ['none', 'cpu', 'bandwidth', 'other'].includes(reason) ? reason : null, round(stampDelta)]);
      } catch (_) { if (!stopped) rtpErrors++; }
      finally { rtpBusy = false; }
    }

    function matchMarkers() {
      for (let i = pending.length - 1; i >= 0; i--) {
        const marker = pending[i];
        if (frames.at(-1)?.sourceMs >= marker.sourceMs + 25) {
          const closest = frames.reduce((best, frame) =>
            Math.abs(frame.sourceMs - marker.sourceMs) < Math.abs(best.sourceMs - marker.sourceMs) ? frame : best);
          if (Math.abs(closest.sourceMs - marker.sourceMs) <= 80) {
            const videoTime = closest.displayMs + marker.sourceMs - closest.sourceMs;
            markers.push([marker.id, phaseAt(marker.audioMs), round(marker.audioMs - videoTime),
              round(marker.audioMs), round(videoTime), round(marker.sourceMs), marker.level]);
            if (recordRtp && videoPlayout.length < 150) videoPlayout.push(videoPlayoutSample(marker.id, closest));
            void sampleRtp(marker.id, closest.sourceMs - marker.sourceMs);
            pending.splice(i, 1);
            continue;
          }
        }
        if (performance.now() - marker.receivedAt > 5000) { unmatched++; pending.splice(i, 1); }
      }
    }
    function frame(now, metadata) {
      if (stopped) return;
      maxCallbackLateness = Math.max(maxCallbackLateness, now - metadata.expectedDisplayTime);
      reader.drawImage(video, 0, 0, 640, 360);
      const pixels = reader.getImageData(0, 0, 640, 24).data;
      const bits = Array.from({length:48}, (_, i) => pixels[(12 * 640 + i * 12 + 6) * 4] >= 128 ? 1 : 0);
      const sourceMs = readStamp(bits);
      if (sourceMs === null || sourceMs > sourceContext.currentTime * 1000 + 100) invalidFrames++;
      else if (sourceMs !== frames.at(-1)?.sourceMs) {
        frames.push({sourceMs, displayMs:metadata.expectedDisplayTime, callbackMs:now,
          captureTime:metadata.captureTime, receiveTime:metadata.receiveTime, processingDuration:metadata.processingDuration});
        while (frames.length > 600) frames.shift();
      }
      matchMarkers();
      frameRequest = video.requestVideoFrameCallback(frame);
    }
    frameRequest = video.requestVideoFrameCallback(frame);
    sink.port.onmessage = event => {
      if (stopped) return;
      const marker = event.data;
      if (seen.has(marker.id) || sourceStart === undefined || marker.id >= Math.ceil(config.marker_seconds / 2)) return;
      seen.add(marker.id);
      const timestamp = receivingContext.getOutputTimestamp();
      if (!timestamp.contextTime || !Number.isFinite(timestamp.performanceTime)) { unmatched++; return; }
      pending.push({id:marker.id, sourceMs:(sourceStart + marker.id * 2) * 1000,
        audioMs:timestamp.performanceTime + (marker.time - timestamp.contextTime) * 1000,
        receivedAt:performance.now(), level});
      matchMarkers();
    };
    sourceStart = sourceContext.currentTime + 2;
    progress = setInterval(() => {
      const last = markers.at(-1);
      document.querySelector('#summary').textContent = `Decoded markers: ${markers.length}; ` +
        `latest offset: ${last?.[2] ?? 'pending'} ms; unmatched: ${unmatched}`;
    }, 5000);
    for (let id = 0; id < Math.ceil(config.marker_seconds / 2); id++) {
      markerDigits(id).forEach((digit, index) => {
        const start = sourceStart + id * 2 + index * .16 + (control === 'audio200' ? .2 : 0);
        for (const tone of [digit >> 2, 4 + (digit & 3)]) {
          const gain = toneGains[tone];
          gain.setValueAtTime(0, start); gain.linearRampToValueAtTime(.12, start + .005);
          gain.setValueAtTime(.12, start + .095); gain.linearRampToValueAtTime(0, start + .1);
        }
      });
    }
    async function profile(name, gain) {
      const response = await fetch('/profile', {method:'POST',
        headers:{'Content-Type':'application/json','X-Lab-Key':config.lab_key}, body:JSON.stringify({profile:name, ...(sfu ? {payload_types:config.media_payload_types} : {})})});
      check(response.ok, 'Network profile rejected');
      if (name === 'delay' && audioFault !== 'none') {
        await bounded(e2ee.armAudioFault(audioFault), 'audio crypto fault');
      }
      phaseChanges.push([config.network_clean_only ? 'clean' : name, performance.now()]);
      level = gain;
      if (elementBaseline) baselineGain.gain.setTargetAtTime(gain, receivingContext.currentTime, .02);
      else await VoiceChatAudio.setCallVolume(remote.getAudioTracks()[0].id, gain);
      check((elementBaseline || video.muted) && graphs.size === 1, 'Duplicate or missing audio path');
    }
    const first = config.marker_seconds >= 600 ? Math.floor(config.marker_seconds / 6) :
      config.marker_seconds >= 90 ? 20 : 15;
    const impaired = config.marker_seconds >= 90 ? 15 : 10;
    const offlineSeconds = config.media_payload_types ? 12 : 3;
    const phases = [['clean', first, 1],
      ...(config.delay_then_pause ? [['delay', impaired * 2, .5]] : [['delay', impaired, .5], ['loss', impaired, 2]]),
      ['offline', offlineSeconds, 1], ['clean', config.marker_seconds - first - impaired * 2 - offlineSeconds, 1]];
    for (const [name, seconds, gain] of phases) {
      await profile(name, gain);
      result.textContent = `RUNNING: ${config.network_clean_only ? 'clean network / ' : ''}${name}, gain ${gain * 100}%, ${markers.length} decoded markers`;
      if (config.media_payload_types) {
        for (let second = 0; second < seconds; second++) {
          if (name === 'clean' && phaseChanges.length > 1 && second === 20 && sourceRebind === '1') {
            check(rebindSource && !sourceRebindProof.performed && video.muted, 'Source rebind unavailable');
            sourceRebindProof = rebindSource();
            check(sourceRebindProof.same_audio_track && video.muted && graphs.size === 1, 'Source rebind changed media ownership');
          }
          const started = performance.now();
          try {
            const reports = await bounded(receiver.getStats(), 'media scope counters');
            mediaSamples.push(mediaScopeSample(reports, name, round(performance.now())));
          } catch (_) { mediaErrors++; }
          await delay(Math.max(0, 1000 - (performance.now() - started)));
        }
      } else await delay(seconds * 1000);
    }
    await delay(1000);
    matchMarkers();
    const baseline = markers.filter(row => row[3] < phaseChanges[1][1]);
    const recovered = markers.filter(row => row[3] >= phaseChanges.at(-1)[1] + 5000);
    const expectedRecovered = Math.max(1, Math.floor((phases.at(-1)[1] - 7) / 2));
    const enough = baseline.length >= 5 && recovered.length >= Math.max(5, expectedRecovered * .7);
    outcome = !enough ? 'insufficient_markers' :
      [...baseline, ...recovered].every(row => Math.abs(row[2]) <= 80) ? 'pass' : 'budget_exceeded';
    if (config.media_payload_types) {
      check(mediaErrors === 0 && singleStreamOutageProof(mediaSamples, config.network_clean_only, config.impaired_media).valid,
        'Single-stream outage not proven while other media remains live');
    }
  } catch (error) {
    outcome = 'setup_failed';
    // Browser errors can contain credential-bearing URLs; retain only the category.
    setupFailure = error instanceof FixtureError ? error.message : error.name;
    result.textContent = `FAIL: setup (${setupFailure})`;
  } finally {
    stopped = true;
    const transportResult = document.createElement('pre');
    transportResult.id = 'transport-result';
    transportResult.textContent = 'TRANSPORT_SETUP_PROOF ' + JSON.stringify({
      candidate_exchange:iceExchange,
      sender:await transportDiagnostics(sender), receiver:await transportDiagnostics(receiver),
    });
    document.body.append(transportResult);
    const sourceResult = document.createElement('pre');
    sourceResult.id = 'source-rebind-result';
    sourceResult.textContent = 'SOURCE_REBIND_PROOF ' + JSON.stringify(sourceRebindProof);
    document.body.append(sourceResult);
    const syncResult = document.createElement('pre');
    syncResult.textContent = 'SYNC_GROUP_PROOF ' + JSON.stringify({
      split_requested:splitSync, distinct_received_streams:splitSync ? receiverStreamIds.size : null,
    });
    document.body.append(syncResult);
    if (recordRtp) {
      const playoutResult = document.createElement('pre');
      playoutResult.id = 'video-playout-result';
      playoutResult.textContent = 'VIDEO_PLAYOUT_PROOF ' + JSON.stringify({schema:1,
        physical_latency_measured:false, samples:videoPlayout.sort((a, b) => a[0] - b[0])});
      document.body.append(playoutResult);
    }
    if (config?.media_payload_types) {
      const outage = singleStreamOutageProof(mediaSamples, config.network_clean_only, config.impaired_media);
      document.querySelector('#media-scope-summary').textContent +=
        `; scope proof: ${outage.valid ? 'PASS' : 'FAIL'}; audio packets +${outage.audio_packets}, ` +
        `video packets +${outage.video_packets}; sample errors: ${mediaErrors}`;
      const mediaResult = document.createElement('pre');
      mediaResult.id = 'media-scope-result';
      mediaResult.textContent = 'MEDIA_SCOPE_PROOF ' + JSON.stringify({codecs:mediaCodecs ?? null,
        outage, errors:mediaErrors,
        // time, phase, audio then video packets/delay/target/emitted count.
        samples:mediaSamples});
      document.body.append(mediaResult);
    }
    if (encrypted && e2ee) {
      const encryptionResult = document.createElement('pre');
      encryptionResult.id = 'encryption-result';
      try {
        encryptionResult.textContent = 'E2EE_MARKER_PROOF ' + JSON.stringify(await e2ee.summary());
      } catch (_) { encryptionResult.textContent = 'E2EE_MARKER_PROOF incomplete'; }
      document.body.append(encryptionResult);
    }
    clearInterval(painter);
    clearInterval(progress);
    if (frameRequest !== undefined) video?.cancelVideoFrameCallback(frameRequest);
    for (const oscillator of oscillators) oscillator.stop();
    for (const track of source?.getTracks() ?? []) track.stop();
    for (const track of remote?.getTracks() ?? []) track.stop();
    if (sfu) {
      const proof = document.createElement('pre');
      proof.textContent = 'SFU_E2EE_PROOF ' + JSON.stringify({
        missing_key_blocked:sfu.missingKeyBlocked(), split_sync:splitSync, ...sfu.diagnostics(),
        decrypted_audio_video_markers:markers.length,
      });
      document.body.append(proof);
      await sfu.dispose();
    } else {
      sender?.close(); receiver?.close();
    }
    if (encrypted && e2ee) {
      try { await e2ee.dispose(); }
      catch (_) { outcome = 'setup_failed'; setupFailure ||= 'SDK encryption cleanup'; }
    }
    if (remote) VoiceChatAudio.forgetCallVolume(remote.getAudioTracks()[0].id);
    video?.pause(); video?.remove();
    baselineSource?.disconnect(); baselineGain?.disconnect();
    const baseLatency = receivingContext?.baseLatency, outputLatency = receivingContext?.outputLatency;
    await Promise.allSettled([sourceContext.close(), receivingContext?.close()]);
    if (config) {
      const baseline = markers.filter(row => row[3] < (phaseChanges[1]?.[1] ?? 0));
      const recovered = markers.filter(row => row[3] >= (phaseChanges.at(-1)?.[1] ?? Infinity) + 5000);
      const proof = {schema:2, outcome, control, duration_seconds:config.marker_seconds,
        playout_path:playoutPath,
        rtp_diagnostics_requested:recordRtp, rtp_diagnostics:rtp, rtp_diagnostics_errors:rtpErrors,
        markers:markers.sort((a, b) => a[0] - b[0]), phase_changes:phaseChanges,
        unmatched_markers:unmatched + pending.length, invalid_video_frames:invalidFrames,
        audio_base_latency_ms:Number.isFinite(baseLatency) ? round(baseLatency * 1000) : null,
        audio_output_latency_ms:Number.isFinite(outputLatency) ? round(outputLatency * 1000) : null,
        max_video_callback_lateness_ms:round(maxCallbackLateness),
        baseline_p95_abs_ms:percentile95(baseline.map(row => row[2])),
        recovered_p95_abs_ms:percentile95(recovered.map(row => row[2])),
        physical_lip_sync_measured:false, media_saved:false, microphone_used:false, test_sink_silent:true};
      try {
        await fetch('/profile', {method:'POST', headers:{'Content-Type':'application/json','X-Lab-Key':config.lab_key}, body:JSON.stringify({profile:'clean', ...(sfu ? {payload_types:config.media_payload_types} : {})})});
        const response = await fetch('/marker-result', {method:'POST',
          headers:{'Content-Type':'application/json','X-Lab-Key':config.lab_key}, body:JSON.stringify(proof)});
        check(response.ok, 'Marker report rejected');
        document.querySelector('#summary').textContent = `Outcome: ${outcome}; path: ${playoutPath}; control: ${control}; ` +
          `markers: ${markers.length}; baseline p95: ${proof.baseline_p95_abs_ms} ms; ` +
          `recovery p95: ${proof.recovered_p95_abs_ms} ms; RTP snapshots: ${rtp.length}`;
        result.textContent = (setupFailure ? `Setup: ${setupFailure}\n` : '') +
          `${outcome === 'pass' ? 'PASS' : 'FAIL'} AV_MARKER_PROOF ` + JSON.stringify(proof);
      } catch (_) { result.textContent = 'FAIL: fixture could not save the marker report'; }
    }
  }
};
