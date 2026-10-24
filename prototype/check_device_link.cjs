// Real Synapse + two isolated browsers: no secrets in reports or console.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');
const root = path.join(__dirname,'..','.prototype');
const base = process.env.WEB_URL || 'http://localhost:7357';
const matrix = process.env.MATRIX_URL || 'http://localhost:8008';
const button = (page,name) => page.getByRole('button',{name,exact:true});
async function api(route,body,token,method) {
  const r = await fetch(matrix+route,{method:method||(body?'POST':'GET'),headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body?{body:JSON.stringify(body)}:{})});
  assert(r.ok,`Matrix request failed: ${r.status} ${route}`); return r.json();
}
async function fill(page,label,value) {
  const field=page.getByRole('textbox',{name:label,exact:true});
  for(let attempt=0;attempt<4;attempt++) {
    await page.bringToFront(); await field.click(); await page.waitForTimeout(200);
    await page.keyboard.press('ControlOrMeta+A'); await page.keyboard.insertText(value);
    await page.waitForTimeout(200); await page.keyboard.press('Tab'); await page.waitForTimeout(200);
    if(await field.inputValue()===value) return;
  }
  throw new Error('Text entry did not settle: '+label);
}
async function open(context) {
  const page=await context.newPage(); await page.goto(base);
  await page.locator('flt-semantics-placeholder').evaluate(el=>el.click());
  await button(page,'Войти').waitFor({timeout:60000}); return page;
}
async function login(page,account) {
  await fill(page,'Имя пользователя',account.username); await fill(page,'Пароль аккаунта',account.password);
  const response = page.waitForResponse(r => r.request().method()==='POST' && new URL(r.url()).pathname.endsWith('/login'));
  await button(page,'Войти').click();
  const r=await response; const payload=r.request().postDataJSON(); assert(payload.password===account.password,'Password entry did not reach login controller'); assert(payload.identifier.user===account.username,'Username entry did not reach login controller'); assert.equal(r.status(),200,'Browser login failed'); return r.json();
}
async function first(page,account) {
  const session = await login(page,account);
  await button(page,'Я сохранил ключ').waitFor({timeout:60000});
  await button(page,'Я сохранил ключ').click();
  await button(page,'Настройки').waitFor({timeout:30000});
  return session;
}
async function compare(a,b,{numbers=false,reject=false,deviceId}={}) {
  const target = b.getByRole('button',{name: deviceId ? new RegExp('^VoiceChat · браузер · '+deviceId+'$') : /^VoiceChat · браузер/}).first();
  await Promise.race([target.waitFor({timeout:60000}),button(a,'Принять проверку').waitFor({timeout:60000})]);
  if(await target.isVisible().catch(()=>false)) await target.click();
  await button(a,'Принять проверку').waitFor({timeout:30000}); await button(a,'Принять проверку').click();
  await button(a,'Совпадают').waitFor({timeout:30000}); await button(b,'Совпадают').waitFor({timeout:30000});
  if(numbers) {
    await a.getByText('Код',{exact:true}).click(); await b.getByText('Код',{exact:true}).click();
    for(const p of [a,b]) await p.getByRole('alertdialog').getByText(/\b\d{4}\s+\d{4}\s+\d{4}\b/).last().waitFor({timeout:10000});
  }
  const snapA=await a.locator('flt-semantics-host').ariaSnapshot();
  const snapB=await b.locator('flt-semantics-host').ariaSnapshot();
  if(numbers) {
    const pattern=/\b\d{4}\s+\d{4}\s+\d{4}\b/;
    assert(snapA.match(pattern),'Numeric SAS absent'); assert.equal(snapA.match(pattern)[0],snapB.match(pattern)?.[0]);
  } else {
    // Each emoji is a visible text node and the digits are hidden by default.
    assert(!/\b\d{4}\s+\d{4}\s+\d{4}\b/.test(snapA));
    const emojis=text=>[...text.matchAll(/text: "?([^\n"]*[\p{Extended_Pictographic}][^\n"]*)/gu)].map(m=>m[1]);
    assert((emojis(snapA).join('').match(/[\p{Extended_Pictographic}\p{Emoji_Presentation}]/gu)||[]).length>=7,'Seven emoji absent'); assert.deepEqual(emojis(snapA),emojis(snapB));
  }
  if(reject) {
    await button(b,'Не совпадают').click();
    await button(b,'Закрыть').click(); await button(a,'Закрыть').click();
    assert.equal(await button(b,'Настройки').count(),0); return;
  }
  await button(a,'Совпадают').click(); await button(b,'Совпадают').click();
  for(const p of [a,b]) { await p.getByText('Устройство подтверждено',{exact:true}).waitFor({timeout:30000}); await button(p,'Закрыть').click(); }
  await button(b,'Настройки').waitFor({timeout:90000});
}
async function run() {
  const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
  const contexts=[]; let pages=[];
  const accounts=[];
  try {
    const registration=JSON.parse(fs.readFileSync(path.join(root,'secrets.json'))).registration;
    const suffix=Date.now();
    for(const name of ['anna','boris','vera']) {
      const username=`link_${name}_${suffix}`,password=crypto.randomBytes(24).toString('base64url');
      const {nonce}=await api('/_synapse/admin/v1/register');
      const mac=crypto.createHmac('sha1',registration).update([nonce,username,password,'notadmin'].join('\0')).digest('hex');
      const registered=await api('/_synapse/admin/v1/register',{nonce,username,password,admin:false,mac});
      // Shared-secret registration may create a session; do not keep an invisible device.
      if(registered.access_token) await api('/_matrix/client/v3/logout',{},registered.access_token);
      accounts.push({username,password});
    }
    fs.writeFileSync(path.join(root,'device-link-accounts.json'),JSON.stringify(accounts,null,2),{mode:0o600});
    for(let i=0;i<4;i++) contexts.push(await chromium.launchPersistentContext(path.join(root,'device-link-demo',String(suffix),String(i)), {executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,viewport:{width:1200,height:1000}}));
    const a=await open(contexts[0]),b=await open(contexts[1]); pages=[a,b];
    const primary = await first(a,accounts[0]); console.log('PASS: first device automatic setup');
    const boris=await open(contexts[2]),vera=await open(contexts[3]);
    const sessions=[primary,await first(boris,accounts[1]),await first(vera,accounts[2])];
    const directMaps=Object.fromEntries(sessions.map(session=>[session.user_id,{}]));
    for(const peer of sessions.slice(1)) {
      const direct=await api('/_matrix/client/v3/createRoom',{is_direct:true,preset:'private_chat',invite:[peer.user_id],initial_state:[
        {type:'m.room.encryption',state_key:'',content:{algorithm:'m.megolm.v1.aes-sha2'}},
        {type:'dev.voicechat.kind',state_key:'',content:{kind:'direct',owner:primary.user_id,peer:peer.user_id}}
      ]},primary.access_token);
      const consent=await fetch((process.env.CONTROL_URL||'http://localhost:8090')+'/contacts',{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${primary.access_token}`},body:JSON.stringify({action:'request',recipient:peer.user_id,room_id:direct.room_id})});
      assert(consent.ok,'Contact fixture failed');
      directMaps[primary.user_id][peer.user_id]=[direct.room_id];
      directMaps[peer.user_id][primary.user_id]=[direct.room_id];
      await api('/_matrix/client/v3/join/'+encodeURIComponent(direct.room_id),{},peer.access_token);
    }
    for(const session of sessions) await api('/_matrix/client/v3/user/'+encodeURIComponent(session.user_id)+'/account_data/m.direct',directMaps[session.user_id],session.access_token,'PUT');
    const rooms=[];
    for(const name of ['Семейный круг','Планы на выходные']) {
      const room=await api('/_matrix/client/v3/createRoom',{name,preset:'private_chat',invite:sessions.slice(1).map(s=>s.user_id),initial_state:[
        {type:'m.room.encryption',state_key:'',content:{algorithm:'m.megolm.v1.aes-sha2'}},
        {type:'m.room.history_visibility',state_key:'',content:{history_visibility:'joined'}}]},primary.access_token);
      for(const peer of sessions.slice(1)) await api('/_matrix/client/v3/join/'+encodeURIComponent(room.room_id),{},peer.access_token);
      rooms.push(room.room_id);
    }
    await button(a,'Группы').click();
    await a.getByRole('button',{name:/Семейный круг/}).first().click();
    const message='Встречаемся в воскресенье в полдень';
    await fill(a,'Написать сообщение…',message);
    const sent=a.waitForResponse(r=>r.request().method()==='PUT' && r.url().includes('/send/m.room.encrypted/'));
    await button(a,'Отправить').click(); assert.equal((await sent).status(),200);
    await button(a,'Настройки').click();
    await a.getByRole('button',{name:/^Обновить backup/}).click();
    await a.locator('flt-semantics-host').getByText('Резервная копия ключей обновлена.',{exact:true}).waitFor({timeout:30000});
    fs.writeFileSync(path.join(root,'device-link-demo.json'),JSON.stringify({accounts,rooms,profiles:path.join(root,'device-link-demo',String(suffix))},null,2),{mode:0o600});
    console.log('PASS: three fresh encrypted users and two groups; encrypted history backed up');
    await login(b,accounts[0]);
    await compare(a,b,{reject:true,deviceId:primary.device_id});
    await button(b,'Подтвердить на другом устройстве').click();
    await compare(a,b,{numbers:true,deviceId:primary.device_id});
    await button(b,'Группы').click();
    await b.getByRole('button',{name:/Семейный круг/}).first().click();
    await b.getByRole('group',{name:new RegExp('^'+message)}).first().waitFor({timeout:30000});
    console.log('PASS: old message decrypted on linked device');
    await b.reload(); await b.locator('flt-semantics-placeholder').evaluate(el=>el.click());
    await button(b,'Настройки').waitFor({timeout:60000});
    const extra = await chromium.launchPersistentContext(path.join(root,'device-link-demo',String(suffix),'emoji'), {executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,viewport:{width:1200,height:1000}});
    contexts.push(extra);
    const c=await open(extra); pages.push(c);
    await login(c,accounts[0]); await compare(a,c,{deviceId:primary.device_id});
    await button(c,'Группы').click(); await c.getByRole('button',{name:/Семейный круг/}).first().click();
    await c.getByRole('group',{name:new RegExp('^'+message)}).first().waitFor({timeout:30000});
    console.log('PASS: successful emoji SAS and history on third device');
    fs.writeFileSync(path.join(__dirname,'verified-device-link-run.json'),JSON.stringify({emoji_default:true,emoji_sas:true,mismatch_blocks:true,numeric_sas:true,secret_transfer:true,history_decrypted:true,demo_users:3,demo_groups:2,reload:true,physical_devices:'NOT_TESTED'},null,2));
    console.log('PASS: automatic profiles, emoji default, mismatch denial, numeric SAS, linked secrets, reload');
  } catch(error) {
    for(let i=0;i<pages.length;i++) fs.writeFileSync(path.join(root,`device-link-failure-${i}.txt`),await pages[i].locator('flt-semantics-host').ariaSnapshot().catch(()=>''),{mode:0o600});
    throw error;
  } finally {for(const context of contexts) await context.close(); await browser.close();}
}
if(require.main===module) run().catch(e=>{console.error(e.message);process.exitCode=1;});
module.exports={open,login,first,compare,fill};
