// Focused playback acceptance; callers supply their own disposable logged-in page.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
module.exports=async function checkLinkCards({page:a,fill,button,waitForAnnouncement,root}) {
  const escape=text=>text.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  const clip = Buffer.from(await a.evaluate(async () => {
    const canvas=document.createElement('canvas');
    canvas.width=canvas.height=16;
    const context=canvas.getContext('2d');
    const stream=canvas.captureStream(10);
    const recorder=new MediaRecorder(stream,{mimeType:'video/webm;codecs=vp8'});
    const chunks=[];
    recorder.ondataavailable=event=>chunks.push(event.data);
    const stopped=new Promise(resolve=>recorder.onstop=resolve);
    const started=new Promise(resolve=>recorder.onstart=resolve);
    recorder.start(); await started;
    for(let frame=0;frame<10;frame++) {
      context.fillStyle=frame%2?'#9e8edb':'#8470c4'; context.fillRect(0,0,16,16);
      await new Promise(resolve=>setTimeout(resolve,100));
    }
    recorder.stop(); await stopped;
    stream.getTracks().forEach(track=>track.stop());
    return Array.from(new Uint8Array(await new Blob(chunks).arrayBuffer()));
  }));
  let videoRequests=0, embedRequests=0;
  const requestedPaths=[];
  await a.route('https://media.example.test/**',async route=>{
    videoRequests++; requestedPaths.push(new URL(route.request().url()).pathname);
    if(route.request().url().includes('broken')) return route.fulfill({status:404,headers:{'Cross-Origin-Resource-Policy':'cross-origin'},body:''});
    const range=/bytes=(\d+)-(\d*)/.exec(route.request().headers().range||'');
    const start=range?Number(range[1]):0;
    const end=range&&range[2]?Math.min(Number(range[2]),clip.length-1):clip.length-1;
    await route.fulfill({status:range?206:200,contentType:'video/webm',
      headers:{'Access-Control-Allow-Origin':'*','Cross-Origin-Resource-Policy':'cross-origin','Accept-Ranges':'bytes',
        ...(range?{'Content-Range':`bytes ${start}-${end}/${clip.length}`}:{})},
      body:clip.subarray(start,end+1)});
  });
  await a.route('https://www.youtube-nocookie.com/**',route=>{
    embedRequests++;
    return route.fulfill({status:403,contentType:'text/html',body:'Embedding unavailable'});
  });
  async function sendLink(text) {
    await fill(a,'Написать сообщение…',text); await button(a,'Отправить').click();
    await waitForAnnouncement(a,text);
    return text;
  }
  async function playLink(text) {
    // Flutter merges a settled link card into a button, not a text group.
    const card=a.getByRole('button',{name:new RegExp(escape(text))})
      .filter({has:button(a,'Смотреть видео')});
    await card.getByRole('button',{name:'Смотреть видео',exact:true}).click();
    console.log('Playback target:',text);
    console.log('Current player:',await a.locator('video').evaluateAll(videos=>videos.map(v=>({src:v.currentSrc,ready:v.readyState,error:v.error?.code}))));
  }
  const message=await sendLink('https://media.example.test/clip.webm');
  assert.equal(videoRequests,0,'Video must not load before the explicit action');
  await playLink(message);
  try {await a.waitForFunction(()=>Array.from(document.querySelectorAll('video')).some(v=>v.videoWidth>0 && v.readyState>=2 && v.getVideoPlaybackQuality().totalVideoFrames>0));} catch(error) {
    console.log('Fixture paths:',requestedPaths);
    console.log('Decode failed:',await a.locator('video').evaluateAll(videos=>videos.map(v=>({src:v.currentSrc,ready:v.readyState,error:v.error?.code,frames:v.getVideoPlaybackQuality().totalVideoFrames}))));
    throw error;
  }
  await a.getByRole('button',{name:/^Закрыть видео/}).click();
  await a.waitForFunction(()=>Array.from(document.querySelectorAll('video')).every(v=>v.paused || !v.isConnected || !v.src));
  const broken=await sendLink('https://media.example.test/broken.webm');
  await playLink(broken);
  try {await waitForAnnouncement(a,'Видео не удалось открыть');} catch(error) {
    console.log('Fixture paths:',requestedPaths);
    console.log('Failed player:',await a.locator('video').evaluateAll(videos=>videos.map(v=>({src:v.currentSrc,ready:v.readyState,error:v.error?.code,paused:v.paused}))));
    throw error;
  }
  await button(a,'Открыть оригинал').waitFor();
  await a.getByRole('button',{name:/^Закрыть видео/}).click();
  const youtube=await sendLink('https://youtu.be/abcdefghijk');
  assert.equal(embedRequests,0,'Embedding must wait for the user');
  await playLink(youtube);
  await a.locator('iframe[title="YouTube · видеоплеер"]').waitFor();
  await button(a,'Если видео недоступно — открыть оригинал').waitFor();
  assert.equal(await a.locator('iframe').getAttribute('credentialless'),'');
  await a.getByRole('button',{name:/^Закрыть видео/}).click();
  await a.locator('iframe[title="YouTube · видеоплеер"]').waitFor({state:'detached'});
  const videoActions=await button(a,'Смотреть видео').count();
  await sendLink('https://example.test/unsupported');
  assert.equal(await button(a,'Смотреть видео').count(),videoActions);
  await a.screenshot({path:path.join(root,'.prototype/ui/link-cards-narrow.png')});
  fs.writeFileSync(path.join(root,'prototype/verified-links-run.json'),JSON.stringify({
    run:Math.floor(Date.now()/1000),result:'PASS',scope:'web 390px; decoded local WebM fixture; denied YouTube embed fixture',
    no_video_requests_before_action:true,direct_webm_frames_decoded:true,
    broken_video_fallback:true,youtube_fallback_and_cleanup:true,unsupported_link_has_no_inline_player:true,
  },null,2)+'\n');
};
