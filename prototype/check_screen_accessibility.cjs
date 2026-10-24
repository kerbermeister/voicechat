// Real browser accessibility tree + production widgets; synthetic UI states only.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {chromium,firefox,webkit}=require('playwright');
const root=path.join(__dirname,'..'),url='http://localhost:7358/';
const report={result:'FAIL',run:new Date().toISOString(),scope:'production CallWindow/ScreenPanel; synthetic call states, no credentials/media/network',
  screen_reader:'separate native VoiceOver record',android:'NOT_RUN',heavy_load:'NOT_RUN',browsers:{}};
async function launch(name) {
  if(name==='firefox')return firefox.launch({headless:true});
  if(name==='webkit')return webkit.launch({headless:true});
  const executablePath=name==='edge' ? fs.readFileSync('/tmp/voicechat-screen-browsers/edge-path','utf8').trim()+'/Contents/MacOS/Microsoft Edge' : '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  return chromium.launch({headless:true,executablePath});
}
const button=(p,name)=>p.getByRole('button',{name,exact:true});
async function status(page) {
  return page.evaluate(()=>window.liveMessages);
}
(async()=>{
  report.lab_source_sha256=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'apps/client/lib/lab_screen_accessibility_main.dart'))).digest('hex');
  report.lab_js_sha256=crypto.createHash('sha256').update(Buffer.from(await(await fetch(url+'main.dart.js')).arrayBuffer())).digest('hex');
  for(const name of ['chrome','edge','firefox','webkit']) {
    const browser=await launch(name),result=report.browsers[name]={result:'FAIL',version:browser.version(),viewports:[]};
    try {
      const page=await browser.newPage();let network=0;
      page.on('request',r=>{if(!r.url().startsWith(url) && !r.url().startsWith('blob:') && !r.url().startsWith('data:'))network++;});
      await page.goto(url);
      await page.locator('flt-semantics-placeholder').evaluate(el=>el.click());
      await button(page,'Открыть проверочный звонок').waitFor({timeout:60000});
      // Flutter announces through a temporary text node, then clears it.
      await page.evaluate(()=>{
        window.liveMessages=[];
        new MutationObserver(()=>document.querySelectorAll('[aria-live="polite"]').forEach(el=>{
          if(el.textContent.trim())window.liveMessages.push(el.textContent.trim());
        })).observe(document.body,{subtree:true,childList:true,characterData:true});
      });
      for(const size of [{width:320,height:640},{width:640,height:320},{width:1280,height:900}]) {
        await page.setViewportSize(size);await page.waitForTimeout(300);
        await button(page,'Открыть проверочный звонок').click();
        const dialog=page.getByRole('alertdialog');await dialog.waitFor();
        const end=await button(page,'Завершить').boundingBox();assert(end && end.y>=0 && end.y+end.height<=size.height+1 && end.width>=24 && end.height>=24);
        const takeover=button(page,'Перехватить экран');
        await page.evaluate(()=>window.liveMessages=[]);
        await takeover.click();await page.mouse.move(2,2);
        await page.waitForFunction(()=>window.liveMessages.some(s=>s.includes('Показ не начат.')));
        assert((await status(page)).some(s=>s.includes('Показ не начат.') && s.includes('Экран показывает:')),'Capture failure must be part of live status');
        await button(page,'Развернуть экран').click();await button(page,'Вернуться в звонок').waitFor();
        await page.mouse.move(2,2);
        await page.waitForTimeout(400); // Finish the modal route transition before Escape.
        await page.keyboard.press('Escape');await button(page,'Вернуться в звонок').waitFor({state:'hidden'});
        await page.mouse.move(2,2);
        await page.waitForTimeout(400);
        assert(await dialog.isVisible(),'Escape from fullscreen must retain the call dialog');
        await page.keyboard.press('Escape');await dialog.waitFor({state:'hidden'});
        result.viewports.push([size.width,size.height]);
      }
      await page.setViewportSize({width:1280,height:900});
      await button(page,'Зритель').click();await page.getByRole('menuitem',{name:'Восстановление',exact:true}).click();
      await button(page,'Открыть проверочный звонок').click();
      assert(await button(page,'Перехватить экран').isDisabled());
      assert((await page.locator('flt-semantics-host').innerText()).includes('Восстанавливаем демонстрацию'));
      await page.mouse.move(2,2);await page.waitForTimeout(400);
      await page.keyboard.press('Escape');
      await page.getByRole('alertdialog').waitFor({state:'hidden'});
      await button(page,'Восстановление').click();await page.getByRole('menuitem',{name:'Ведущий',exact:true}).click();
      await button(page,'Открыть проверочный звонок').click();
      await button(page,'Экран: Авто').click();await page.getByRole('menuitem',{name:'Экран: Низкое',exact:true}).click();
      await page.mouse.move(2,2);await button(page,'Экран: Низкое').waitFor();
      await page.evaluate(()=>window.liveMessages=[]);
      await button(page,'Остановить показ').click();await page.mouse.move(2,2);
      await page.waitForFunction(()=>window.liveMessages.some(s=>s.includes('Показ остановлен.')));
      assert((await status(page)).some(s=>s.includes('Показ остановлен.')));
      await button(page,'Завершить').click();await page.mouse.move(2,2);
      await button(page,'Закрыть').click();
      assert.equal(network,0,'UI fixture must not access Matrix/SFU or other origins');
      Object.assign(result,{result:'PASS',live_error_and_status:true,fullscreen_escape_preserves_call:true,
        named_controls_and_disabled_reconnect:true,quality_selection_and_stop:true,no_backend_or_media_requests:true});
    } finally {await browser.close();}
  }
  report.result='PASS';console.log('PASS: four browser accessibility trees, dialogs, errors and controls');
})().catch(error=>{console.error(error.stack);process.exitCode=1;}).finally(()=>{
  fs.writeFileSync(path.join(__dirname,'verified-screen-accessibility-browsers-run.json'),JSON.stringify(report,null,2)+'\n');
});
