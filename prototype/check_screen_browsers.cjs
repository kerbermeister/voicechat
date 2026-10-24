// SS-12: browser interoperability, pinned Flutter/LiveKit probe; no Matrix claim.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');
const {createInterface}=require('node:readline');
const {chromium,firefox,webkit}=require('playwright');
const media=require('./check_screen_calls.cjs');
const target=process.argv[2],direction=process.argv[3]||'viewer';
assert(['edge','firefox','webkit','safari'].includes(target));
assert(['viewer','sender'].includes(direction) && (direction==='viewer' || target==='edge'));
const root=path.join(__dirname,'..'),directory=process.env.VOICECHAT_SCREEN_PROBE_DIRECTORY;
assert(directory && directory.startsWith('/tmp/voicechat-screen-'));
const url='http://localhost:7362/';
const report={result:'FAIL',run:new Date().toISOString(),target,direction,
  scope:'real pinned SFU and Flutter SDK; lab entrypoint; synthetic microphone/camera; Matrix exchange not exercised',
  android:'NOT_RUN',heavy_load:'NOT_RUN'};
const fixture=action=>execFileSync('python3',['prototype/screen_fixture.py',...(action ? [action] : [])],{cwd:root,stdio:'pipe'});
const browserArgs=['--enable-usermedia-screen-capturing','--auto-select-tab-capture-source-by-title=VoiceChat Screen Source','--autoplay-policy=no-user-gesture-required'];
async function launch(name) {
  if(name==='firefox')return firefox.launch({headless:true,firefoxUserPrefs:{'media.peerconnection.ice.loopback':true}});
  if(name==='webkit')return webkit.launch({headless:true});
  const executablePath=name==='edge' ? fs.readFileSync('/tmp/voicechat-screen-browsers/edge-path','utf8').trim()+'/Contents/MacOS/Microsoft Edge' : '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  return chromium.launch({executablePath,headless:true,args:browserArgs});
}
async function stats(page) {
  await page.getByRole('button',{name:'Статистика',exact:true}).click();
  const text=await page.getByText(/^stats:/).textContent();
  const m=text.match(/screen=(\d+),camera=(\d+),decrypted=(true|false).*audio=(\d+)/);assert(m);
  return {screen:+m[1],camera:+m[2],decrypted:m[3]==='true',audio_packets:+m[4]};
}
(async()=>{
  const browsers=[];let rooms=[];
  try {
    fixture();rooms=JSON.parse(fs.readFileSync(path.join(directory,'fixture.json'))).rooms;
    report.source_commit=execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim();
    report.lab_source_sha256=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'apps/client/lib/lab_screen_main.dart'))).digest('hex');
    report.lab_js_sha256=crypto.createHash('sha256').update(fs.readFileSync(path.join(directory,'main.dart.js'))).digest('hex');
    const senderBrowser=await launch(direction==='sender' ? target : 'chrome');browsers.push(senderBrowser);
    const context=await senderBrowser.newContext({viewport:{width:1280,height:900}});
    await context.addInitScript(media.syntheticMedia);
    const source=await context.newPage();await source.goto(url+'source.html');
    const sender=await context.newPage();await sender.goto(url+'?role=sender');
    await sender.getByText('ready',{exact:true}).waitFor({timeout:60000});
    await sender.getByRole('button',{name:'Захватить экран',exact:true}).click();
    await sender.getByText('published',{exact:true}).waitFor({timeout:30000});
    if(target==='safari') {
      console.log('Native Safari viewer ready at '+url+'?role=viewer; press Enter only after CUA verification');
      const input=createInterface({input:process.stdin}),lines=input[Symbol.asyncIterator]();
      assert(!(await lines.next()).done,'Native inspection required');
      input.close();
      report.native_observation='See separate native Safari/VoiceOver record; no automatic media PASS';
      report.result='MANUAL_SESSION_COMPLETE';
    } else {
      const viewerBrowser=await launch(direction==='sender' ? 'chrome' : target);browsers.push(viewerBrowser);
      report.sender_browser=senderBrowser.version();report.viewer_browser=viewerBrowser.version();
      const vc=await viewerBrowser.newContext({viewport:{width:1280,height:900}});
      await vc.addInitScript(()=>{
        window.probePeers=[];window.RTCPeerConnection=new Proxy(window.RTCPeerConnection,{construct(target,args){
          const pc=Reflect.construct(target,args);window.probePeers.push(pc);return pc;
        }});
      });
      const viewer=await vc.newPage();
      if(target==='firefox')report.firefox_test_preferences={loopback_ice:true};
      await viewer.goto(url+'?role=viewer');
      report.apis=await viewer.evaluate(()=>({secure:isSecureContext,isolated:crossOriginIsolated,
        shared_array_buffer:typeof SharedArrayBuffer==='function',script_transform:typeof RTCRtpScriptTransform==='function',
        encoded_streams:typeof RTCRtpSender.prototype.createEncodedStreams==='function',display_media:typeof navigator.mediaDevices.getDisplayMedia==='function'}));
      await viewer.getByText(/^(ready|failed:)/).waitFor({timeout:60000});
      report.viewer_stage=await viewer.getByText(/^(ready|failed:)/).textContent();
      report.peer_states=await viewer.evaluate(()=>window.probePeers.map(p=>{
        try {return {ice:p.iceConnectionState,gathering:p.iceGatheringState,connection:p.connectionState};}
        catch {return {state_read_failed:true};}
      })).catch(()=>['not_available']);
      assert.equal(report.viewer_stage,'ready','Browser SDK preparation failed');
      let valid;
      for(let i=0;i<100;i++) {
        await viewer.bringToFront();valid=await stats(viewer);
        if(valid.screen>5 && valid.camera>5 && valid.decrypted)break;
        await viewer.waitForTimeout(200);
      }
      assert(valid.screen>5 && valid.camera>5 && valid.decrypted);await media.pixels(viewer);
      const wrong=await vc.newPage();await wrong.goto(url+'?role=wrong');
      await wrong.getByText('ready',{exact:true}).waitFor({timeout:60000});await wrong.waitForTimeout(1000);
      const missing=await stats(wrong);assert.equal(missing.screen,0);assert.equal(missing.camera,0);assert.equal(missing.decrypted,false);
      await wrong.getByRole('button',{name:'Неверный ключ',exact:true}).click();
      await wrong.getByText('wrong-key-installed',{exact:true}).waitFor();await wrong.waitForTimeout(1000);
      const incorrect=await stats(wrong);assert.equal(incorrect.screen,0);assert.equal(incorrect.camera,0);assert.equal(incorrect.decrypted,false);
      await wrong.close();
      fixture('retire-screen');await viewer.bringToFront();let after;
      for(let i=0;i<50;i++) {
        after=await stats(viewer);
        if(after.camera>valid.camera && after.audio_packets>valid.audio_packets)break;
        await viewer.waitForTimeout(200);
      }
      assert(after.camera>valid.camera && after.audio_packets>valid.audio_packets);
      Object.assign(report,{result:'PASS',valid,missing_key:missing,wrong_key:incorrect,
        rendered_source_pixels:true,screen_room_deletion_preserves_camera_and_audio_packets:true});
    }
  } finally {
    for(const browser of browsers)await browser.close();
    fixture('cleanup');
    execFileSync('python3',['-c',"import sys,json;sys.path.insert(0,'prototype');from screen_fixture import assert_room_absent;[assert_room_absent(r) for r in json.load(sys.stdin)]"],{cwd:root,input:JSON.stringify(rooms),stdio:'pipe'});
    report.cleanup_completed=true;
    fs.writeFileSync(path.join(__dirname,'verified-screen-browser-'+target+'-'+direction+'-run.json'),JSON.stringify(report,null,2)+'\n');
  }
  console.log(report.result+': '+target+' '+direction);
})().catch(error=>{console.error(error.name+': '+(error.code==='ERR_ASSERTION' ? error.message : 'browser probe failed; no SDK secrets logged'));process.exitCode=1;});
