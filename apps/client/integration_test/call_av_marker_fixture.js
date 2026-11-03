import {lowTones, highTones, markerDigits, stampBits, readStamp} from './call_av_marker.js';
import {transportDiagnostics} from './call_transport_diagnostics.js';

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
};
await import('./media_audio.js');
// Optional lab-only encryption uses the SDK factory and exact compiled worker.
const encrypted = new URLSearchParams(location.search).get('e2ee') === '1';
if (encrypted) await import('./call_av_marker_e2ee.dart.js');
const e2ee = encrypted ? window.VoiceChatMarkerE2EE : null;

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
  const control = new URLSearchParams(location.search).get('control') ?? 'none';
  const audioFault = new URLSearchParams(location.search).get('audio_fault') ?? 'none';
  const round = value => Math.round(value * 10) / 10;
  const phaseAt = time => phaseChanges.findLast(phase => phase[1] <= time)?.[0] ?? 'clean';
  try {
    check(location.hostname === '127.0.0.1', 'Loopback fixture required');
    check(['none', 'audio200', 'video200'].includes(control), 'Unknown calibration control');
    check(['none', 'encrypt', 'decrypt'].includes(audioFault) &&
      (encrypted || audioFault === 'none'), 'Unknown audio crypto fault');
    result.textContent = 'Preparing real WebRTC and the product audio graph';
    const response = await bounded(fetch('/turn.json'), 'lab configuration');
    check(response.ok, 'Lab configuration rejected');
    config = await response.json();
    check(Number.isInteger(config.marker_seconds), 'Marker lab required');
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
    const rtcConfig = {iceTransportPolicy:'relay', iceServers:config.iceServers,
      ...(encrypted ? {encodedInsertableStreams:true} : {})};
    sender = new RTCPeerConnection(rtcConfig); receiver = new RTCPeerConnection(rtcConfig);
    const candidatesForSender = [], candidatesForReceiver = [];
    sender.onicecandidate = event => {
      if (stopped || !event.candidate) return;
      if (receiver.remoteDescription) void receiver.addIceCandidate(event.candidate);
      else candidatesForReceiver.push(event.candidate);
    };
    receiver.onicecandidate = event => {
      if (stopped || !event.candidate) return;
      if (sender.remoteDescription) void sender.addIceCandidate(event.candidate);
      else candidatesForSender.push(event.candidate);
    };
    receiver.ontrack = event => { remote = event.streams[0]; };
    for (const track of source.getTracks()) {
      const rtpSender = sender.addTrack(track, source);
      if (encrypted) {
        if (track.kind === 'video') {
          const codecs = RTCRtpSender.getCapabilities('video').codecs.filter(row => row.mimeType === 'video/VP8');
          check(codecs.length > 0, 'VP8 control unavailable');
          sender.getTransceivers().find(row => row.sender === rtpSender).setCodecPreferences(codecs);
        }
        await bounded(e2ee.prepareSender(rtpSender), 'SDK sender encryption');
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
    for (const candidate of candidatesForReceiver) await receiver.addIceCandidate(candidate);
    await bounded(receiver.setLocalDescription(await receiver.createAnswer()), 'receiver answer');
    await bounded(sender.setRemoteDescription(receiver.localDescription), 'sender answer');
    for (const candidate of candidatesForSender) await sender.addIceCandidate(candidate);
    await waitFor(() => remote?.getAudioTracks().length === 1 && remote?.getVideoTracks().length === 1);
    video = document.createElement('video'); video.playsInline = true;
    video.srcObject = remote; document.querySelector('#view').append(video);
    if (elementBaseline) {
      // Redirect element audio before play() so the control cannot reach hardware.
      baselineSource = receivingContext.createMediaElementSource(video);
      baselineGain = receivingContext.createGain();
      baselineSource.connect(baselineGain); baselineGain.connect(receivingContext.destination);
    } else {
      await VoiceChatAudio.setCallVolume(remote.getAudioTracks()[0].id, 1);
    }
    check((elementBaseline || video.muted) && graphs.size === 1, 'Expected one silent instrumented gain path');
    await bounded(video.play(), 'video playout');
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
    check(pair && reports.get(pair.localCandidateId)?.candidateType === 'relay', 'Expected selected TURN relay');
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
        frames.push({sourceMs, displayMs:metadata.expectedDisplayTime});
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
        headers:{'Content-Type':'application/json','X-Lab-Key':config.lab_key}, body:JSON.stringify({profile:name})});
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
    const phases = [['clean', first, 1], ['delay', impaired, .5], ['loss', impaired, 2],
      ['offline', 3, 1], ['clean', config.marker_seconds - first - impaired * 2 - 3, 1]];
    for (const [name, seconds, gain] of phases) {
      await profile(name, gain);
      result.textContent = `RUNNING: ${config.network_clean_only ? 'clean network / ' : ''}${name}, gain ${gain * 100}%, ${markers.length} decoded markers`;
      await delay(seconds * 1000);
    }
    await delay(1000);
    matchMarkers();
    const baseline = markers.filter(row => row[3] < phaseChanges[1][1]);
    const recovered = markers.filter(row => row[3] >= phaseChanges.at(-1)[1] + 5000);
    const expectedRecovered = Math.max(1, Math.floor((phases.at(-1)[1] - 7) / 2));
    const enough = baseline.length >= 5 && recovered.length >= Math.max(5, expectedRecovered * .7);
    outcome = !enough ? 'insufficient_markers' :
      [...baseline, ...recovered].every(row => Math.abs(row[2]) <= 80) ? 'pass' : 'budget_exceeded';
  } catch (error) {
    // Browser errors can contain credential-bearing URLs; retain only the category.
    setupFailure = error instanceof FixtureError ? error.message : error.name;
    result.textContent = `FAIL: setup (${setupFailure})`;
  } finally {
    stopped = true;
    const transportResult = document.createElement('pre');
    transportResult.id = 'transport-result';
    transportResult.textContent = 'TRANSPORT_SETUP_PROOF ' + JSON.stringify({
      sender:await transportDiagnostics(sender), receiver:await transportDiagnostics(receiver),
    });
    document.body.append(transportResult);
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
    sender?.close(); receiver?.close();
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
        await fetch('/profile', {method:'POST', headers:{'Content-Type':'application/json','X-Lab-Key':config.lab_key}, body:'{"profile":"clean"}'});
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
