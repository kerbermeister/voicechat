// Own headless browser; synthetic camera/mic, real Matrix/Olm/SFU/media decryption.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');

(async () => {
  const root = path.resolve(__dirname, '..');
  const config = JSON.parse(fs.readFileSync(path.join(root, '.prototype/web.json'), 'utf8'));
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true, args: ['--autoplay-policy=no-user-gesture-required'],
  });
  try {
    for (const role of (process.env.STREAM_VIEWER_NATIVE === '1' ? ['owner'] : ['owner', 'viewer'])) {
      const context = await browser.newContext({permissions: ['camera', 'microphone'], viewport: {width: 900, height: 900}});
      await context.addInitScript(() => {
        navigator.mediaDevices.getUserMedia = async constraints => {
          const stream = new MediaStream();
          if (constraints.video) {
            const canvas = document.createElement('canvas');
            const width = constraints.video.width, height = constraints.video.height;
            canvas.width = typeof width === 'number' ? width : width?.ideal || 640;
            canvas.height = typeof height === 'number' ? height : height?.ideal || 360;
            const draw = canvas.getContext('2d');
            const timer = setInterval(() => {
              draw.fillStyle = '#226633'; draw.fillRect(0, 0, canvas.width, canvas.height);
              draw.fillStyle = '#ffffff'; draw.font = '24px sans-serif'; draw.fillText(String(Date.now()), 10, 50);
            }, 100);
            const track = canvas.captureStream(10).getVideoTracks()[0];
            const stop = track.stop.bind(track);
            track.stop = () => { clearInterval(timer); stop(); };
            stream.addTrack(track);
          }
          if (constraints.audio) {
            const audio = new AudioContext(); const tone = audio.createOscillator();
            const destination = audio.createMediaStreamDestination();
            tone.connect(destination); tone.start();
            const track = destination.stream.getAudioTracks()[0], stop = track.stop.bind(track);
            track.stop = () => { tone.stop(); audio.close(); stop(); };
            stream.addTrack(track);
          }
          return stream;
        };
      });
      const page = await context.newPage();
      page.on('pageerror', error => {
        let message = error.message;
        for (const [key, value] of Object.entries(config)) {
          if (key.includes('PASSWORD') && typeof value === 'string') message = message.split(value).join('[redacted]');
        }
        console.log(role + ' pageerror: ' + message.slice(0, 200));
      });
      await page.goto(`http://localhost:7358/?role=${role}`);
    }
    const deadline = Date.now() + 240000;
    let last = [];
    while (Date.now() < deadline) {
      const response = await fetch('http://127.0.0.1:8090/reports');
      last = (await response.json()).filter(row => row.run === config.RUN_ID && row.role.startsWith('stream-'));
      const failed = last.find(row => row.stage === 'failed');
      assert(!failed, failed ? JSON.stringify(failed) : '');
      if (['stream-owner', 'stream-viewer'].every(role => last.some(row => row.role === role && row.stage === 'complete'))) {
        const result = {result: 'PASS', browser: browser.version(), source: 'local worktree', native_viewer: process.env.STREAM_VIEWER_NATIVE === '1',
          matrix: 'real local disposable accounts', media: 'synthetic input, real E2EE decoded frames',
          stages: last.map(({role, stage}) => ({role, stage})), physical_android: false, physical_iphone: false};
        fs.writeFileSync(path.join(root, process.env.STREAM_VIEWER_NATIVE === '1' ? '.prototype/stream-android-web-result.json' : '.prototype/stream-web-result.json'), JSON.stringify(result, null, 2));
        console.log(JSON.stringify(result, null, 2));
        return;
      }
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
    throw new Error('Stream smoke timed out: ' + JSON.stringify(last.map(({role, stage}) => ({role, stage}))));
  } finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
