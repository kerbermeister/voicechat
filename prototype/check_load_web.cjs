// Isolated synthetic-media browsers; verify the server cap and all nine remote decoders per peer.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');
const {execFileSync} = require('node:child_process');
const crypto = require('node:crypto');
(async()=>{
  const root=path.join(__dirname,'..');
  const config=JSON.parse(fs.readFileSync(path.join(root,'.prototype/load-web.json')));
  assert.equal(JSON.parse(config.LOAD_ACCOUNTS).length,11,'Run prepare_run.py --load first');
  const browser=await chromium.launch({executablePath:process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,
    args:['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream','--autoplay-policy=no-user-gesture-required','--disable-background-timer-throttling','--disable-renderer-backgrounding']});
  try {
    let capProved=false;
    for(let peer=0;peer<11;peer++) {
      const context=await browser.newContext({permissions:['camera','microphone'],viewport:{width:1024,height:1000}});
      const page=await context.newPage();
      let traceMatrix=peer===10;
      page.on('request',request=>{
        const url=new URL(request.url());
        if(peer===10 && traceMatrix && url.port==='8008') console.log('Matrix request: '+url.pathname);
      });
      page.on('console',message=>{if(message.text().startsWith('LOAD STACK:') || message.text().startsWith('LOAD PHASE:')) console.log(message.text());});
      page.on('response',response=>{
        const url=new URL(response.url());
        if(url.pathname==='/token') {console.log(`Peer ${peer}: admission HTTP ${response.status()}`);traceMatrix=true;}
        if(peer===10 && traceMatrix && url.port==='8008') console.log(`Matrix response ${response.status()}: ${url.pathname}`);
      });
      page.on('websocket',()=>console.log(`Peer ${peer}: media signaling opened`));
      await page.goto(`http://localhost:7358/?peer=${peer}`);
    }
    for(let attempt=0;attempt<600;attempt++) {
      const response=await fetch('http://localhost:8090/reports');
      assert(response.ok,'Report service unavailable');
      const reports=(await response.json()).filter(r=>r.run===config.RUN_ID);
      const stages=new Set(reports.map(r=>r.stage));
      const failed=reports.find(r=>r.stage==='failed');
      assert(!failed,failed?.detail || 'Load acceptance failed');
      if(stages.has('load_eleventh_rejected') && !capProved) {
        const room=reports.find(report=>report.stage==='load_room')?.room_id;
        assert(room,'Load room binding missing');
        const name=crypto.createHash('sha256').update(room+'\0load'+config.RUN_ID).digest('hex');
        const logs=execFileSync('docker',['compose','-f',path.join(root,'prototype/compose.yaml'),'logs','--no-color','--tail=1000','livekit'],{encoding:'utf8',maxBuffer:8*1024*1024});
        capProved=logs.split('\n').some(line=>line.includes(name) && line.includes('room has exceeded its max participants'));
        assert(capProved,'Eleventh failure was not confirmed as a server room-cap rejection');
      }
      if(attempt%30===0) console.log(`Load acceptance: connected=${[...stages].filter(s=>/^load_connected_/.test(s)).length}, decoded=${[...stages].filter(s=>/^load_frames_/.test(s)).length}`);
      if(Array.from({length:11},(_,i)=>`load_done_${i}`).every(s=>stages.has(s))) {
        assert(capProved && stages.has('load_slot_released'));
        const publicReports=reports.map(({run,role,stage,timestamp})=>({run,role,stage,timestamp}));
        fs.writeFileSync(path.join(root,'prototype/verified-load-run.json'),JSON.stringify({run:config.RUN_ID,result:'PASS',reports:publicReports},null,2)+'\n');
        console.log('PASS: ten E2EE video/audio peers, nine remote decoders each, eleventh denied, released slot reusable');
        return;
      }
      await new Promise(resolve=>setTimeout(resolve,1000));
    }
    assert.fail('Ten-peer E2EE acceptance timed out');
  } finally {await browser.close();}
})().catch(error=>{console.error(error.message);process.exitCode=1;});
