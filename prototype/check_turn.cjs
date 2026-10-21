// Local Synapse/Coturn check; credentials stay in memory and the session is revoked.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');

(async () => {
  const account = JSON.parse(fs.readFileSync(path.join(__dirname, '../.prototype/accounts.json'))).alice;
  const base = 'http://localhost:8008/_matrix/client/v3/';
  let token, browser;
  try {
    let response = await fetch(base + 'login', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({type: 'm.login.password', identifier: {type: 'm.id.user', user: account.username}, password: account.password}),
    });
    assert(response.ok, 'Test login failed');
    token = (await response.json()).access_token;
    response = await fetch(base + 'voip/turnServer', {headers: {Authorization: 'Bearer ' + token}});
    assert(response.ok, 'TURN credentials unavailable');
    const turn = await response.json();
    browser = await chromium.launch({executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});
    const page = await browser.newPage();
    await page.goto('http://localhost:7357/favicon.png');
    const result = await page.evaluate(async turn => {
      const config = {iceTransportPolicy: 'relay', iceServers: [{urls: turn.uris, username: turn.username, credential: turn.password}]};
      const a = new RTCPeerConnection(config), b = new RTCPeerConnection(config);
      const result = {relay: 0, errors: [], echo: false};
      const timeout = (ms, value) => new Promise(resolve => setTimeout(() => resolve(value), ms));
      for (const peer of [a, b]) {
        peer.onicecandidate = event => { if (event.candidate?.type === 'relay') result.relay++; };
        peer.onicecandidateerror = event => result.errors.push(event.errorCode);
      }
      const channel = a.createDataChannel('test');
      b.ondatachannel = event => { event.channel.onmessage = message => event.channel.send(message.data); };
      const gather = peer => peer.iceGatheringState === 'complete' ? Promise.resolve() : Promise.race([
        new Promise(resolve => { peer.onicegatheringstatechange = () => { if (peer.iceGatheringState === 'complete') resolve(); }; }),
        timeout(10000),
      ]);
      try {
        await a.setLocalDescription(await a.createOffer()); await gather(a);
        await b.setRemoteDescription(a.localDescription);
        await b.setLocalDescription(await b.createAnswer()); await gather(b);
        await a.setRemoteDescription(b.localDescription);
        const opened = await Promise.race([new Promise(resolve => { channel.onopen = () => resolve(true); }), timeout(10000, false)]);
        if (opened) {
          const echo = new Promise(resolve => { channel.onmessage = event => resolve(event.data === 'check'); });
          channel.send('check');
          result.echo = await Promise.race([echo, timeout(3000, false)]);
        }
        return result;
      } finally { a.close(); b.close(); }
    }, turn);
    assert(result.relay > 0 && result.echo, 'TURN relay exchange failed');
    console.log('PASS: two WebRTC peers exchange data through TURN');
  } finally {
    await browser?.close();
    if (token) await fetch(base + 'logout', {method: 'POST', headers: {Authorization: 'Bearer ' + token, 'Content-Type': 'application/json'}, body: '{}'});
  }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
