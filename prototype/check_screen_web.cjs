// Собственный Chromium и реальный захват тестовой вкладки; камера/микрофон синтетические.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const {chromium} = require('playwright');

(async () => {
  const start = performance.now();
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true,
    args: [
      '--enable-usermedia-screen-capturing',
      '--auto-select-tab-capture-source-by-title=VoiceChat Screen Source',
      '--autoplay-policy=no-user-gesture-required'],
  });
  const result = {result: 'FAIL', browser: browser.version(),
    capture: 'real browser tab; automated source selection',
    camera_microphone: 'synthetic', matrix_key_exchange: 'NOT_TESTED',
    android: 'NOT_TESTED', p2p_plus_sfu: 'NOT_TESTED'};
  try {
    const context = await browser.newContext({permissions: ['camera', 'microphone']});
    // Подменяется только camera/microphone API. getDisplayMedia остаётся настоящим.
    await context.addInitScript(() => {
      navigator.mediaDevices.getUserMedia = async constraints => {
        const stream = new MediaStream();
        if (constraints.video) {
          const canvas = document.createElement('canvas'); canvas.width = 320; canvas.height = 180;
          const context = canvas.getContext('2d');
          setInterval(() => { context.fillStyle = '#228833'; context.fillRect(0,0,320,180);
            context.fillStyle = 'white'; context.fillText(String(Date.now()), 10, 50); }, 100);
          stream.addTrack(canvas.captureStream(10).getVideoTracks()[0]);
        }
        if (constraints.audio) {
          const audio = new AudioContext(); const tone = audio.createOscillator();
          const destination = audio.createMediaStreamDestination(); tone.connect(destination); tone.start();
          stream.addTrack(destination.stream.getAudioTracks()[0]);
        }
        return stream;
      };
    });
    const source = await context.newPage();
    await source.goto('http://localhost:7362/source.html');
    const pages = {};
    for (const role of ['viewer', 'wrong', 'sender']) {
      const page = pages[role] = await context.newPage();
      await page.goto('http://localhost:7362/?role=' + role);
      await page.getByText('ready', {exact: true}).waitFor({timeout: 60000});
    }
    await pages.sender.getByRole('button', {name: 'Захватить экран', exact: true}).click();
    await pages.sender.getByText('published', {exact: true}).waitFor({timeout: 30000});
    let valid;
    for (let attempt = 0; attempt < 30; attempt++) {
      await pages.viewer.getByRole('button', {name: 'Статистика', exact: true}).click();
      valid = await pages.viewer.getByText(/^stats:/).textContent();
      const match = valid.match(/screen=(\d+),camera=(\d+),decrypted=(true|false)/);
      if (match && Number(match[1]) > 5 && Number(match[2]) > 5 && match[3] === 'true') break;
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
    assert.match(valid, /decrypted=true/);
    const numbers = valid.match(/screen=(\d+),camera=(\d+)/);
    assert(Number(numbers[1]) > 5 && Number(numbers[2]) > 5, 'Independent screen/camera decoding required');
    const audioBefore = Number(valid.match(/audio=(\d+)/)[1]);
    assert(audioBefore > 0, 'Microphone packets required in the independent call room');
    await pages.wrong.getByRole('button', {name: 'Статистика', exact: true}).click();
    const wrong = await pages.wrong.getByText(/^stats:/).textContent();
    result.decoder_observations = {valid, missing_key: wrong};
    assert.match(wrong, /screen=0,camera=0,decrypted=false/);
    await pages.wrong.getByRole('button', {name:'Неверный ключ',exact:true}).click();
    await pages.wrong.getByText('wrong-key-installed',{exact:true}).waitFor();
    await pages.wrong.waitForTimeout(1000);
    await pages.wrong.getByRole('button',{name:'Статистика',exact:true}).click();
    const incorrect=await pages.wrong.getByText(/^stats:/).textContent();
    assert.match(incorrect,/screen=0,camera=0,decrypted=false/);
    result.wrong_key_decoded_frames=0;
    const pixels = await pages.viewer.locator('video').evaluateAll(videos => videos.map(video => {
      if (!video.videoWidth) return 0;
      const canvas = document.createElement('canvas'); canvas.width = canvas.height = 32;
      const context = canvas.getContext('2d'); context.drawImage(video, 0, 0, 32, 32);
      const data = context.getImageData(0, 0, 32, 32).data;
      let purple = 0;
      for (let i = 0; i < data.length; i += 4) {
        if (Math.abs(data[i]-81)<20 && Math.abs(data[i+1]-73)<20 && Math.abs(data[i+2]-201)<20) purple++;
      }
      return purple;
    }));
    result.source_colour_samples = pixels;
    assert(pixels.some(count => count > 300), 'Decoded source colour must match captured tab');
    await pages.sender.getByRole('button', {name:'Перепубликовать копию', exact:true}).click();
    await pages.sender.getByText('clone-republished', {exact:true}).waitFor({timeout:15000});
    await pages.viewer.waitForFunction(() => [...document.querySelectorAll('video')].some(video => {
      if (!video.videoWidth) return false;
      const canvas=document.createElement('canvas'); canvas.width=canvas.height=1;
      const c=canvas.getContext('2d'); c.drawImage(video,0,0,1,1);
      const p=c.getImageData(0,0,1,1).data;
      return Math.abs(p[0]-81)<20 && Math.abs(p[1]-73)<20 && Math.abs(p[2]-201)<20;
    }), null, {timeout:15000});
    result.capture_survives_publication_disposal = true;
    await pages.sender.getByRole('button', {name:'Камера в screen room', exact:true}).click();
    await pages.sender.getByText('camera-rejected', {exact:true}).waitFor({timeout:15000});
    result.owner_camera_in_screen_room = 'REJECTED';
    await pages.viewer.getByRole('button', {name:'Публикация viewer', exact:true}).click();
    await pages.viewer.getByText(/^failed:/).waitFor({timeout:15000});
    result.viewer_publication = 'REJECTED';
    await pages.sender.getByRole('button', {name: 'Статистика', exact: true}).click();
    const direct = await pages.sender.getByText(/^stats:/).textContent();
    assert(Number(direct.match(/p2p=(\d+)/)[1]) > 5, 'Flutter WebRTC P2P decoder must continue alongside both SFU rooms');
    result.p2p_frames = Number(direct.match(/p2p=(\d+)/)[1]);
    result.p2p_plus_sfu = 'PASS: local Flutter WebRTC pair; not Matrix DirectCall acceptance';
    await pages.sender.getByRole('button', {name: 'Второй трек', exact: true}).click();
    const duplicateResult = pages.sender.getByText(/^duplicate-(published|rejected)$/);
    await duplicateResult.waitFor({timeout:30000});
    const duplicateStage = await duplicateResult.textContent();
    await pages.sender.getByRole('button', {name: 'Статистика', exact:true}).click();
    const duplicate = await pages.sender.getByText(/^stats:/).textContent();
    result.same_owner_two_tracks = {result: duplicateStage,
      publications: Number(duplicate.match(/publications=(\d+)/)[1])};
    execFileSync('python3', [path.join(__dirname, 'screen_fixture.py'), 'inspect-duplicate'], {stdio:'pipe'});
    result.production_metadata_guard = 'REJECTS_DUPLICATE';
    execFileSync('python3', [path.join(__dirname, 'screen_fixture.py'), 'refresh-sender'], {stdio: 'pipe'});
    for (let attempt = 0; attempt < 10; attempt++) {
      await pages.sender.getByRole('button', {name: 'Запомнить токен', exact: true}).click();
      if (await pages.sender.getByText('token-refreshed', {exact:true}).count()) break;
      await new Promise(resolve => setTimeout(resolve, 500));
    }
    await pages.sender.getByText('token-refreshed', {exact:true}).waitFor({timeout:5000});
    execFileSync('python3', [path.join(__dirname, 'screen_fixture.py'), 'retire-screen'], {stdio: 'pipe'});
    await pages.sender.getByRole('button', {name: 'Повторить токен', exact: true}).click();
    await pages.sender.getByText('replay-rejected', {exact:true}).waitFor({timeout:30000});
    result.refreshed_jwt_deleted_room = 'REJECTED';
    const replay = await context.newPage();
    await replay.goto('http://localhost:7362/?role=sender');
    await replay.getByText(/^failed:/).waitFor({timeout: 30000});
    result.old_jwt_deleted_room = 'REJECTED';
    await pages.viewer.getByRole('button', {name: 'Статистика', exact: true}).click();
    const after = await pages.viewer.getByText(/^stats:/).textContent();
    assert(Number(after.match(/camera=(\d+)/)[1]) > Number(numbers[2]), 'Camera must survive screen room deletion');
    assert(Number(after.match(/audio=(\d+)/)[1]) > audioBefore, 'Microphone must survive screen room deletion');
    await pages.sender.getByRole('button', {name: 'Статистика', exact: true}).click();
    const afterDirect = await pages.sender.getByText(/^stats:/).textContent();
    assert(Number(afterDirect.match(/p2p=(\d+)/)[1]) > result.p2p_frames, 'P2P must survive screen room deletion');
    result.screen_deletion_call_continuity = 'PASS: camera, microphone packets, local P2P';
    result.source_colour_verified = true;
    result.result = 'PASS';
    result.screen_frames = Number(numbers[1]);
    result.camera_frames = Number(numbers[2]);
    result.missing_key_decoded_frames = 0;
    result.elapsed_seconds = (performance.now() - start) / 1000;
    console.log(JSON.stringify(result));
  } finally {
    await browser.close();
    result.elapsed_seconds = (performance.now() - start) / 1000;
    fs.writeFileSync(path.join(__dirname, 'verified-screen-web-run.json'), JSON.stringify(result, null, 2) + '\n');
  }
})().catch(error => {
  console.error('Screen probe failed:', error.name, error.code === 'ERR_ASSERTION' ? error.message : '');
  process.exitCode = 1;
});
