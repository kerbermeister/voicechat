// Real SFU replay test: credentials/tokens stay in memory, never in logs or reports.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {chromium}=require('playwright');
const root=path.join(__dirname,'..');
const config=JSON.parse(fs.readFileSync(path.join(root,'.prototype/web.json')));
let stage='setup';
(async()=>{
  const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,
    args:['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream','--autoplay-policy=no-user-gesture-required','--disable-background-timer-throttling','--disable-renderer-backgrounding']});
  const saved=new Map();
  async function reports() {
    const response=await fetch('http://localhost:8090/reports');assert(response.ok);
    const list=(await response.json()).filter(r=>r.run===config.RUN_ID);
    assert(!list.some(r=>r.stage==='failed'),'A media actor failed');return list;
  }
  async function wait(check, seconds=120) {
    for(let i=0;i<seconds*2;i++) {if(await check())return;await new Promise(r=>setTimeout(r,500));}
    assert.fail('Acceptance stage timed out');
  }
  async function report(name) {
    const response=await fetch('http://localhost:8090/report',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({run:config.RUN_ID,role:'driver',stage:name})});assert(response.ok);
  }
  async function raw() {
    const context=await browser.newContext(), page=await context.newPage();
    await page.goto('http://localhost:7358/');
    await page.waitForFunction(()=>document.documentElement.getAttribute('data-raw-ready')==='true');
    return page;
  }
  try {
    const pages=[];
    for(let peer=0;peer<3;peer++) {
      const context=await browser.newContext({permissions:['camera','microphone'],viewport:{width:1000,height:900}});
      const page=await context.newPage();pages.push(page);
      page.on('response',async response=>{
        if(new URL(response.url()).pathname!=='/token' || response.status()!==200)return;
        try {
          saved.set(peer,{data:await response.json(),body:response.request().postDataJSON(),auth:response.request().headers()['authorization']});
        } catch (_) {} // A discarded page can close before its last response is read.
      });
      await page.goto('http://localhost:7358/?peer='+peer);
    }
    stage='three independent E2EE peers';
    await wait(async()=>{const list=await reports();return [0,1,2].every(i=>list.some(r=>r.stage==='revoke_ready_'+i));});
    console.log('PASS: three peers decode independent E2EE audio/video');
    const retained=saved.get(2);assert(retained);
    await pages[2].goto('about:blank');
    const renewed=await fetch('http://localhost:8090/token',{method:'POST',headers:{Authorization:retained.auth,'Content-Type':'application/json'},
      body:JSON.stringify({...retained.body,lease_id:retained.data.lease_id})});assert.equal(renewed.status,200);
    const admission=await renewed.json();
    const jwt=JSON.parse(Buffer.from(admission.token.split('.')[1],'base64url'));
    const rogue=await raw();
    let closedAt=0;
    rogue.on('websocket',socket=>socket.on('close',()=>{closedAt=Date.now();}));
    await rogue.evaluate(token=>window.postMessage({type:'voicechat.raw',token},location.origin),admission.token);
    stage='unmanaged saved-token participant';
    await rogue.waitForFunction(()=>document.documentElement.getAttribute('data-raw-state')==='connected',null,{timeout:20000});
    const revokedAt=Date.now();
    const logout=await fetch('http://localhost:8008/_matrix/client/v3/logout',{method:'POST',headers:{Authorization:retained.auth,'Content-Type':'application/json'},body:'{}'});
    assert.equal(logout.status,200);await report('revoked');
    stage='server-forced removal';
    await rogue.waitForFunction(()=>document.documentElement.getAttribute('data-raw-state')==='disconnected',null,{timeout:35000});
    assert(closedAt>=revokedAt && closedAt-revokedAt<=35000,'SFU must cut the unmanaged connection after revocation');
    assert(Date.now()/1000<jwt.exp,'The saved token must still be unexpired');
    console.log('PASS: server cut an unmanaged SFU participant after Matrix logout');
    stage='unexpired token replay';
    const replay=await raw();
    await replay.evaluate(token=>window.postMessage({type:'voicechat.raw',token},location.origin),admission.token);
    await replay.waitForFunction(()=>document.documentElement.getAttribute('data-raw-state')==='rejected',null,{timeout:15000});
    assert(Date.now()/1000<jwt.exp,'Replay must be rejected before JWT expiry');
    await report('replay_rejected');
    stage='remaining participants rekey and decode';
    await wait(async()=>{const list=await reports();return [0,1].every(i=>list.some(r=>r.stage==='revoke_done_'+i));});
    assert([0,1].every(i=>saved.get(i)?.data.generation!==admission.generation),'Both remaining peers must use a new media generation');
    const publicReports=(await reports()).map(({run,role,stage,timestamp})=>({run,role,stage,timestamp}));
    fs.writeFileSync(path.join(root,'prototype/verified-revocation-run.json'),JSON.stringify({run:config.RUN_ID,result:'PASS',reports:publicReports},null,2)+'\n');
    console.log('PASS: unexpired old JWT rejected; both remaining peers decode new-generation E2EE frames');
  } finally {saved.clear();await browser.close();}
})().catch(error=>{console.error(`FAIL at ${stage}: ${error.name}`);process.exitCode=1;});
