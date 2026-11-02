(() => {
  'use strict';
  if (!['localhost', '127.0.0.1', '[::1]'].includes(location.hostname)) {
    throw new Error('QA media is restricted to loopback');
  }
  const panel = document.createElement('aside');
  panel.style.cssText = 'position:fixed;bottom:8px;right:8px;z-index:2147483647;background:#171a22;color:#fff;border:2px solid #ddb75c;padding:8px;font:12px monospace;max-width:430px';
  const title = document.createElement('strong');
  title.textContent = 'QA: синтетические медиа; реальный микрофон не используется';
  const status = document.createElement('output');
  status.id = 'qa-media-status';
  status.style.cssText = 'display:block;white-space:pre-wrap;margin:5px 0';
  panel.append(title, status);
  const audio = new AudioContext();
  const silence = audio.createConstantSource();
  silence.offset.value = 0;
  silence.start();
  const sources = [], waiting = [];
  let holdNext = false, requests = 0;
  function metrics() {
    status.textContent = JSON.stringify({mode:'synthetic',requests,pending:waiting.length,hold_next:holdNext,
      sources:sources.length,ended:sources.filter(s=>s.getTracks().every(t=>t.readyState==='ended')).length,audio:audio.state});
    release.disabled = waiting.length === 0;
  }
  function button(label, action) {
    const item = document.createElement('button'); item.textContent=label;
    item.style.cssText='font:11px sans-serif;margin:2px'; item.onclick=action;panel.append(item);return item;
  }
  button('QA: запустить источник', async () => { await audio.resume(); metrics(); });
  button('QA: задержать следующий захват', () => { holdNext = true; metrics(); });
  const release = button('QA: вернуть задержанный захват', () => { waiting.shift()?.(); metrics(); });
  function makeSource(constraints) {
    const stream = new MediaStream(), cleanup=[];
    if (constraints.audio) {
      const destination = audio.createMediaStreamDestination();
      silence.connect(destination);
      stream.addTrack(destination.stream.getAudioTracks()[0]);
      cleanup.push(() => silence.disconnect(destination));
    }
    if (constraints.video) {
      const canvas = document.createElement('canvas'); canvas.width=640;canvas.height=360;
      const context=canvas.getContext('2d');let frame=0;
      const paint=() => { context.fillStyle=frame++%2?'#246a92':'#89367d';context.fillRect(0,0,640,360);
        context.fillStyle='#fff';context.font='32px monospace';context.fillText('QA frame '+frame,25,60); };
      paint();const timer=setInterval(paint,67);
      stream.addTrack(canvas.captureStream(15).getVideoTracks()[0]);cleanup.push(()=>clearInterval(timer));
    }
    let cleaned=false;
    for (const track of stream.getTracks()) {
      const stop=track.stop.bind(track);
      track.stop=()=>{stop();if(!cleaned && stream.getTracks().every(t=>t.readyState==='ended')) {
        cleaned=true;for(const dispose of cleanup)dispose();}metrics();};
    }
    sources.push(stream);metrics();return stream;
  }
  navigator.mediaDevices.getUserMedia = constraints => {
    requests++;audio.resume().catch(()=>{});
    if (holdNext) {
      holdNext=false;
      return new Promise(resolve=>{waiting.push(()=>resolve(makeSource(constraints)));metrics();});
    }
    return Promise.resolve(makeSource(constraints));
  };
  window.addEventListener('pagehide',()=>{for(const stream of sources)for(const track of stream.getTracks())track.stop();audio.close();});
  document.addEventListener('DOMContentLoaded',()=>{document.body.append(panel);metrics();});
})();
