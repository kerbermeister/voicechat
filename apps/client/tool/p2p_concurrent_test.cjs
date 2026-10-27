// Isolated Chromium: four encrypted P2P transfers alongside synthetic RTP.
// NODE_PATH=<Playwright modules> P2P_TURN_PORT=3479 node apps/client/tool/p2p_concurrent_test.cjs
// Start the local test TURN and build lib/lab_p2p_main.dart first; see docs/iterations/p2p-share.md.
const {chromium}=require('playwright');
const {spawn}=require('node:child_process');
const path=require('node:path');
const fs=require('node:fs');
const assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../../..');
(async()=>{
  const server=spawn(process.execPath,['prototype/test_p2p_transport.cjs','--serve'],{cwd:root,env:process.env,stdio:['ignore','pipe','inherit']});
  let browser;
  try {
    const origin=await new Promise((resolve,reject)=>{
      const timeout=setTimeout(()=>reject(new Error('Lab server startup timeout')),10000);
      server.once('error',error=>{clearTimeout(timeout);reject(error)});
      server.once('exit',()=>{clearTimeout(timeout);reject(new Error('Lab server exited'))});
      server.stdout.on('data',chunk=>{
        const match=String(chunk).match(/http:\/\/127\.0\.0\.1:\d+/);
        if(match){clearTimeout(timeout);resolve(match[0])}
      });
    });
    browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
    const context=await browser.newContext();
    const page=await context.newPage();
    const errors=[];page.on('pageerror',error=>errors.push(error.message));
    const start=Date.now();
    await page.goto(origin+'/?peers=4&bytes=33554432&storage=1&relay=1');
    await page.evaluate(async () => {
        const audio = new AudioContext();
        const tone = audio.createOscillator(), destination = audio.createMediaStreamDestination();
        tone.connect(destination); tone.start();
        const canvas = document.createElement('canvas'); canvas.width=320; canvas.height=240;
        const painter=canvas.getContext('2d'); let frame=0;
        const timer=setInterval(()=>{painter.fillStyle=`hsl(${frame++%360},80%,50%)`;painter.fillRect(0,0,320,240)},33);
        const iceServers=await (await fetch('/p2p-test-config.json')).json();
        const options={iceServers,iceTransportPolicy:'relay'};
        const video=canvas.captureStream(30), sender=new RTCPeerConnection(options), receiver=new RTCPeerConnection(options);
        sender.onicecandidate=e=>{if(e.candidate)receiver.addIceCandidate(e.candidate)};
        receiver.onicecandidate=e=>{if(e.candidate)sender.addIceCandidate(e.candidate)};
        for(const track of [...destination.stream.getTracks(),...video.getTracks()])sender.addTrack(track);
        await sender.setLocalDescription(await sender.createOffer());
        await receiver.setRemoteDescription(sender.localDescription);
        await receiver.setLocalDescription(await receiver.createAnswer());
        await sender.setRemoteDescription(receiver.localDescription);
        window.concurrentMedia={audio,receiver,sender,timer,tone,video,destination};
      });
    await page.getByRole('button',{name:'Run',exact:true}).click({timeout:60000});
    await page.evaluate(()=>window.concurrentMedia.audio.resume());
    assert.equal(await page.evaluate(()=>window.concurrentMedia.audio.state),'running');
    await page.getByText(/^(PASS|FAIL:)/).first().waitFor({timeout:180000});
    const outcome=await page.getByText(/^(PASS|FAIL:)/).first().innerText();
    const concurrentMedia=await page.evaluate(async()=>{
          const m=window.concurrentMedia;
          const stats=Array.from((await m.receiver.getStats()).values()).filter(s=>s.type==='inbound-rtp').map(s=>({kind:s.kind,bytesReceived:s.bytesReceived,framesDecoded:s.framesDecoded}));
          clearInterval(m.timer);m.tone.stop();for(const t of [...m.video.getTracks(),...m.destination.stream.getTracks()])t.stop();
          m.sender.close();m.receiver.close();await m.audio.close();return stats;
        });
        assert(concurrentMedia.some(s=>s.kind==='audio'&&s.bytesReceived>0));
        assert(concurrentMedia.some(s=>s.kind==='video'&&s.framesDecoded>10));
    assert.equal(outcome,'PASS');assert.deepEqual(errors,[]);
    const result={name:'four-relay-with-media',bytesPerRecipient:33554432,recipients:4,outcome,elapsedMs:Date.now()-start,errors,concurrentMedia};
    const evidence=path.join(root,'.prototype/p2p-evidence/concurrent-media.json');
    fs.writeFileSync(evidence,JSON.stringify(result,null,2)+'\n');
    console.log(JSON.stringify(result));
  } finally {
    if(browser)await browser.close();
    server.kill('SIGTERM');
  }
})().catch(error=>{console.error(error.message);process.exitCode=1});
