// Public VPS smoke test. Reuses production UI and the existing real screen-call assertions.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'../../..'),base='https://univc.duckdns.org';
const fixture=path.join(root,'.prototype/screen-vps-test/accounts.json');
const accounts=JSON.parse(fs.readFileSync(fixture)).accounts;
assert.equal(accounts.length,3);
for(const a of accounts)assert(/^new_(anna|boris|vera)_\d+$/.test(a.username));
process.env.VOICECHAT_VIDEO_TEST='1';
for(const name of ['VOICECHAT_SCREEN_REGRESSION','VOICECHAT_SCREEN_REVOKE_TEST','VOICECHAT_SCREEN_TEST_FLAG','VOICECHAT_SCREEN_FAULT_TEST','VOICECHAT_SCREEN_LOST_REPLY_TEST','VOICECHAT_SCREEN_CONCURRENT_TEST'])delete process.env[name];
const media=require('../../../prototype/check_screen_calls.cjs');
const priorCalls=path.join(root,'prototype/verified-screen-calls-run.json'),priorBytes=fs.readFileSync(priorCalls);
const report={authentication:'preauthenticated disposable sessions issued by real Synapse shared-secret registration; login response fixture only; all subsequent Matrix/API/RTC requests use public HTTPS/WSS',result:'FAIL',run:new Date().toISOString(),origin:base,release_commit:'30e96d299b786006f3408b2f5615b6a5dd8527e1',scope:'published ordinary web with preauthenticated test sessions; real public Matrix/SFU and tab capture; synthetic microphone/camera; two browser participants',android:'NOT_RUN',heavy_load:'NOT_RUN'};
const button=(p,n)=>p.getByRole('button',{name:n,exact:true}).first();
let enabled=true,mediaStarted=false,browser;
const pages=[];
function flag(value) {
 const code=`import fcntl,json,subprocess\nfrom pathlib import Path\nr=Path('/srv/voicechat')\nwith (r/'deploy.lock').open('a') as lock:\n fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)\n current=json.loads((r/'current.json').read_text())\n assert current['manifest']['commit']=='${report.release_commit}'\n script="from pathlib import Path;import os;p=Path('/work/.prototype/screen-enabled');t=p.with_name('screen-preview.pending');os.umask(0o077);t.write_text('${value}\\\\n');t.chmod(0o600);t.replace(p);assert p.read_text().strip()=='${value}'"\n subprocess.run(['docker','exec','-u','10001:10001','voicechat-control-1','python3','-c',script],check=True)\n print('screen flag set: ${value}')\n`;
 execFileSync('ssh',['-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','root@84.200.80.13','python3 -'],{input:code,stdio:['pipe','pipe','pipe']});
}
async function fill(page,label,value) {
 const field=page.getByRole('textbox',{name:label,exact:true});
 for(let attempt=0;attempt<4;attempt++) {
  await page.bringToFront();await field.click();await page.waitForTimeout(200);await page.keyboard.press('ControlOrMeta+A');await page.keyboard.insertText(value);await page.waitForTimeout(200);await page.keyboard.press('Tab');await page.waitForTimeout(200);
  if(await field.inputValue()===value)return;
 }
 throw new Error('Text entry did not settle: '+label);
}

async function login(account) {
 let fixtureLoginBody;
 const context=await browser.newContext({viewport:{width:1280,height:1000}});
 await context.route(base+'/_matrix/client/v3/login',async route=>{fixtureLoginBody=account.session;await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(fixtureLoginBody)});});
 await context.addInitScript(media.syntheticMedia);
 await context.addInitScript(()=>{window.callPeers=[];window.RTCPeerConnection=new Proxy(window.RTCPeerConnection,{construct(t,args){const pc=Reflect.construct(t,args);window.callPeers.push(pc);return pc;}});});
 const page=await context.newPage();pages.push(page);report.stage='login '+pages.length;
 page.on('response',async response=>{
  const url=new URL(response.url());
  if(url.pathname.startsWith('/api/screen/') && response.status()>=400){const body=await response.json().catch(()=>({}));console.log('screen HTTP',url.pathname.split('/').pop(),response.status(),typeof body.error==='string'?body.error:'');}
 });
 await page.goto(base);await page.locator('flt-semantics-placeholder').evaluate(el=>el.click());
 await fill(page,'Имя пользователя',account.username);await fill(page,'Пароль аккаунта',account.password);
 let session;
 for(let attempt=0;attempt<6;attempt++) {
  const logged=page.waitForResponse(r=>new URL(r.url()).pathname==='/_matrix/client/v3/login'&&r.request().method()==='POST');
  await button(page,'Войти').click();const response=await logged,payload=response.request().postDataJSON(),data=fixtureLoginBody||await response.json();
  assert(payload.password===account.password && payload.identifier.user===account.username,'Browser input must reach login model');
  if(response.status()===429){console.log('Respecting public login rate limit',data.retry_after_ms);await page.waitForTimeout((data.retry_after_ms||5000)+500);continue;}
  assert.equal(response.status(),200,'Browser login status '+response.status()+' '+data.errcode);session=data;break;
 }
 assert(session,'Public login retries exhausted');
 await button(page,'Я сохранил ключ').waitFor({timeout:60000});await button(page,'Я сохранил ключ').click();await button(page,'Настройки').waitFor({timeout:60000});
 console.log('Published browser session bootstrap '+pages.length+' complete');return {page,session};
}
async function verify(a,b,peer) {
 await button(a,'Настройки').click();await a.getByRole('button',{name:/^Проверить устройства/}).click();
 const escaped=peer.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');await a.getByRole('button',{name:new RegExp(escaped)}).first().click();
 if(await button(b,'Открыть').isVisible())await button(b,'Открыть').click();
 await button(b,'Принять проверку').waitFor({timeout:30000});await button(b,'Принять проверку').click();
 await button(a,'Сравнить эмодзи').waitFor({timeout:30000});await button(a,'Сравнить эмодзи').click();
 for(const p of [a,b])await button(p,'Совпадают').waitFor({timeout:30000});
 for(const p of [a,b]){await p.getByText('Код',{exact:true}).click();await p.getByRole('alertdialog').getByText(/\b\d{4}\s+\d{4}\s+\d{4}\b/).last().waitFor({timeout:10000});}
 const code=async p=>(await p.getByRole('alertdialog').ariaSnapshot()).match(/\d{4}\s+\d{4}\s+\d{4}/)?.[0].replace(/\s+/g,' ');
 const first=await code(a),second=await code(b);report.sas_numbers_present=!!first&&!!second;report.sas_numbers_match=first===second;assert(first&&second);assert.equal(first,second,'Independent SAS numbers must match');
 for(const p of [a,b])await button(p,'Совпадают').click();
 for(const p of [a,b]){await p.getByText('Устройство подтверждено',{exact:true}).waitFor({timeout:30000});await button(p,'Закрыть').click();}
 report.test_peer_devices_sas_verified=true;
}

async function reach(page,name) {
 await page.bringToFront();
 for(let attempt=0;attempt<15;attempt++) {
  const control=button(page,name),box=await control.boundingBox(),header=await button(page,'Свернуть звонок').boundingBox(),footer=await button(page,'Завершить').boundingBox();
  if(box&&header&&footer&&box.y>=header.y+header.height&&box.y+box.height<=footer.y)return;
  await page.mouse.move(640,500);await page.mouse.wheel(0,140);await page.waitForTimeout(150);
 }
 assert.fail('Screen control must be reachable: '+name);
}
async function basicScreen(a,b,transport) {
 const sources=[];
 try {
  for(const p of [a,b]){await p.bringToFront();await button(p,'Показать экран').waitFor({timeout:30000});let sample;for(let i=0;i<100;i++){sample=await media.audio(p);if(sample.packets>0&&sample.frames>0)break;await p.waitForTimeout(200);}assert(sample.packets>0&&sample.frames>0);}
  for(const [i,p] of [a,b].entries())sources.push(await media.captureSource(p,i));
  await media.selectSource(sources,0);await reach(a,'Показать экран');await button(a,'Показать экран').click();await button(a,'Остановить показ').waitFor({timeout:30000});
  await media.pixels(b);const before=await media.audio(b);report.initial_source_pixels=true;
  await b.screenshot({path:path.join(__dirname,transport+'-screen.png')});
  await media.selectSource(sources,1);await reach(b,'Перехватить экран');await button(b,'Перехватить экран').click();await button(b,'Остановить показ').waitFor({timeout:30000});await media.pixels(a,true,[201,97,49]);
  await a.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'));
  await reach(b,'Остановить показ');await button(b,'Остановить показ').click();await a.waitForFunction(()=>!window.screenCaptureTracks.some(t=>t.readyState==='live'));await b.waitForFunction(()=>!window.screenCaptureTracks.some(t=>t.readyState==='live'));await media.pixels(a,false,[201,97,49]);
  await b.bringToFront();let after;
  for(let i=0;i<100;i++){after=await media.audio(b);if(after.packets>before.packets&&after.frames>before.frames)break;await b.waitForTimeout(200);}
  assert.deepEqual(after.voicePeers,before.voicePeers);assert(after.packets>before.packets&&after.frames>before.frames);
  report.calls??={};report.calls[transport]={result:'PASS',real_tab_capture:true,decoded_source_pixels:true,distinct_takeover_source_pixels:true,old_capture_stopped:true,stop_releases_capture:true,voice_packets_and_camera_frames_continue:true,voice_peer_connections_unchanged:true};
  console.log('PASS:',transport,'public screen, takeover, stop and voice/camera continuity');
 } finally {for(const source of sources)await source.close();}
}

async function closeCall(a,b,transport) {
 await a.bringToFront();await button(a,'Завершить').click();
 if(transport==='group'){await b.bringToFront();await button(b,'Завершить').click();}
 for(const p of [a,b]){await button(p,'Закрыть').waitFor({timeout:15000});await button(p,'Закрыть').click();}
}
(async()=>{
 const js=await fetch(base+'/main.dart.js');assert.equal(js.status,200);report.main_dart_js_sha256=crypto.createHash('sha256').update(Buffer.from(await js.arrayBuffer())).digest('hex');assert.equal(report.main_dart_js_sha256,'6c3e65baf91c5e39955a36afe6520fae166e8bc904676b1f0aa6cd8d27594caa');
 assert.equal(js.headers.get('cross-origin-opener-policy'),'same-origin');assert.equal(js.headers.get('cross-origin-embedder-policy'),'require-corp');
 browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',args:['--enable-usermedia-screen-capturing','--auto-select-tab-capture-source-by-title=VoiceChat Screen Source','--autoplay-policy=no-user-gesture-required']});report.browser=browser.version();
 const first=await login(accounts[0]),second=await login(accounts[1]),a=first.page,b=second.page;
 const before=await a.evaluate(async token=>(await fetch('/api/screen/capabilities',{headers:{Authorization:'Bearer '+token}})).json(),first.session.access_token);assert.equal(typeof before.screen,'boolean');report.authenticated_capability_before=before.screen;
 report.stage='open direct chats';
 for(const [p,peer] of [[a,accounts[1]],[b,accounts[0]]]){await p.getByRole('button',{name:/^Люди(?: \d+)?$/}).click();await p.getByRole('button',{name:new RegExp(peer.username)}).first().click();}
 report.stage='encrypted preflight messages';
 const text='VPS screen test '+Date.now();await fill(a,'Написать сообщение…',text);await button(a,'Отправить').click();await b.getByRole('group',{name:new RegExp(text)}).waitFor({timeout:30000});
 await fill(b,'Написать сообщение…',text+' reply');await button(b,'Отправить').click();await a.getByRole('group',{name:new RegExp(text+' reply')}).waitFor({timeout:30000});
 report.stage='SAS trust';await verify(a,b,second.session.user_id);
 flag(1);enabled=true;mediaStarted=true;
 const cap=await a.evaluate(async token=>(await fetch('/api/screen/capabilities',{headers:{Authorization:'Bearer '+token}})).json(),first.session.access_token);assert.equal(cap.screen,true);assert.equal(cap.protocol_version,1);report.authenticated_capability_after=true;
 console.log('Enabled screen preview on existing release; checking direct call');
 await a.bringToFront();await button(a,'Видеозвонок').click();await button(b,'Принять').waitFor({timeout:30000});await b.bringToFront();await button(b,'Принять').click();
 report.stage='direct screen';await basicScreen(a,b,'direct');await closeCall(a,b,'direct');
 console.log('Checking group call');
 for(const p of [a,b]){await p.getByRole('button',{name:/^Группы(?: \d+)?$/}).click();await p.getByRole('button',{name:/Семейный круг/}).first().click();await p.waitForTimeout(500);}
 report.stage='group invitation';
 const groupRoom=JSON.parse(fs.readFileSync(fixture)).rooms.find(r=>r.name==='Семейный круг').room_id;
 const groupAdmission=p=>p.waitForResponse(r=>new URL(r.url()).pathname==='/api/token'&&r.status()===200&&r.request().postDataJSON().room_id===groupRoom,{timeout:30000});
 const admitted=groupAdmission(a);await a.bringToFront();await button(a,'Видеозвонок').click();await admitted;
 await button(b,'Принять').waitFor({timeout:30000});const joined=groupAdmission(b);await b.bringToFront();await button(b,'Принять').click();await joined;report.both_group_sfu_admissions_confirmed=true;
 report.stage='group screen';await basicScreen(a,b,'group');await closeCall(a,b,'group');
 assert.equal(report.calls.direct.result,'PASS');assert.equal(report.calls.group.result,'PASS');report.result='PASS';
})().catch(async error=>{report.failure=error.name+': '+String(error.message).split('\n')[0];console.error(report.stage,report.failure);for(const p of pages)console.error('Visible controls:',await p.getByRole('button').allTextContents().catch(()=>[]));process.exitCode=1;}).finally(async()=>{
 if(browser)await browser.close();fs.writeFileSync(priorCalls,priorBytes);
 let cleaned=0;
 try {
 const cleanup=fs.readFileSync(path.join(__dirname,'cleanup.py'));
 const cleanedReport=JSON.parse(execFileSync('ssh',['-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','root@84.200.80.13','docker exec -i voicechat-synapse-1 python3 -'],{input:cleanup,stdio:['pipe','pipe','pipe']}).toString());
 assert(cleanedReport.temporary_cleanup_admin_deactivated && cleanedReport.private_admin_file_removed);
 report.temporary_cleanup_admin_deactivated=true;cleaned=cleanedReport.deactivated;
 const users=accounts.map(a=>a.user_id);for(const user of users)assert(/^@new_(anna|boris|vera)_[0-9]+:univc\.duckdns\.org$/.test(user));
 const verifyCleanup="import subprocess\nusers="+JSON.stringify(users)+"\nquery=\"SELECT COUNT(*) FROM users WHERE name IN (\"+','.join(\"'\"+u+\"'\" for u in users)+\") AND deactivated::text IN ('1','t','true')\"\nprint(subprocess.check_output(['docker','exec','voicechat-postgres-1','psql','-U','synapse','-d','synapse','-At','-c',query],text=True).strip())\n";
 cleaned=Number(execFileSync('ssh',['-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','root@84.200.80.13','python3 -'],{input:verifyCleanup,stdio:['pipe','pipe','pipe']}).toString().trim());
 } catch(error) {fs.writeFileSync(path.join(root,'.prototype/screen-vps-test/cleanup-error.txt'),error.stderr||String(error),{mode:0o600});console.error('Remote disposable account cleanup needs retry');}
 report.disposable_accounts_deactivated=cleaned;
 if(cleaned!==accounts.length){report.result='FAIL';process.exitCode=1;}
 if(report.result!=='PASS'&&mediaStarted){flag(0);enabled=false;}
 report.screen_enabled_for_owner_test=enabled;
 fs.writeFileSync(path.join(__dirname,'verification.json'),JSON.stringify(report,null,2)+'\n');
 console.log(report.result+': screen VPS check; test accounts deactivated '+cleaned);
});
