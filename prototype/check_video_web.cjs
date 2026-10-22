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
    let background=false, returned=false, sasAccepted=false, sasCompared=false, qrTransferred=false, qrCompared=false;
    const actors=new Map();
    const adb=(...args)=>execFileSync('/tmp/voicechat-android-sdk/platform-tools/adb', ['-s','emulator-5554',...args],{stdio:'pipe',timeout:15000});
    const androidUi=()=>adb('shell','-tt','uiautomator','dump','/dev/tty').toString();
    const nativeTap=(xml,label)=>{
      const node=[...xml.matchAll(/<node\b[^>]*>/g)].map(m=>m[0]).find(node=>node.includes(`text="${label}"`) || node.includes(`content-desc="${label}"`));
      assert(node,'Native verification button unavailable: '+label);
      const bounds=node.match(/bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/).slice(1).map(Number);
      adb('shell','input','tap',String(Math.round((bounds[0]+bounds[2])/2)),String(Math.round((bounds[1]+bounds[3])/2)));
    };
    for(const role of ['web','carol']) {
      const context=await browser.newContext({permissions:['camera','microphone'],viewport:{width:1280,height:900}});
      const page=await context.newPage();
      actors.set(role,page);
      page.on('console',message=>{if(message.text().startsWith('VIDEO FAILED:')) console.log(message.text());});
      await page.goto('http://localhost:7358/'+(role==='carol' ? '?role=carol' : ''));
    }
    for(let attempt=0;attempt<360;attempt++) {
      const response=await fetch('http://localhost:8090/reports');
      assert(response.ok,'Report service unavailable');
      const stages=new Set((await response.json()).filter(r=>r.run===run).map(r=>r.stage));
      assert(!stages.has('failed'),'A platform rejected video acceptance');
      if(stages.has('video_qr_invited_1') && !sasAccepted) {
        nativeTap(androidUi(),'Принять проверку');sasAccepted=true;
      }
      if(stages.has('video_qr_codes_0') && stages.has('video_qr_codes_1') && !qrTransferred) {
        const code=actors.get('web').getByText('QR для текущей проверки устройства',{exact:false});
        const bounds=await code.boundingBox();assert(bounds && bounds.width>100,'Visible live QR required');
        const png=await actors.get('web').screenshot({clip:bounds});
        execFileSync('/tmp/voicechat-android-sdk/platform-tools/adb',['-s','emulator-5554','shell','-T','run-as','dev.voicechat.voicechat_probe','sh','-c',"'cat > databases/voicechat-live-qr.png'"],{input:png,stdio:['pipe','pipe','pipe'],timeout:15000});
        qrTransferred=true;
      }
      if(stages.has('video_qr_scanned_1') && !qrCompared) {
        const alice=actors.get('web');
        await alice.getByRole('button',{name:'Вижу успешное сканирование',exact:true}).click();
        await alice.getByText('Устройство подтверждено',{exact:true}).waitFor({timeout:30000});
        let confirmed;
        for(let i=0;i<10;i++) {confirmed=androidUi();if(confirmed.includes('Устройство подтверждено')) break;}
        assert(confirmed.includes('Устройство подтверждено'),'Native QR verification did not complete');
        nativeTap(confirmed,'Закрыть');await alice.getByRole('button',{name:'Закрыть',exact:true}).click();
        qrCompared=true;
      }
      if(stages.has('video_sas_invited_1') && !sasAccepted) {
        nativeTap(androidUi(),'Принять проверку');
        sasAccepted=true;
      }
      if(stages.has('video_sas_codes_0') && stages.has('video_sas_codes_1') && !sasCompared) {
        const alice=actors.get('web');
        const code=/\d{4}\s+\d{4}\s+\d{4}/;
        const webCode=(await alice.getByRole('alertdialog').ariaSnapshot()).match(code);
        let native=androidUi(), nativeCode=native.match(code);
        if(!nativeCode) {
          adb('shell','input','swipe','155','370','155','200','400');
          native=androidUi(); nativeCode=native.match(code);
        }
        assert(webCode && nativeCode && webCode[0].replace(/\s+/g,' ')==nativeCode[0].replace(/\s+/g,' '),'Android/web SAS did not match');
        await alice.getByRole('button',{name:'Совпадают',exact:true}).click();
        nativeTap(native,'Совпадают');
        await alice.getByText('Устройство подтверждено',{exact:true}).waitFor({timeout:30000});
        let confirmed;
        for(let i=0;i<10;i++) { confirmed=androidUi(); if(confirmed.includes('Устройство подтверждено')) break; }
        assert(confirmed.includes('Устройство подтверждено'),'Native SAS did not complete');
        nativeTap(confirmed,'Закрыть');
        await alice.getByRole('button',{name:'Закрыть',exact:true}).click();
        sasCompared=true;
      }
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
    try {
      execFileSync('/tmp/voicechat-android-sdk/platform-tools/adb',['-s','emulator-5554','shell','run-as','dev.voicechat.voicechat_probe','rm','-f','cache/voicechat-live-qr.png','databases/voicechat-live-qr.png'],{stdio:'pipe',timeout:15000});
    } catch(error) {if(!error.stderr?.toString().includes('unknown package')) throw error;}
    execFileSync('/tmp/voicechat-android-sdk/platform-tools/adb',['-s','emulator-5554','shell','settings','put','global','always_finish_activities','0'],{stdio:'pipe',timeout:15000});
    await browser.close();
  }
})().catch(error=>{console.error(error.message);process.exitCode=1;});
