// Synthetic oscillator and data only, in a fresh browser. No microphone/profile access.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const http = require('node:http');
const execFile = require('node:util').promisify(require('node:child_process').execFile);
const {chromium} = require('playwright');

(async () => {
  const fixture = JSON.parse(process.env.ROUTE_TURN_FIXTURE);
  const credentials = role => {
    assert.match(fixture.ports[role], /^127\.0\.0\.1:[0-9]+$/);
    const username = `${Math.floor(Date.now()/1000)+300}:route-probe`;
    return {urls: [`turn:${fixture.ports[role]}?transport=tcp`], username,
      credential: crypto.createHmac('sha1', fixture.secrets[role]).update(username).digest('base64')};
  };
  const server = http.createServer((req, res) => res.end('<!doctype html><title>Local TURN probe</title>'));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch({executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true,
      args: ['--autoplay-policy=no-user-gesture-required']});
    const page = await browser.newPage();
    await page.exposeFunction('stopFirstRelay', () => execFile('docker', ['compose', '-f', fixture.compose, 'stop', '-t', '1', 'b']));
    await page.goto(`http://127.0.0.1:${server.address().port}`);
    const result = await page.evaluate(async ice => {
      const peers = [new RTCPeerConnection({iceTransportPolicy:'relay', iceServers:[ice.b]}),
        new RTCPeerConnection({iceTransportPolicy:'relay', iceServers:[ice.b]})];
      const audio = new AudioContext();
      const tone = audio.createOscillator(), source = audio.createMediaStreamDestination();
      tone.frequency.value = 440; tone.connect(source); tone.start(); await audio.resume();
      const analyser = audio.createAnalyser(); analyser.fftSize = 256;
      let receiver, remoteChannel;
      peers[1].ontrack = event => {
        const stream = new MediaStream([event.track]);
        const player = document.createElement('audio'); player.autoplay = true; player.volume = 0;
        player.srcObject = stream; document.body.append(player); player.play();
        receiver = audio.createMediaStreamSource(stream);
        receiver.connect(analyser);
        // Keep the audio graph running without producing sound on the machine.
        const mute = audio.createGain(); mute.gain.value = 0; analyser.connect(mute); mute.connect(audio.destination);
      };
      peers[0].addTrack(source.stream.getAudioTracks()[0], source.stream);
      peers[1].ondatachannel = event => { remoteChannel = event.channel; remoteChannel.onmessage = message => remoteChannel.send(message.data); };
      const channel = peers[0].createDataChannel('route-test');
      const wait = async (check, ms = 12000) => {
        const until = performance.now() + ms;
        while (performance.now() < until) { if (await check()) return; await new Promise(r => setTimeout(r, 50)); }
        throw new Error('TURN proof deadline');
      };
      const localDescription = async (peer, description) => {
        let complete = false;
        const listener = event => { if (!event.candidate) complete = true; };
        peer.addEventListener('icecandidate', listener);
        try {
          await peer.setLocalDescription(description);
          // After restart, iceGatheringState may briefly still say complete
          // from the previous generation. Wait for this generation's end event.
          await wait(() => complete);
        } finally { peer.removeEventListener('icecandidate', listener); }
      };
      const negotiate = async () => {
        await localDescription(peers[0], await peers[0].createOffer({iceRestart:true}));
        await peers[1].setRemoteDescription(peers[0].localDescription);
        await localDescription(peers[1], await peers[1].createAnswer());
        await peers[0].setRemoteDescription(peers[1].localDescription);
        await wait(() => peers.every(p => p.connectionState === 'connected'), 30000).catch(async () => {
          const details = await Promise.all(peers.map(async p => ({state:p.connectionState, ice:p.iceConnectionState, gathering:p.iceGatheringState,
            candidates:[...(await p.getStats()).values()].filter(s=>s.type==='local-candidate' || s.type==='remote-candidate').map(s=>({type:s.type,kind:s.candidateType,url:s.url,port:s.port}))})));
          throw new Error(JSON.stringify({phase:'negotiate', details}));
        });
      };
      const sample = async () => {
        await wait(() => channel.readyState === 'open');
        let echo = false;
        const value = crypto.randomUUID(); channel.onmessage = event => { echo = event.data === value; };
        channel.send(value); await wait(() => echo);
        let amplitude = 0;
        await wait(() => { const samples = new Float32Array(analyser.fftSize); analyser.getFloatTimeDomainData(samples);
          amplitude = Math.max(...samples.map(Math.abs)); return amplitude > .05; }).catch(async () => {
            const stats = [...(await peers[1].getStats()).values()].filter(s => s.type === 'inbound-rtp');
            throw new Error(JSON.stringify({phase:'decoded-audio', state:audio.state, amplitude, stats}));
          });
        const stats = await peers[0].getStats();
        const transport = [...stats.values()].find(s => s.type === 'transport' && s.selectedCandidatePairId);
        const pair = stats.get(transport?.selectedCandidatePairId);
        const local = stats.get(pair?.localCandidateId), remote = stats.get(pair?.remoteCandidateId);
        return {echo, decodedAudio: amplitude > .05, localType: local?.candidateType, remoteType: remote?.candidateType,
          relayUrl: local?.url, localPort:local?.port};
      };
      try {
        await negotiate(); const before = await sample();
        await window.stopFirstRelay();
        for (const peer of peers) peer.setConfiguration({iceTransportPolicy:'relay', iceServers:[ice.c]});
        const started = performance.now();
        peers[0].restartIce();
        await negotiate();
        await wait(async () => {
          const stats=await peers[0].getStats();
          const transport=[...stats.values()].find(s=>s.type==='transport' && s.selectedCandidatePairId);
          const candidate=stats.get(stats.get(transport?.selectedCandidatePairId)?.localCandidateId);
          return candidate?.url?.includes(ice.c.urls[0].split('?')[0]);
        }).catch(async () => {
          const candidates = [...(await peers[0].getStats()).values()].filter(s=>s.type==='local-candidate').map(s=>({type:s.candidateType, url:s.url, port:s.port}));
          throw new Error(JSON.stringify({phase:'relay-switch', candidates}));
        });
        const after = await sample();
        return {before, after, elapsedMs: Math.round(performance.now()-started), samePeerConnections:true};
      } finally { peers.forEach(p=>p.close()); source.stream.getTracks().forEach(t=>t.stop()); tone.stop(); await audio.close(); }
    }, {b:credentials('b'), c:credentials('c')});
    for (const phase of [result.before, result.after]) {
      assert.equal(phase.echo,true); assert.equal(phase.decodedAudio,true);
      assert.equal(phase.localType,'relay'); assert.equal(phase.remoteType,'relay');
    }
    assert.notEqual(result.before.relayUrl, result.after.relayUrl);
    console.log(JSON.stringify({result:'PASS', ...result}));
  } finally { await browser?.close(); await new Promise(resolve=>server.close(resolve)); }
})().catch(error=>{console.error(error.message);process.exitCode=1;});
