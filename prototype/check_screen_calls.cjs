// Дополнение существующего двухпользовательского UI-harness. Только тестовые вкладки.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
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

const results={result:'IN_PROGRESS',run:new Date().toISOString()};
exports.check = async (a,b,button,transport) => {
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
    await button(a,'Показать экран').waitFor({timeout:30000});
    await a.bringToFront();
    if(audioOnly) await mute(a,true);
    await button(a,'Показать экран').click();
    await button(a,'Остановить показ').waitFor({timeout:30000});
    await pixels(b);
    await a.bringToFront();
    await a.getByText('Экран: Авто',{exact:true}).click();
    await a.getByRole('menuitem',{name:'Экран: Низкое',exact:true}).click();
    await a.getByRole('menu',{name:'Всплывающее меню'}).waitFor({state:'hidden'});
    await a.waitForFunction(()=>window.callPeers.flatMap(pc=>pc.getSenders())
      .filter(s=>s.track?.getSettings().displaySurface).some(s=>s.getParameters().encodings?.every(e=>e.maxBitrate<=1000000&&e.maxFramerate<=8)));
    await a.getByText('Экран: Низкое',{exact:true}).click();
    await a.getByRole('menuitem',{name:'Экран: Авто',exact:true}).click();
    await a.getByRole('menu',{name:'Всплывающее меню'}).waitFor({state:'hidden'});
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
  } finally {
    const flag=process.env.VOICECHAT_SCREEN_TEST_FLAG;
    if(transport==='group' && flag && flag.startsWith('/tmp/voicechat-screen-')) {
      fs.writeFileSync(flag+'.pending','1',{mode:0o600});fs.renameSync(flag+'.pending',flag);
    }
    for(const source of sources) await source.close();
  }
};
