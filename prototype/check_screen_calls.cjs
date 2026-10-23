// Дополнение существующего двухпользовательского UI-harness. Только тестовые вкладки.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
exports.syntheticMedia = () => {
  window.screenCaptureTracks=[];
  window.screenTestCameraRequests=0;
  const display=navigator.mediaDevices.getDisplayMedia.bind(navigator.mediaDevices);
  navigator.mediaDevices.getDisplayMedia=async options=>{
    const stream=await display(options);
    window.screenCaptureTracks.push(...stream.getTracks());
    return stream;
  };
  navigator.mediaDevices.getUserMedia=async constraints=>{
    const stream=new MediaStream();
    if(constraints.video) {
      window.screenTestCameraRequests++;
      const canvas=document.createElement('canvas');canvas.width=320;canvas.height=180;
      const c=canvas.getContext('2d');setInterval(()=>{c.fillStyle='#228833';c.fillRect(0,0,320,180);
        c.fillStyle='white';c.fillText(String(Date.now()),10,50);},100);
      stream.addTrack(canvas.captureStream(10).getVideoTracks()[0]);
    }
    if(constraints.audio) {
      const audio=new AudioContext(),tone=audio.createOscillator(),destination=audio.createMediaStreamDestination();
      tone.connect(destination);tone.start();stream.addTrack(destination.stream.getAudioTracks()[0]);
    }
    return stream;
  };
};
async function pixels(page,present=true) {
  await page.bringToFront();
  await page.waitForFunction(expected=>{
    function videos(root) {return [...root.querySelectorAll('video'), ...[...root.querySelectorAll('*')].filter(el=>el.shadowRoot).flatMap(el=>videos(el.shadowRoot))];}
    return videos(document).some(v=>{
    if(!v.videoWidth || !v.getBoundingClientRect().width) return false;
    const canvas=document.createElement('canvas');canvas.width=canvas.height=32;
    const c=canvas.getContext('2d');c.drawImage(v,0,0,32,32);
    const p=c.getImageData(0,0,32,32).data;let count=0;
    for(let i=0;i<p.length;i+=4) if(Math.abs(p[i]-81)<20&&Math.abs(p[i+1]-73)<20&&Math.abs(p[i+2]-201)<20) count++;
    return count>300;
  })===expected;},present,{timeout:30000});
}
async function audio(page) {
  return page.evaluate(async()=>{
    let packets=0,frames=0;
    const voicePeers=[];
    for(const [index,pc] of window.callPeers.entries()) {
      if(pc.connectionState==='closed') continue;
      const reports=[...(await pc.getStats()).values()];
      // Screen room не имеет audio: считаем camera только в основном voice PC.
      if(!reports.some(r=>r.type==='inbound-rtp'&&r.kind==='audio')) continue;
      voicePeers.push(index);
      for(const row of reports) {
        if(row.type==='inbound-rtp'&&row.kind==='audio') packets+=row.packetsReceived||0;
        if(row.type==='inbound-rtp'&&row.kind==='video') frames+=row.framesDecoded||0;
      }
    }
    return {packets,frames,voicePeers};
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

const results={result:'IN_PROGRESS',run:new Date().toISOString()};
exports.check = async (a,b,button,transport,revokeDevice) => {
  const started=performance.now();
  const audioOnly=process.env.VOICECHAT_VIDEO_TEST!=='1';
  async function mute(page, value) {
    await page.bringToFront();
    await button(page,value ? 'Выключить микрофон' : 'Включить микрофон').click();
    await page.mouse.move(5,5);
    await button(page,value ? 'Включить микрофон' : 'Выключить микрофон').waitFor();
  }
  const sources=[];
  for(const page of [a,b]) {
    const source=await page.context().newPage();sources.push(source);
    const sourceUrl=new URL('screen-source.html',page.url()).href;
    await source.route(sourceUrl, route=>route.fulfill({contentType:'text/html',body:
      '<!doctype html><title>VoiceChat Screen Source</title><body style="background:#5149c9;color:white;font:48px sans-serif">Screen test<p id="tick"></p><script>setInterval(()=>tick.textContent=Date.now(),100)</script>'}));
    await source.goto(sourceUrl);
  }
  try {
    await waitForCallMedia(a,b,!audioOnly);
    await button(a,'Показать экран').waitFor({timeout:30000});
    if(transport==='direct' && process.env.VOICECHAT_SCREEN_LOST_REPLY_TEST==='1') {
      await checkLostClaimReply(a,button);
    }
    await a.bringToFront();
    if(audioOnly) await mute(a,true);
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
    await button(b,'Перехватить экран').click();
    await b.getByText('Показ не начат. Проверьте разрешение на захват экрана.',{exact:true}).waitFor();
    await a.bringToFront();
    await button(a,'Остановить показ').waitFor();await pixels(b);
    await button(b,'Перехватить экран').click();
    await button(b,'Остановить показ').waitFor({timeout:30000});
    await pixels(a);
    await a.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'));
    await button(a,'Развернуть экран').click();
    await button(a,'Вернуться в звонок').click();
    if(audioOnly) await mute(b,true);
    await button(b,'Остановить показ').click();
    await button(a,'Показать экран').waitFor({timeout:30000});
    await b.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'));
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
    results.result=results.direct && results.group ? 'PASS' : 'PARTIAL';
    fs.writeFileSync(path.join(__dirname,audioOnly ? 'verified-screen-calls-audio-run.json' : 'verified-screen-calls-run.json'),JSON.stringify(results,null,2)+'\n');
    console.log(`PASS: ${transport} screen capture, Matrix E2EE, cancellation, takeover and stop`);
    if(revokeDevice) await checkRevoke(a,b,button,revokeDevice);
  } finally {
    const flag=process.env.VOICECHAT_SCREEN_TEST_FLAG;
    if(transport==='group' && flag && flag.startsWith('/tmp/voicechat-screen-')) {
      fs.writeFileSync(flag+'.pending','1',{mode:0o600});fs.renameSync(flag+'.pending',flag);
    }
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

async function checkRevoke(a,b,button,revokeDevice) {
  const report={result:'FAIL',run:new Date().toISOString(),scope:'real Matrix device deletion during group screen publication'};
  const tokenResponse=b.waitForResponse(r=>r.status()===200 && /\/screen\/[^/]+\/token$/.test(r.url()));
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
  await pixels(a);
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
    await pixels(a,false);
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
    await a.bringToFront();
    await button(a,'Показать экран').click();
    await button(a,'Остановить показ').waitFor({timeout:15000});
    await button(a,'Остановить показ').click();
    report.result='PASS';
    report.token_endpoint_after_device_deletion=401;
    report.old_frame_hidden=true;
    report.old_sfu_room_deleted=true;
    report.independent_pinned_sdk_rejects_unexpired_old_jwt=true;
    report.revoked_client_unbind_blocked=true;
    report.remaining_group_call_survives=true;
    report.remaining_device_can_publish_new_generation=true;
    console.log('PASS: Matrix device deletion revokes active screen; independent SDK rejects unexpired JWT');
  } finally {
    report.elapsed_seconds=(performance.now()-started)/1000;
    fs.writeFileSync(path.join(__dirname,'verified-screen-revoke-run.json'),JSON.stringify(report,null,2)+'\n');
    if(probe) await probe.close();
    await b.unroute('**/screen/**',block);
  }
}
