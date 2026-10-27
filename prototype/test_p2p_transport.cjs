// Run against the isolated release lab, never against a user's browser/profile.
// NODE_PATH=<runtime node_modules> node prototype/test_p2p_transport.cjs [--large]
const {chromium} = require('playwright');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../.prototype/p2p-lab-web');
const evidence = path.resolve(__dirname, '../.prototype/p2p-evidence');
fs.mkdirSync(evidence, {recursive:true});
(async () => {
  const server = http.createServer((req, res) => {
    let name = decodeURIComponent(req.url.split('?')[0]);
    if (name === '/p2p-test-config.json') {
      const config = fs.readFileSync(path.resolve(__dirname, '../.prototype/turnserver.conf'), 'utf8');
      const secret = config.match(/^static-auth-secret=(.+)$/m)?.[1];
      if (!secret) { res.writeHead(503).end(); return; }
      const username = `${Math.floor(Date.now()/1000)+3600}:p2p-test`;
      const credential = crypto.createHmac('sha1', secret).update(username).digest('base64');
      res.setHeader('Content-Type', 'application/json'); res.setHeader('Cache-Control','no-store');
      res.end(JSON.stringify([{urls:[`turn:127.0.0.1:${process.env.P2P_TURN_PORT || 3478}?transport=tcp`], username, credential}])); return;
    }
    if (name === '/') name = '/index.html';
    const file = path.resolve(root, '.'+name);
    if (!file.startsWith(root+'/')) { res.writeHead(403).end(); return; }
    try {
      res.setHeader('Content-Type', ({'.html':'text/html','.js':'application/javascript','.wasm':'application/wasm','.json':'application/json','.ttf':'font/ttf'})[path.extname(file)] || 'application/octet-stream');
      res.end(fs.readFileSync(file));
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const browser = await chromium.launch({executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless:true});
  const results = [];
  const heartbeats = [];
  const contexts = [], profiles = [];
  try {
    const scenarios = process.argv.includes('--large') ? [{name:'5GB-relay-storage',query:'peers=1&bytes=5000000000&relay=1&storage=1'}] : [
      {name:'four-direct',query:'peers=4&bytes=262144'},
      {name:'cancel-one',query:'peers=4&cancel=1&relay=1'},
      {name:'corrupt-one',query:'peers=4&corrupt=1&relay=1'},
      {name:'four-relay',query:'peers=4&relay=1&storage=1'},
      {name:'empty',query:'peers=1&bytes=0'},
    ];
    for (const scenario of scenarios) {
      if(process.env.P2P_CASE && process.env.P2P_CASE !== scenario.name) continue;
      if(process.env.P2P_QUERY) scenario.query=process.env.P2P_QUERY;
      let context;
      if (process.argv.includes('--large')) {
        const profile=fs.mkdtempSync(path.join(os.tmpdir(),'voicechat-p2p-test-')); profiles.push(profile);
        context=await chromium.launchPersistentContext(profile,{executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,viewport:{width:440,height:950}});
      } else { context=await browser.newContext({viewport:{width:440,height:950}}); }
      contexts.push(context);
      const page = await context.newPage();
      await page.addInitScript(() => {
        const Native = window.RTCPeerConnection;
        window.p2pDiagnostics=[];
        window.RTCPeerConnection=class extends Native {
          constructor(...args) {
            super(...args);
            const diag={states:[],candidates:0,types:[],channels:[]}; window.p2pDiagnostics.push(diag);
            this.addEventListener('connectionstatechange',()=>diag.states.push(this.connectionState));
            this.addEventListener('icecandidate',e=>{if(e.candidate){diag.candidates++;diag.types.push({type:e.candidate.type,protocol:e.candidate.protocol,unspecified:e.candidate.address==='0.0.0.0'})}});
            this.addEventListener('datachannel',e=>this.tap(e.channel,diag));
            this.diag=diag;
          }
          tap(channel, diag) {
            const value={sent:0,received:0,states:[],buffered:0};diag.channels.push(value);
            channel.addEventListener('open',()=>value.states.push('open'));
            channel.addEventListener('close',()=>value.states.push('closed'));
            channel.addEventListener('message',()=>value.received++);
            const send=channel.send.bind(channel);
            channel.send=data=>{value.sent++;const result=send(data);value.buffered=channel.bufferedAmount;return result};
          }
          createDataChannel(...args) { const channel=super.createDataChannel(...args);this.tap(channel,this.diag);return channel; }
        };
      });
      const errors=[];
      page.on('pageerror', error=>errors.push(error.message));
      const start=Date.now();
      const heartbeat=setInterval(async()=>{try{console.log(JSON.stringify({progress:scenario.name,seconds:Math.round((Date.now()-start)/1000),peers:await page.evaluate(()=>window.p2pDiagnostics)}));}catch{}},30000); heartbeats.push(heartbeat);
      await page.goto(`http://127.0.0.1:${server.address().port}/?${scenario.query}`);
      const capacity=await page.evaluate(()=>navigator.storage.estimate());
      console.log(JSON.stringify({name:scenario.name,quota:capacity.quota}));
      await page.getByRole('button',{name:'Run',exact:true}).click({timeout:60000});
      await page.getByText(/^(PASS|FAIL:)/).first().waitFor({timeout:process.argv.includes('--large')?1500000:600000});
      clearInterval(heartbeat);
      const outcome=await page.getByText(/^(PASS|FAIL:)/).first().innerText();
      await page.screenshot({path:path.join(evidence,`${scenario.name}.png`),fullPage:true});
      const result={name:scenario.name,query:scenario.query,outcome,elapsedMs:Date.now()-start,errors};
      results.push(result); console.log(JSON.stringify(result));
      if(outcome!=='PASS') console.log(JSON.stringify(await page.evaluate(()=>window.p2pDiagnostics)));
      assert.equal(outcome,'PASS'); assert.deepEqual(errors,[]);
      await context.close();
    }
  } finally {
    heartbeats.forEach(clearInterval);
    fs.writeFileSync(path.join(evidence,process.argv.includes('--large')?'large.json':`${process.env.P2P_CASE || 'transport'}.json`),JSON.stringify(results,null,2)+'\n');
    for(const context of contexts) await context.close();
    await browser.close();
    for(const profile of profiles) fs.rmSync(profile,{recursive:true,force:true});
    await new Promise(r=>server.close(r));
  }
})().catch(error=>{console.error(error.message);process.exitCode=1;});
