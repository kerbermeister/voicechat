// SS-16: ordinary UI and rendered Flutter Canvas, disposable users only.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {PNG}=require('pngjs');
const crypto=require('node:crypto');
const media=require('./check_screen_calls.cjs');
const report={result:'FAIL',run:new Date().toISOString(),
  scope:'clean ordinary web client; local Matrix/SFU; real tab capture; synthetic microphone/camera',
  android:'NOT_RUN',heavy_load:'NOT_RUN',screen_reader:'NOT_RUN'};
const output=path.join(__dirname,'verified-screen-regression-run.json');
const save=()=>fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');
async function inside(page,locator) {
  const r=await locator.boundingBox(),v=page.viewportSize();
  assert(r && r.width>0 && r.height>0 && r.x>=-1 && r.y>=-1 &&
    r.x+r.width<=v.width+1 && r.y+r.height<=v.height+1,'Required control must fit the viewport');
}
module.exports=async({a,b,bob,button,fill})=>{
  report.main_dart_js_sha256=crypto.createHash('sha256').update(Buffer.from(await
    (await fetch(new URL('main.dart.js',process.env.VOICECHAT_UI_URL))).arrayBuffer())).digest('hex');
  save();
  async function attachment(label) {
    const payload=Buffer.from('SS-16 encrypted attachment '+label+'\n'),name='ss16-'+label+'.txt';
    const chooser=a.waitForEvent('filechooser');
    await button(a,'Прикрепить файл или видео').click();
    await a.getByRole('menuitem',{name:'Файл',exact:true}).click();
    await (await chooser).setFiles({name,mimeType:'text/plain',buffer:payload});
    await button(a,'Отправить').click();
    await b.getByRole('group',{name:new RegExp(name)}).waitFor({timeout:30000});
    await b.evaluate(()=>{window.savedBytes=[];window.showSaveFilePicker=async()=>({createWritable:async()=>({
      write:async bytes=>window.savedBytes.push(...bytes),close:async()=>{},abort:async()=>{window.savedBytes=[];}})});});
    await button(b,'Сохранить файл').last().click();
    await b.waitForFunction(()=>window.savedBytes.length>0);
    assert.deepEqual(Buffer.from(await b.evaluate(()=>window.savedBytes)),payload);
  }
  await attachment('direct');
  for(const p of [a,b]) {
    await p.getByRole('button',{name:/^Группы(?: \d+)?$/}).click();
    await p.getByRole('button',{name:/^Согласие на группу /}).click();
  }
  const text='SS-16 сообщение в группе';
  await fill(a,'Написать сообщение…',text);await button(a,'Отправить').click();
  await b.getByRole('group',{name:new RegExp(text)}).waitFor({timeout:30000});
  await attachment('group');
  report.direct_and_group_attachment_bytes_match=true;
  report.group_text_decrypted_in_ordinary_ui=true;
  const themes=[['lavender','Lavender Soft'],['ocean','Ocean Calm'],['midnight','Midnight'],
    ['lagoon','Лагуна'],['reef','Коралловый риф'],['bioluminescence','Биолюминесценция'],['sunset','Закат в бухте']];
  const dominant=[];
  async function theme(id,label) {
    await a.bringToFront();
    await a.getByRole('button',{name:/^Настройки(?: Настройки)?$/}).click();
    await button(a,'Цветовая схема').click();
    await a.getByRole('menuitem',{name:label,exact:true}).click();
    await a.waitForFunction(id=>localStorage.getItem('flutter.palette')===JSON.stringify(id),id);
    await button(a,'Закрыть').click();await a.mouse.move(1,1);await a.waitForTimeout(300);
  }
  for(const [id,label] of themes) {
    await theme(id,label);
    const png=PNG.sync.read(await a.screenshot()),counts=new Map();let dark=0,light=0;
    for(let i=0;i<png.data.length;i+=4) {
      const [r,g,b]=png.data.subarray(i,i+3),k=[r,g,b].join(',');
      counts.set(k,(counts.get(k)||0)+1);
      if(Math.max(r,g,b)<100)dark++;if(Math.min(r,g,b)>200)light++;
    }
    if(['midnight','bioluminescence'].includes(id))assert(dark>png.width*png.height*.45);
    else assert(light>png.width*png.height*.4);
    dominant.push([...counts].sort((a,b)=>b[1]-a[1])[0][0]);
  }
  assert.equal(new Set(dominant).size,7,'Every palette must change rendered pixels');
  await theme('midnight','Midnight');
  for(const size of [{width:320,height:640},{width:390,height:844},{width:640,height:320}]) {
    await a.setViewportSize(size);
    await a.bringToFront();await a.waitForTimeout(400);
    const field=a.getByRole('textbox',{name:'Написать сообщение…',exact:true});
    await inside(a,field);await inside(a,button(a,'Позвонить').or(button(a,'Видеозвонок')).first());
  }
  await a.setViewportSize({width:1280,height:1000});
  for(const p of [a,b])await p.getByRole('button',{name:/^Люди(?: \d+)?$/}).click();
  await a.getByRole('button',{name:new RegExp(bob.username)}).click();
  // AnimatedSwitcher briefly retains both chat semantics after a resize/navigation.
  for(let i=0;i<30 && await button(a,'Видеозвонок').count()!==1;i++)await a.waitForTimeout(100);
  assert.equal(await button(a,'Видеозвонок').count(),1);
  report.seven_themes_render_and_persist=true;
  report.keyboard_focus='Flutter widget test; browser screen reader not accepted';
  report.chat_viewports=[[320,640],[390,844],[640,320]];
  report.call_palettes=['Midnight','Lavender Soft'];save();
  console.log('SS-16: ordinary encrypted messages/files, seven palettes and narrow chat controls PASS');
};
module.exports.callLayout=async(a,b,button,transport)=>{
  async function screenAction(page,name) {
    const control=button(page,name),v=page.viewportSize();
    for(let i=0;i<10;i++) {
      const r=await control.boundingBox(),header=await button(page,'Свернуть звонок').boundingBox(),
        footer=await button(page,'Завершить').boundingBox();
      if(r && r.y>=header.y+header.height && r.y+r.height<=footer.y) {
        await inside(page,control);return;
      }
      await page.mouse.move(v.width/2,v.height*.55);await page.mouse.wheel(0,100);
      await page.waitForTimeout(150);
    }
    assert.fail('Screen action must be reachable by scrolling the call content');
  }
  const before=await media.audio(b);
  await a.bringToFront();
  await button(a,'Выключить камеру').click();
  await a.mouse.move(5,5);
  await a.waitForFunction(()=>!window.callPeers.flatMap(pc=>pc.getSenders()).some(s=>
    s.track?.kind==='video' && !s.track.getSettings().displaySurface && s.track.enabled && s.track.readyState==='live'));
  await media.pixels(b);await a.bringToFront();await button(a,'Включить камеру').click();
  await a.mouse.move(5,5);
  await a.waitForFunction(()=>window.callPeers.flatMap(pc=>pc.getSenders()).some(s=>
    s.track?.kind==='video' && !s.track.getSettings().displaySurface && s.track.enabled && s.track.readyState==='live'));
  await button(a,'Выключить микрофон').click();
  await a.mouse.move(5,5);
  await a.waitForFunction(()=>!window.callPeers.flatMap(pc=>pc.getSenders()).some(s=>
    s.track?.kind==='audio' && s.track.enabled && s.track.readyState==='live'));
  await media.pixels(b);await a.bringToFront();await button(a,'Включить микрофон').click();
  await a.mouse.move(5,5);
  await a.waitForFunction(()=>window.callPeers.flatMap(pc=>pc.getSenders()).some(s=>
    s.track?.kind==='audio' && s.track.enabled && s.track.readyState==='live'));
  for(const size of transport==='group' ? [{width:320,height:640},{width:390,height:844},{width:640,height:320}] : []) {
    for(const p of [a,b]) {
      await p.setViewportSize(size);await p.bringToFront();await p.waitForTimeout(400);
      await inside(p,button(p,'Завершить'));
      await screenAction(p,p===a ? 'Остановить показ' : 'Перехватить экран');
      await inside(p,button(p,'Завершить'));
    }
    await screenAction(b,'Развернуть экран');
    await button(b,'Развернуть экран').click();
    await inside(b,button(b,'Вернуться в звонок'));
    await button(b,'Вернуться в звонок').click();
  }
  for(const p of [a,b])await p.setViewportSize({width:1280,height:1000});
  await media.pixels(b);
  // SFU republishing creates a new RTP stream with counters starting at zero.
  const resumed=await media.audio(b);let after=resumed;
  for(let i=0;i<200;i++) {
    await b.waitForTimeout(100);after=await media.audio(b);
    if(after.packets>resumed.packets && after.frames>resumed.frames)break;
  }
  assert(after.packets>resumed.packets && after.frames>resumed.frames,'Voice/camera must resume on the new RTP streams');
  assert.deepEqual(after.voicePeers,before.voicePeers);
  report.call_controls={...report.call_controls,[transport]:{camera_off_on:true,mute_unmute:true,screen_pixels_continue:true}};
  if(transport==='group') {
    report.live_screen_viewports=[[320,640],[390,844],[640,320]];
    report.resizing_and_fullscreen_preserve_voice_camera_and_screen=true;
  }
  save();
};
module.exports.finish=(passed,cleaned)=>{
  report.cleanup_accounts_deactivated=cleaned;
  if(passed && cleaned===3) {
    for(const transport of ['direct','group'])assert(report.call_controls?.[transport]?.camera_off_on &&
      report.call_controls[transport].mute_unmute,'Both transports require real camera/microphone toggles');
    assert(report.live_screen_viewports?.length===3);
    const calls=JSON.parse(fs.readFileSync(path.join(__dirname,'verified-screen-calls-run.json')));
    assert.equal(calls.result,'PASS');report.direct_and_group_video_screen_calls=calls;
    report.unchanged_audio_and_revoke_evidence=['verified-screen-calls-audio-run.json','verified-screen-revoke-run.json'];
    report.result='PASS';
  }
  save();
  if(passed)assert.equal(report.result,'PASS','Regression requires successful cleanup');
};
