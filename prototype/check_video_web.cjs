// Keep two isolated, synthetic-media web clients alive while Android completes the same run.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');
const {execFileSync} = require('node:child_process');
(async()=>{
  const root=path.join(__dirname,'..');
  const run=JSON.parse(fs.readFileSync(path.join(root,'.prototype/web.json'))).RUN_ID;
  assert(typeof run==='string' && run.length<=64,'Fresh video fixture required');
  const browser=await chromium.launch({executablePath:process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,
    args:['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream','--autoplay-policy=no-user-gesture-required']});
  try {
    let background=false, returned=false;
    const adb=(...args)=>execFileSync('/tmp/voicechat-android-sdk/platform-tools/adb', ['-s','emulator-5554',...args],{stdio:'pipe',timeout:15000});
    for(const role of ['web','carol']) {
      const context=await browser.newContext({permissions:['camera','microphone'],viewport:{width:1280,height:900}});
      const page=await context.newPage();
      page.on('console',message=>{if(message.text().startsWith('VIDEO FAILED:')) console.log(message.text());});
      await page.goto('http://localhost:7358/'+(role==='carol' ? '?role=carol' : ''));
    }
    for(let attempt=0;attempt<360;attempt++) {
      const response=await fetch('http://localhost:8090/reports');
      assert(response.ok,'Report service unavailable');
      const stages=new Set((await response.json()).filter(r=>r.run===run).map(r=>r.stage));
      assert(!stages.has('failed'),'A platform rejected video acceptance');
      if(stages.has('video_background_ready') && !background) {
        adb('shell','settings','put','global','always_finish_activities','1');
        adb('shell','input','keyevent','KEYCODE_HOME');
        background=true;
      }
      if(background && !returned && [0,1,2].every(i=>stages.has(`video_background_audio_${i}`))) {
        const service=adb('shell','dumpsys','activity','services','dev.voicechat.voicechat_probe').toString();
        assert(service.includes('CallService') && service.includes('isForeground=true'),'No foreground microphone service');
        adb('shell','settings','put','global','always_finish_activities','0');
        adb('shell','am','start','-n','dev.voicechat.voicechat_probe/.MainActivity');
        returned=true;
      }
      if([0,1,2].every(i=>stages.has(`video_done_${i}`))) { console.log('PASS: both web actors completed Android video acceptance'); return; }
      await new Promise(resolve=>setTimeout(resolve,1000));
    }
    assert.fail('Video actors timed out');
  } finally {
    execFileSync('/tmp/voicechat-android-sdk/platform-tools/adb',['-s','emulator-5554','shell','settings','put','global','always_finish_activities','0'],{stdio:'pipe',timeout:15000});
    await browser.close();
  }
})().catch(error=>{console.error(error.message);process.exitCode=1;});
