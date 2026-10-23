// Дополнение существующего двухпользовательского UI-harness. Только тестовые вкладки.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const {PNG}=require('pngjs');
const sourceColours=[[81,73,201],[201,97,49],[43,151,175]];
exports.syntheticMedia = () => {
  window.screenCaptureTracks=[];
  window.screenCaptureAttempts=[];
  window.screenTestAudioContexts=[];
  window.screenTestCameraRequests=0;
  const display=navigator.mediaDevices.getDisplayMedia.bind(navigator.mediaDevices);
  navigator.mediaDevices.getDisplayMedia=async options=>{
    const attempt={focused:document.hasFocus(),active:navigator.userActivation.isActive};
    window.screenCaptureAttempts.push(attempt);
    try {
      const stream=await display(options);
      window.screenCaptureTracks.push(...stream.getTracks());
      return stream;
    } catch(error) {attempt.error=error.name;throw error;}
  };
  navigator.mediaDevices.getUserMedia=async constraints=>{
    const stream=new MediaStream();
    if(constraints.video) {
      window.screenTestCameraRequests++;
      const canvas=document.createElement('canvas');canvas.width=320;canvas.height=180;
      const c=canvas.getContext('2d'),draw=()=>{c.fillStyle='#228833';c.fillRect(0,0,320,180);
        c.fillStyle='white';c.fillText(String(Date.now()),10,50);};
      draw();const timer=setInterval(draw,100),track=canvas.captureStream(10).getVideoTracks()[0];
      const stop=track.stop.bind(track);
      track.stop=()=>{clearInterval(timer);stop();};
      stream.addTrack(track);
    }
    if(constraints.audio) {
      const audio=new AudioContext(),tone=audio.createOscillator(),destination=audio.createMediaStreamDestination();
      window.screenTestAudioContexts.push(audio);
      tone.connect(destination);tone.start();await audio.resume();
      const track=destination.stream.getAudioTracks()[0],stop=track.stop.bind(track);
      let stopped=false;
      track.stop=()=>{if(stopped)return;stopped=true;stop();tone.stop();audio.close().catch(()=>{});};
      stream.addTrack(track);
    }
    return stream;
  };
};
async function pixels(page,present=true,colour=sourceColours[0]) {
  await page.bringToFront();
  const deadline=performance.now()+30000;
  while(performance.now()<deadline) {
    // flutter_webrtc hides <video> and paints it into Flutter Canvas.
    const {data}=PNG.sync.read(await page.screenshot({timeout:5000}));let count=0;
    for(let i=0;i<data.length;i+=4) {
      if(Math.abs(data[i]-colour[0])<20 && Math.abs(data[i+1]-colour[1])<20 && Math.abs(data[i+2]-colour[2])<20) count++;
    }
    if((count>20000)===present) return;
    await page.waitForTimeout(200);
  }
  assert.fail('Rendered screen source pixels did not become '+(present ? 'visible' : 'hidden'));
}
async function audio(page) {
  return page.evaluate(async()=>{
    let packets=0,frames=0;
    const voicePeers=[],transports=[];
    for(const [index,pc] of window.callPeers.entries()) {
      if(pc.connectionState==='closed') continue;
      const reports=[...(await pc.getStats()).values()];
      transports.push({index,state:pc.connectionState,ice:pc.iceConnectionState,
        senders:pc.getSenders().map(s=>s.track?.kind),receivers:pc.getReceivers().map(r=>r.track.kind),
        inbound:reports.filter(r=>r.type==='inbound-rtp').map(r=>({kind:r.kind,packets:r.packetsReceived,frames:r.framesDecoded}))});
      // Screen room не имеет audio: считаем camera только в основном voice PC.
      if(!reports.some(r=>r.type==='inbound-rtp'&&r.kind==='audio')) continue;
      voicePeers.push(index);
      for(const row of reports) {
        if(row.type==='inbound-rtp'&&row.kind==='audio') packets+=row.packetsReceived||0;
        if(row.type==='inbound-rtp'&&row.kind==='video') frames+=row.framesDecoded||0;
      }
    }
    return {packets,frames,voicePeers,transports,syntheticAudioStates:window.screenTestAudioContexts.map(c=>c.state)};
  });
}

async function waitForCallMedia(a,b,video) {
  // Основной звонок использует adaptiveStream: фоновая вкладка вправе не получать video.
  for(const page of [a,b]) {
    await page.bringToFront();
    let state;
    for(let attempt=0;attempt<100;attempt++) {
      state=await audio(page);
      if(state.packets>0 && (!video || state.frames>0)) break;
      await page.waitForTimeout(200);
    }
    assert(state.packets>0 && (!video || state.frames>0),
      'Base call must receive media before screen sharing: '+JSON.stringify(state));
  }
}

async function captureSource(page,index) {
  const source=await page.context().newPage();
  const url=new URL('screen-source.html',page.url()).href;
  await source.route(url,route=>route.fulfill({contentType:'text/html',body:
    '<!doctype html><title>VoiceChat Screen Source</title><body style="background:rgb('+sourceColours[index].join(',')+');color:white;font:48px sans-serif">Screen test<p id="tick"></p><script>setInterval(()=>tick.textContent=Date.now(),100)</script>'}));
  await source.goto(url);
  return source;
}

async function selectSource(sources,index) {
  for(const [position,source] of sources.entries()) {
    await source.evaluate(title=>document.title=title,
      position===index ? 'VoiceChat Screen Source' : 'Inactive screen fixture');
  }
}

const results={result:'IN_PROGRESS',run:new Date().toISOString()};
exports.check = async (a,b,button,transport,revokeDevice,faults) => {
  const started=performance.now();
  const audioOnly=process.env.VOICECHAT_VIDEO_TEST!=='1';
  async function mute(page, value) {
    await page.bringToFront();
    await button(page,value ? 'Выключить микрофон' : 'Включить микрофон').click();
    await page.mouse.move(5,5);
    await button(page,value ? 'Включить микрофон' : 'Выключить микрофон').waitFor();
  }
  const sources=[];
  for(const [index,page] of [a,b].entries()) sources.push(await captureSource(page,index));
  try {
    await waitForCallMedia(a,b,!audioOnly);
    await button(a,'Показать экран').waitFor({timeout:30000});
    if(transport==='direct' && process.env.VOICECHAT_SCREEN_LOST_REPLY_TEST==='1') {
      await selectSource(sources,0);
      await checkLostClaimReply(a,button);
    }
    if(transport==='direct' && process.env.VOICECHAT_SCREEN_CONCURRENT_TEST==='1') {
      await checkCompetingClaims(a,b,button,sources);
    }
    await a.bringToFront();
    if(audioOnly) await mute(a,true);
    await selectSource(sources,0);
    await button(a,'Показать экран').click();
    await button(a,'Остановить показ').waitFor({timeout:30000});
    await pixels(b);
    await a.bringToFront();
    await a.getByText('Экран: Авто',{exact:true}).click();
    await a.getByRole('menuitem',{name:'Экран: Низкое',exact:true}).click();
    await a.getByRole('menu').waitFor({state:'hidden'});
    await a.waitForFunction(()=>window.callPeers.flatMap(pc=>pc.getSenders())
      .filter(s=>s.track?.getSettings().displaySurface).some(s=>s.getParameters().encodings?.every(e=>e.maxBitrate<=1000000&&e.maxFramerate<=8)));
    await a.getByText('Экран: Низкое',{exact:true}).click();
    await a.getByRole('menuitem',{name:'Экран: Авто',exact:true}).click();
    await a.getByRole('menu').waitFor({state:'hidden'});
    if(audioOnly) await mute(a,false);
    const before=await audio(b);
    // Отмена picker не должна захватить владение или уничтожить текущий renderer.
    await b.evaluate(()=>{const original=navigator.mediaDevices.getDisplayMedia;
      navigator.mediaDevices.getDisplayMedia=async()=>{navigator.mediaDevices.getDisplayMedia=original;
        throw new DOMException('test cancellation','NotAllowedError');};});
    await selectSource(sources,1);
    await button(b,'Перехватить экран').click();
    await b.getByText('Показ не начат. Проверьте разрешение на захват экрана.',{exact:true}).waitFor();
    await a.bringToFront();
    await button(a,'Остановить показ').waitFor();await pixels(b);
    await button(b,'Перехватить экран').click();
    await button(b,'Остановить показ').waitFor({timeout:30000});
    await pixels(a,true,sourceColours[1]);
    await a.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'));
    await button(a,'Развернуть экран').click();
    await button(a,'Вернуться в звонок').click();
    if(audioOnly) await mute(b,true);
    await button(b,'Остановить показ').click();
    await button(a,'Показать экран').waitFor({timeout:30000});
    await b.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'));
    await pixels(a,false,sourceColours[1]);
    const after=await audio(b);
    assert.deepEqual(after.voicePeers,before.voicePeers,'Screen takeover must retain voice peer connections');
    assert(after.packets>before.packets,'Voice packets must continue through takeover/stop');
    if(!audioOnly) {
      assert(after.frames>before.frames,'Camera decoding must continue through takeover/stop');
      assert(await button(a,'Выключить камеру').isVisible());
    } else {
      await mute(b,false);
      assert.equal(await a.evaluate(()=>window.screenTestCameraRequests),0);
      assert.equal(await b.evaluate(()=>window.screenTestCameraRequests),0);
    }
    let disabled=false;
    const flag=process.env.VOICECHAT_SCREEN_TEST_FLAG;
    if(transport==='group' && flag) {
      assert(flag.startsWith('/tmp/voicechat-screen-'),'Use an isolated temporary test flag');
      await selectSource(sources,0);
      await a.bringToFront();await button(a,'Показать экран').click();await pixels(b);
      const baseline=await audio(b);
      fs.writeFileSync(flag+'.pending','0',{mode:0o600});fs.renameSync(flag+'.pending',flag);
      await a.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'),null,{timeout:8000});
      await pixels(b,false);
      await b.waitForTimeout(1200);
      const stopped=await audio(b);
      assert.deepEqual(stopped.voicePeers,baseline.voicePeers);
      assert(stopped.packets>baseline.packets && stopped.frames>baseline.frames,'Feature off must preserve base call');
      disabled=true;
    }
    results[transport]={result:'PASS',elapsed_seconds:(performance.now()-started)/1000,
      capture:'real browser tab, automatic picker selection',camera_microphone:audioOnly ? 'microphone synthetic; camera not requested' : 'synthetic',
      encrypted_matrix_key_exchange:true,decoded_source_pixels:true,cancel_preserves_owner:true,
      takeover_without_confirmation:true,old_capture_stopped:true,fullscreen_keeps_call:true,
      stop_releases_capture:true,low_encoder_limits_applied:true,voice_packets_increase:true,...(audioOnly ? {} : {video_frames_increase:true}),voice_peer_connections_unchanged:true,...(audioOnly ? {camera_not_requested:true,mute_before_during_after_preserved:true} : {}),...(disabled ? {feature_off_stops_capture_and_hides_frame:true,feature_off_preserves_voice_and_camera:true} : {})};
    results[transport].distinct_source_colours=true;
    results.result=results.direct && results.group ? 'PASS' : 'PARTIAL';
    fs.writeFileSync(path.join(__dirname,audioOnly ? 'verified-screen-calls-audio-run.json' : 'verified-screen-calls-run.json'),JSON.stringify(results,null,2)+'\n');
    console.log(`PASS: ${transport} screen capture, Matrix E2EE, cancellation, takeover and stop`);
    if(revokeDevice) await checkRevoke(a,b,button,revokeDevice,sources);
    if(faults) await require('./check_screen_faults.cjs').check({a,b,button,sources,selectSource,pixels,audio,fixture:faults});
  } finally {
    const flag=process.env.VOICECHAT_SCREEN_TEST_FLAG;
    if(transport==='group' && flag && flag.startsWith('/tmp/voicechat-screen-')) {
      fs.writeFileSync(flag+'.pending','1',{mode:0o600});fs.renameSync(flag+'.pending',flag);
    }
    for(const source of sources) await source.close();
  }
};

exports.checkThree=async(pages,button,joinThird)=>{
  const report={result:'FAIL',run:new Date().toISOString(),scope:'three ordinary web clients; real Matrix + SFU + tab capture; synthetic camera/microphone'};
  const started=performance.now(),sources=[];
  try {
    await waitForCallMedia(pages[0],pages[1],true);
    for(const [index,page] of pages.entries()) {
      if(index<2) await button(page,'Показать экран').waitFor({timeout:15000});
      sources.push(await captureSource(page,index));
    }
    const firstToken=pages[0].waitForResponse(r=>r.status()===200 && /\/screen\/[^/]+\/token$/.test(r.url()));
    await selectSource(sources,0);await pages[0].bringToFront();
    await button(pages[0],'Показать экран').click();
    const initial=await (await firstToken).json();
    await pixels(pages[1]);
    const rotated=pages[0].waitForResponse(r=>r.status()===200 && /\/screen\/[^/]+\/token$/.test(r.url()) && r.request().postDataJSON().generation!==initial.generation,{timeout:25000});
    await Promise.all([joinThird(),rotated]);
    await waitForCallMedia(pages[0],pages[2],true);
    for(const viewer of pages.slice(1)) await pixels(viewer);
    assert.equal(await pages[0].evaluate(()=>window.screenCaptureTracks.length),1,'Roster rotation must reuse the permitted root capture');
    assert.equal(await pages[0].evaluate(()=>window.screenCaptureTracks[0].readyState),'live');
    execFileSync('python3',['-c',"import sys;sys.path.insert(0,'prototype');from screen_fixture import assert_room_absent;assert_room_absent(sys.stdin.read())"],
      {cwd:path.join(__dirname,'..'),input:initial.generation,stdio:['pipe','pipe','pipe']});
    const before=await Promise.all(pages.map(audio));
    for(let index=1;index<pages.length;index++) {
      const owner=pages[index];await owner.bringToFront();
      await selectSource(sources,index);
      await button(owner,'Перехватить экран').click();
      await button(owner,'Остановить показ').waitFor({timeout:15000});
      for(const viewer of pages.filter(p=>p!==owner)) await pixels(viewer,true,sourceColours[index]);
      for(const former of pages.slice(0,index)) await former.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'));
    }
    const live=await Promise.all(pages.map(p=>p.evaluate(()=>window.screenCaptureTracks.filter(t=>t.readyState==='live').length)));
    assert.equal(live.reduce((a,b)=>a+b,0),1);
    for(const [index,page] of pages.entries()) {
      await page.bringToFront();let after;
      for(let attempt=0;attempt<30;attempt++) {
        after=await audio(page);
        if(after.packets>before[index].packets && after.frames>before[index].frames) break;
        await page.waitForTimeout(200);
      }
      assert.deepEqual(after.voicePeers,before[index].voicePeers,'Takeover must not rebuild voice transports');
      assert(after.packets>before[index].packets && after.frames>before[index].frames);
    }
    await button(pages[2],'Остановить показ').click();
    for(const page of pages) {
      await button(page,'Показать экран').waitFor();
      await page.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'));
      await pixels(page,false,sourceColours[2]);
    }
    report.result='PASS';report.participants=3;report.takeover_sequence='A -> B -> C';
    report.former_owners_view_winner_pixels=true;report.one_live_capture=true;
    report.voice_connections_unchanged=true;report.voice_and_camera_continue_on_all_clients=true;
    report.stop_releases_all_captures=true;
    report.distinct_source_colours=true;
    report.late_join_rotates_generation_and_delivers_pixels=true;
    report.roster_rotation_reuses_root_capture=true;
    report.previous_generation_deleted=true;
    console.log('PASS: late third join rotates generation without a second picker; A -> B -> C shows distinct encrypted pixels');
  } finally {
    if(report.result!=='PASS') {
      report.capture_attempts=await Promise.all(pages.map(p=>p.evaluate(()=>window.screenCaptureAttempts)));
      report.media_states=await Promise.all(pages.map(audio));
      report.renderers=await Promise.all(pages.map(page=>page.evaluate(()=>{
        function videos(root){return [...root.querySelectorAll('video'),...[...root.querySelectorAll('*')].filter(e=>e.shadowRoot).flatMap(e=>videos(e.shadowRoot))];}
        return videos(document).map(v=>({width:v.videoWidth,height:v.videoHeight,visible:v.checkVisibility({visibilityProperty:true,opacityProperty:true})}));
      })));
    }
    report.elapsed_seconds=(performance.now()-started)/1000;
    fs.writeFileSync(path.join(__dirname,'verified-screen-three-run.json'),JSON.stringify(report,null,2)+'\n');
    for(const source of sources) await source.close();
  }
};

async function checkLostClaimReply(page,button) {
  const started=performance.now();
  const report={result:'FAIL',run:new Date().toISOString(),scope:'real committed claim with one HTTP reply dropped by browser route'};
  const pattern='**/screen/*/claim';
  let first,finish,fail;
  const replayed=new Promise((resolve,reject)=>{finish=resolve;fail=reject;});
  const timer=setTimeout(()=>fail(new Error('Lost claim must be replayed within 15 seconds')),15000);
  const handler=async route=>{
    try {
      const body=route.request().postDataJSON();
      const response=await route.fetch();
      assert.equal(response.status(),200);
      const result=await response.json();
      assert.equal(result.status,'succeeded');
      if(!first) {
        first={body,result};
        await route.abort();
      } else {
        assert.deepEqual(body,first.body,'Retry must preserve the whole command and request_id');
        assert.equal(result.snapshot.generation,first.result.snapshot.generation,'Retry must not rotate the screen room');
        assert.equal(result.snapshot.revision,first.result.snapshot.revision);
        await route.fulfill({response});
        finish();
      }
    } catch(error) {fail(error);await route.abort().catch(()=>{});}
  };
  await page.route(pattern,handler);
  const stopped=page.waitForResponse(r=>r.status()===200 && /\/screen\/[^/]+\/stop$/.test(r.url()),{timeout:20000});
  const settled=Promise.all([replayed,stopped]);
  try {
    await page.bringToFront();await button(page,'Показать экран').click();
    await settled;
    await button(page,'Показать экран').waitFor();
    await page.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'));
    report.result='PASS';
    report.same_request_replayed=true;
    report.same_revision_and_generation=true;
    report.capture_released_and_owner_stopped=true;
    console.log('PASS: dropped claim reply replays same command without rotating room again');
  } finally {
    clearTimeout(timer);
    await page.unroute(pattern,handler);
    report.elapsed_seconds=(performance.now()-started)/1000;
    fs.writeFileSync(path.join(__dirname,'verified-screen-lost-reply-run.json'),JSON.stringify(report,null,2)+'\n');
  }
}

async function checkCompetingClaims(a,b,button,sources) {
  const started=performance.now();
  const report={result:'FAIL',run:new Date().toISOString(),scope:'two real capture requests held at the same revision, then sent concurrently'};
  const pattern='**/screen/*/claim', requests=[];
  let ready,fail;
  const paired=new Promise((resolve,reject)=>{ready=resolve;fail=reject;});
  let timer;
  const handlers=new Map();
  try {
    for(const page of [a,b]) {
      const handler=route=>{
        requests.push({page,route,body:route.request().postDataJSON()});
        if(requests.length===2) ready();
      };
      handlers.set(page,handler);await page.route(pattern,handler);
      await button(page,'Показать экран').waitFor({timeout:10000});
    }
    const firstSent=a.waitForRequest(r=>/\/screen\/[^/]+\/claim$/.test(r.url()),{timeout:10000});
    timer=setTimeout(()=>fail(new Error('Both prepared claims must arrive within 10 seconds')),10000);
    await Promise.all([
      (async()=>{
        await selectSource(sources,0);
        await a.bringToFront();await button(a,'Показать экран').click();await firstSent;
        await selectSource(sources,1);
        await b.bringToFront();await button(b,'Показать экран').click();
      })(),
      paired,
    ]);
    assert.equal(requests[0].body.expected_revision,requests[1].body.expected_revision);
    assert.notEqual(requests[0].body.request_id,requests[1].body.request_id);
    const replies=await Promise.all(requests.map(async item=>{
      const response=await item.route.fetch();
      await item.route.fulfill({response});
      return {page:item.page,status:response.status()};
    }));
    assert.deepEqual(replies.map(r=>r.status).sort(),[200,409]);
    const winner=replies.find(r=>r.status===200).page,loser=replies.find(r=>r.status===409).page;
    await button(winner,'Остановить показ').waitFor({timeout:15000});
    await loser.waitForFunction(()=>window.screenCaptureTracks.length>0 && window.screenCaptureTracks.every(t=>t.readyState==='ended'));
    await pixels(loser,true,sourceColours[winner===a ? 0 : 1]);
    const roots=await Promise.all([a,b].map(page=>page.evaluate(()=>window.screenCaptureTracks.filter(t=>t.readyState==='live').length)));
    assert.equal(roots[0]+roots[1],1,'Exactly one root capture may remain live');
    await button(winner,'Остановить показ').click();
    await button(a,'Показать экран').waitFor();
    await button(b,'Показать экран').waitFor();
    report.result='PASS';report.status_codes=[200,409];report.loser_capture_stopped=true;
    report.one_live_capture=true;report.winner_pixels_decrypted_by_loser=true;
    console.log('PASS: concurrent same-revision claims have one winner; loser releases capture and views encrypted screen');
  } finally {
    clearTimeout(timer);
    for(const [page,handler] of handlers) await page.unroute(pattern,handler);
    for(const item of requests) await item.route.abort().catch(()=>{});
    report.elapsed_seconds=(performance.now()-started)/1000;
    fs.writeFileSync(path.join(__dirname,'verified-screen-concurrent-run.json'),JSON.stringify(report,null,2)+'\n');
  }
}

async function checkRevoke(a,b,button,revokeDevice,sources) {
  const report={result:'FAIL',run:new Date().toISOString(),scope:'real Matrix device deletion during group screen publication'};
  const tokenResponse=b.waitForResponse(r=>r.status()===200 && /\/screen\/[^/]+\/token$/.test(r.url()));
  await selectSource(sources,1);
  await b.bringToFront();await button(b,'Показать экран').click();
  const response=await tokenResponse;
  const saved=await response.json();
  const headers=await response.request().allHeaders();
  const claims=JSON.parse(Buffer.from(saved.token.split('.')[1],'base64url').toString());
  assert.equal(saved.role,'publisher');
  const whoResponse=await fetch(new URL('/_matrix/client/v3/account/whoami',process.env.VOICECHAT_MATRIX_URL || 'http://localhost:8008'),{
    headers:{Authorization:headers.authorization},signal:AbortSignal.timeout(5000)});
  assert.equal(whoResponse.status,200);
  const who=await whoResponse.json();
  assert.equal(claims.sub,who.user_id+'/'+who.device_id);
  await button(b,'Остановить показ').waitFor({timeout:15000});
  await button(a,'Перехватить экран').waitFor({timeout:15000});
  await pixels(a,true,sourceColours[1]);
  // Не позволяем отозванному UI добровольно unbind: отзыв должен обеспечить сервер.
  const block=route=>route.abort();
  await b.route('**/screen/**',block);
  let probe;
  const started=performance.now();
  try {
    await revokeDevice(who.device_id);
    const denied=await fetch(response.url(),{method:'POST',headers:{'Content-Type':'application/json',Authorization:headers.authorization},
      body:response.request().postData(),signal:AbortSignal.timeout(5000)});
    assert.equal(denied.status,401,'Deleted device must not receive another screen token');
    await button(a,'Показать экран').waitFor({timeout:10000});
    await pixels(a,false,sourceColours[1]);
    assert.equal(claims.video.room,saved.generation);
    execFileSync('python3',['-c',
      "import sys;sys.path.insert(0,'prototype');from screen_fixture import assert_room_absent;assert_room_absent(sys.stdin.read())"],
      {input:saved.generation,cwd:path.join(__dirname,'..'),stdio:['pipe','pipe','pipe']});
    assert(Date.now()/1000<claims.exp,'Saved JWT must still be unexpired');
    probe=await a.context().newPage();
    const fixture={key:Buffer.alloc(32).toString('base64'),screen_wrong:saved.token,camera_wrong:saved.token};
    await probe.route('**/fixture.json',route=>route.fulfill({json:fixture}));
    await probe.goto(process.env.VOICECHAT_SCREEN_PROBE_URL || 'http://localhost:7362/?role=wrong');
    await probe.getByText(/^failed:/).waitFor({timeout:20000});
    assert(Date.now()/1000<claims.exp,'Reconnect rejection must precede token expiry');
    assert(await button(a,'Завершить').isVisible(),'Remaining group participant must retain the call');
    await selectSource(sources,0);
    await a.bringToFront();
    await button(a,'Показать экран').click();
    await button(a,'Остановить показ').waitFor({timeout:15000});
    await button(a,'Остановить показ').click();
    await b.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'),null,{timeout:10000});
    report.result='PASS';
    report.token_endpoint_after_device_deletion=401;
    report.old_frame_hidden=true;
    report.old_sfu_room_deleted=true;
    report.independent_pinned_sdk_rejects_unexpired_old_jwt=true;
    report.revoked_client_unbind_blocked=true;
    report.remaining_group_call_survives=true;
    report.remaining_device_can_publish_new_generation=true;
    report.revoked_client_capture_stopped=true;
    console.log('PASS: Matrix device deletion revokes active screen; independent SDK rejects unexpired JWT');
  } finally {
    report.elapsed_seconds=(performance.now()-started)/1000;
    fs.writeFileSync(path.join(__dirname,'verified-screen-revoke-run.json'),JSON.stringify(report,null,2)+'\n');
    if(probe) await probe.close();
    await b.unroute('**/screen/**',block);
  }
}
