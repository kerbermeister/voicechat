// Normal built client, fresh local users, no microphone/camera or production data.
const assert=require('node:assert/strict'),crypto=require('node:crypto'),fs=require('node:fs'),path=require('node:path');
const repo=path.resolve(__dirname,'..');
const prefix=process.env.PIN_ONLY==='1'?'chat30-pin':'chat30-ui';
process.env.WEB_URL ||= 'http://localhost:7358';
process.env.MATRIX_URL ||= 'http://localhost:8008';
const {chromium}=require('playwright');
const {open,first,fill}=require(repo+'/prototype/check_device_link.cjs');
const button=(p,name)=>p.getByRole('button',{name,exact:true});
const matrix=process.env.MATRIX_URL,control=process.env.CONTROL_URL||'http://localhost:8090';
for(const origin of [process.env.WEB_URL,matrix,control]) {
 const url=new URL(origin);
 assert(url.protocol==='http:' && ['localhost','127.0.0.1'].includes(url.hostname),'This fixture is local-only');
}
async function request(base,route,body,token,method=body?'POST':'GET') {
 const r=await fetch(base+route,{method,signal:AbortSignal.timeout(15000),headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},...(body?{body:JSON.stringify(body)}:{})});
 assert(r.ok,`Fixture API ${r.status} ${route}`);return r.json();
}
async function register(role) {
 const secret=JSON.parse(fs.readFileSync(repo+'/.prototype/secrets.json')).registration;
 const username=`chat30_${role}_${Date.now()}`,password=crypto.randomBytes(24).toString('base64url');
 const {nonce}=await request(matrix,'/_synapse/admin/v1/register');
 const mac=crypto.createHmac('sha1',secret).update([nonce,username,password,'notadmin'].join('\0')).digest('hex');
 const created=await request(matrix,'/_synapse/admin/v1/register',{nonce,username,password,admin:false,inhibit_login:true,mac});
 if(created.access_token)await request(matrix,'/_matrix/client/v3/logout',{},created.access_token);
 return {username,password};
}
(async()=>{
 const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--mute-audio']});
 const pages=[];let held=[];
 const deadline=setTimeout(()=>{console.error('Local follow-up UI deadline exceeded');browser.close().catch(()=>{});},300000);
 const proof={source_commit:require('node:child_process').execFileSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).trim(),harness_sha256:crypto.createHash('sha256').update(fs.readFileSync(__filename)).digest('hex'),physical_phone:false};
 try {
  const accounts=[await register('alice'),await register('bob')];
  const contexts=await Promise.all(accounts.map(()=>browser.newContext({viewport:{width:1100,height:900},permissions:[]})));
  for(const context of contexts)pages.push(await open(context));
  const sessions=[];for(let i=0;i<2;i++)sessions.push(await first(pages[i],accounts[i]));
  console.log('PASS: normal web30 automatic profiles and real crypto initialized');
  const [alice,bob]=sessions,[a,b]=pages;
  await request(control,'/contacts',{action:'policy',allow_direct:true},bob.access_token);
  const {room_id}=await request(matrix,'/_matrix/client/v3/createRoom',{is_direct:true,preset:'private_chat',invite:[bob.user_id],initial_state:[
   {type:'m.room.encryption',state_key:'',content:{algorithm:'m.megolm.v1.aes-sha2'}},
   {type:'dev.voicechat.kind',state_key:'',content:{kind:'direct',owner:alice.user_id,peer:bob.user_id}},
   {type:'m.room.history_visibility',state_key:'',content:{history_visibility:'invited'}},
  ]},alice.access_token);
  await request(control,'/contacts',{action:'request',recipient:bob.user_id,room_id},alice.access_token);
  await request(matrix,'/_matrix/client/v3/join/'+encodeURIComponent(room_id),{},bob.access_token);
  for(const [s,peer] of [[alice,bob],[bob,alice]])await request(matrix,'/_matrix/client/v3/user/'+encodeURIComponent(s.user_id)+'/account_data/m.direct',{[peer.user_id]:[room_id]},s.access_token,'PUT');
  for(const [p,peer] of [[a,accounts[1]],[b,accounts[0]]]) {
   await p.getByRole('button',{name:new RegExp(peer.username)}).first().click({timeout:60000});
   await p.getByRole('textbox',{name:'Написать сообщение…',exact:true}).waitFor();
  }
  const text='Сохранённая очередь после минутного таймаута';
  if(process.env.PIN_ONLY!=='1') {
  let sends=0;a.on('request',r=>{if(r.method()==='PUT'&&r.url().includes('/send/m.room.encrypted/'))sends++;});
  await a.route('**/_matrix/client/v3/rooms/**/send/**',route=>{held.push(route);});
  await fill(a,'Написать сообщение…',text);
  await button(a,'Отправить').click();
  await button(a,'Действия с очередью').waitFor({timeout:2000});
  await a.screenshot({path:repo+'/.prototype/'+prefix+'-pending.png'});
  proof.visible_before_network_confirmation=true;
  await fill(a,'Написать сообщение…','Следующий черновик');
  assert.equal(await a.getByRole('textbox',{name:'Написать сообщение…',exact:true}).inputValue(),'Следующий черновик');
  console.log('PASS: pending visible before network confirmation; composer accepts next draft');
  await button(a,'Ошибка отправки: подробности').waitFor({timeout:75000});
  await button(a,'Ошибка отправки: подробности').click();
  await a.getByText('Отправка не подтверждена за минуту.',{exact:true}).waitFor();
  await a.getByRole('alertdialog').getByRole('button',{name:'Закрыть',exact:true}).click();
  proof.minute_deadline_visible=true;
  console.log('PASS: actual one-minute deadline and explanatory failure dialog');
  for(const route of held)await route.abort().catch(()=>{});held=[];
  const before=sends;
  await a.reload();await a.locator('flt-semantics-placeholder').evaluate(el=>el.click());
  await a.getByRole('button',{name:new RegExp(accounts[1].username)}).first().click({timeout:60000});
  await button(a,'Ошибка отправки: подробности').waitFor({timeout:20000});
  assert.equal(sends,before,'Restoring paused item sent it automatically');
  proof.reload_did_not_send=true;
  console.log('PASS: reopening preserved the paused message without automatic delivery');
  await a.unroute('**/_matrix/client/v3/rooms/**/send/**');
  await button(a,'Ошибка отправки: подробности').click();await button(a,'Повторить сейчас').click();
  } else {
    await fill(a,'Написать сообщение…',text);
    await button(a,'Отправить').click();
  }
  await b.getByText(text,{exact:true}).first().waitFor({timeout:60000});
  if(process.env.PIN_ONLY!=='1')proof.manual_retry_decrypted_on_peer=true;
  proof.peer_decrypted=true;
  const wire=await request(matrix,'/_matrix/client/v3/rooms/'+encodeURIComponent(room_id)+'/messages?dir=b&limit=20',null,alice.access_token);
  assert.equal(wire.chunk.filter(e=>e.type==='m.room.encrypted').length,1,'Duplicate encrypted event');
  proof.single_encrypted_event=true;
  fs.writeFileSync(repo+'/.prototype/'+prefix+'-delivery-proof.json',JSON.stringify(proof,null,2),{mode:0o600});
  console.log(process.env.PIN_ONLY==='1'?'PASS: peer decrypted one encrypted event':'PASS: peer decrypted the manual retry; exactly one encrypted event');
  const normalize=b.waitForResponse(r=>r.url().includes('/_synapse/client/voicechat-direct-pins')&&r.request().method()==='POST').then(r=>r.status(),()=>null);
  await button(b,'Действия с сообщением').first().click();
  await b.getByRole('menuitem',{name:'Закрепить',exact:true}).click();
  assert.equal(await normalize,200);
  for(const p of [a,b])await p.getByRole('button',{name:/Закреплённое сообщение/}).first().waitFor({timeout:30000});
  const state=await request(matrix,'/_matrix/client/v3/rooms/'+encodeURIComponent(room_id)+'/state/m.room.pinned_events',null,bob.access_token);
  assert.equal(state.pinned.length,1);
  proof.dm_peer_shared_pin=true;
  proof.result='PASS';
  fs.writeFileSync(repo+'/.prototype/'+prefix+'-proof.json',JSON.stringify(proof,null,2),{mode:0o600});
  console.log(process.env.PIN_ONLY==='1'?'PASS: real DM peer shared pin and shared header in both clients':'PASS: actual minute deadline, reload without auto-send, manual E2EE retry without duplicate, DM peer shared pin');
 }catch(error){
  for(let i=0;i<pages.length;i++)fs.writeFileSync(repo+`/.prototype/chat30-ui-error-${i}.txt`,await pages[i].locator('flt-semantics-host').ariaSnapshot().catch(()=>''),{mode:0o600});
  throw error;
 }finally{clearTimeout(deadline);for(const route of held)await route.abort().catch(()=>{});await browser.close();}
})().catch(error=>{console.error(error.message);process.exitCode=1;});
