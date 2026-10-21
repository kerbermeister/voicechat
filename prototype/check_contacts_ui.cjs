// Two independent browsers, disposable users; never log credentials or vault contents.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');
const root = path.join(__dirname, '..');

async function request(base, route, body, token, method = body ? 'POST' : 'GET') {
  const response = await fetch(base + route, {
    method,
    headers: {'Content-Type':'application/json', ...(token ? {Authorization:`Bearer ${token}`} : {})},
    ...(body ? {body:JSON.stringify(body)} : {}),
  });
  assert.equal(response.status, 200, route);
  return response.json();
}

async function register(role) {
  const base = 'http://localhost:8008';
  const route = '/_synapse/admin/v1/register';
  const {nonce} = await request(base, route);
  const username = `consent_ui_${role}_${Date.now()}`;
  const password = crypto.randomBytes(24).toString('base64url');
  const secret = JSON.parse(fs.readFileSync(path.join(root,'.prototype/secrets.json'))).registration;
  const mac = crypto.createHmac('sha1',secret).update([nonce,username,password,'notadmin'].join('\0')).digest('hex');
  await request(base, route, {nonce,username,password,admin:false,mac});
  const session = await request(base,'/_matrix/client/v3/login',{type:'m.login.password',user:username,password});
  return {username,password,...session};
}

(async () => {
  const alice = await register('alice'), bob = await register('bob'), charlie = await register('charlie');
  await request('http://localhost:8090','/contacts',{action:'policy',allow_direct:false},bob.access_token);
  const browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream','--autoplay-policy=no-user-gesture-required']});
  const pages=[];
  try {
    const fill = async (page, name, value) => {
      await page.bringToFront();
      const field=page.getByRole('textbox',{name,exact:true});
      for(let i=0;i<100 && !await field.isEditable();i++) await page.waitForTimeout(100);
      await field.click(); await page.waitForTimeout(200);
      await page.keyboard.press('ControlOrMeta+A');
      if (value) await page.keyboard.insertText(value); else await page.keyboard.press('Backspace');
      await page.waitForTimeout(150);
      assert.equal(await field.inputValue()===value,true,`Text input did not commit: ${name}`);
      await page.keyboard.press('Tab');
    };
    const button=(page,name)=>page.getByRole('button',{name,exact:true});
    async function login(account) {
      const context=await browser.newContext({permissions:['microphone','camera'],viewport:{width:1280,height:900}});
      await context.addInitScript(()=>{
        window.soundPlays=[];
        const play=HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play=function(...args){
          const result=play.apply(this,args);
          if(this.src.includes('/sounds/')) result.then(()=>window.soundPlays.push({src:this.src,audio:this}),()=>{});
          return result;
        };
      });
      const page=await context.newPage(); pages.push(page);
      await page.goto('http://localhost:7357/');
      await page.locator('flt-semantics-placeholder').evaluate(el=>el.click());
      await fill(page,'Имя пользователя',account.username);
      await fill(page,'Пароль аккаунта',account.password);
      await page.getByText('Параметры подключения',{exact:true}).click();
      await fill(page,'Профиль устройства',account.username);
      await fill(page,'Отдельная локальная фраза (от 12 символов)','independent consent test local phrase');
      await button(page,'Войти').click();
      await button(page,'Найти человека').waitFor({timeout:60000});
      return page;
    }
    const a=await login(alice), b=await login(bob);
    await button(a,'Найти человека').click();
    await fill(a,'Поиск пользователей',bob.username); await button(a,'Найти').click();
    await a.getByRole('checkbox',{name:`${bob.username} ${bob.user_id}`,exact:true}).click();
    await a.getByText('Приглашение отправлено. После подтверждения собеседник появится в «Люди».',{exact:true}).waitFor();
    await a.waitForTimeout(350);
    await a.getByRole('button',{name:/Приглашения/}).click();
    await button(a,'Отменить запрос').waitFor({timeout:30000});
    await button(a,'Закрыть').click();
    await b.waitForTimeout(11000);
    await b.getByRole('button',{name:/Приглашения/}).click();
    await button(b,'Принять').waitFor();
    await button(b,'Принять').click();
    await button(b,'Принять').waitFor({state:'hidden',timeout:30000});
    await button(b,'Закрыть').click();
    await a.getByRole('button',{name:new RegExp(bob.username)}).click({timeout:30000});
    await b.getByRole('button',{name:new RegExp(alice.username)}).click({timeout:30000});
    const text='Первое сообщение после согласия';
    await fill(a,'Написать сообщение…',text); await button(a,'Отправить').click();
    await b.getByRole('group',{name:new RegExp(text)}).waitFor({timeout:30000});
    await a.waitForFunction(()=>window.soundPlays.some(p=>p.src.includes('sent.wav')));
    await b.waitForFunction(()=>window.soundPlays.some(p=>p.src.includes('received.wav')));
    await fill(b,'Написать сообщение…','Ответ с другого устройства'); await button(b,'Отправить').click();
    await button(a,'Действия с сообщением').nth(1).waitFor({timeout:30000});
    await button(a,'Участники и настройки чата').click();
    await a.getByText('Профиль',{exact:true}).waitFor();
    assert.equal(await button(a,'Покинуть чат').count(),0);
    assert.equal(await button(a,'Изменить название').count(),0);
    await button(a,'Закрыть').click();
    await a.getByText('Группы',{exact:true}).click();
    await button(a,'Создать группу').click();
    await fill(a,'Поиск пользователей',bob.username); await button(a,'Найти').click();
    await a.getByRole('checkbox',{name:`${bob.username} ${bob.user_id}`,exact:true}).click();
    await button(a,'Добавить').click();
    const name=a.getByRole('alertdialog').getByRole('textbox');
    await name.click(); await a.keyboard.insertText('Согласие на группу'); await a.keyboard.press('Tab');
    await button(a,'Сохранить').click();
    await a.getByText('Согласие на группу',{exact:true}).waitFor();
    await b.getByRole('button',{name:/Приглашения/}).click();
    await b.getByRole('tab',{name:'Группы',exact:true}).click();
    await b.getByText(/Ожидает ответа/).waitFor();
    await button(b,'Принять').click();
    await button(b,'Принять').waitFor({state:'hidden',timeout:30000});
    await b.getByText(/Принято/).waitFor({timeout:30000});
    let joined=[];
    for(let i=0;i<30;i++) {
      joined=(await request('http://localhost:8008','/_matrix/client/v3/joined_rooms',undefined,bob.access_token)).joined_rooms;
      if(joined.length===2) break;
      await b.waitForTimeout(500);
    }
    assert.equal(joined.length,2,'Group acceptance did not join the room');
    await button(b,'Закрыть').click();
    await a.getByRole('button',{name:/Согласие на группу[\s\S]*Вступили: 2/}).waitFor({timeout:30000});
    await a.getByText('Люди',{exact:true}).click();
    await a.getByRole('button',{name:new RegExp(bob.username)}).getByRole('button',{name:'Действия с чатом',exact:true}).click();
    await a.getByRole('menuitem',{name:'Отключить уведомления',exact:true}).click();
    const receivedBeforeMute=await a.evaluate(()=>window.soundPlays.filter(p=>p.src.includes('received.wav')).length);
    for(const message of ['Тихое сообщение один','Тихое сообщение два']) {
      await fill(b,'Написать сообщение…',message); await button(b,'Отправить').click();
      await b.getByRole('group',{name:new RegExp(message)}).waitFor({timeout:30000});
    }
    const row=a.getByRole('button',{name:new RegExp(bob.username)});
    let label='';
    for(let i=0;i<60;i++) {
      label=await row.getAttribute('aria-label') ?? '';
      if(/\s2$/.test(label)) break;
      await a.waitForTimeout(300);
    }
    assert(/\s2$/.test(label),'Muted room did not keep its unread message count');
    assert.equal(await a.evaluate(()=>window.soundPlays.filter(p=>p.src.includes('received.wav')).length),receivedBeforeMute,'Muted messages must not play received sound');
    await a.getByRole('button',{name:/^Люди\s+1$/}).waitFor();
    await row.click();
    for(let i=0;i<60;i++) {
      label=await row.getAttribute('aria-label') ?? '';
      if(!/\s2$/.test(label)) break;
      await a.waitForTimeout(300);
    }
    assert(!/\s2$/.test(label),'Read receipt did not clear the count');
    const c=await login(charlie);
    for(let i=0;i<60;i++) {
      const keys=await request('http://localhost:8008','/_matrix/client/v3/keys/query',{device_keys:{[charlie.user_id]:[]}},alice.access_token);
      if(Object.keys(keys.device_keys[charlie.user_id] ?? {}).length) break;
      assert(i<59,'Offline recipient did not publish device keys');
      await c.waitForTimeout(300);
    }
    await c.goto('about:blank');
    await button(a,'Найти человека').click();
    await fill(a,'Поиск пользователей',charlie.username); await button(a,'Найти').click();
    await a.getByRole('checkbox',{name:`${charlie.username} ${charlie.user_id}`,exact:true}).click();
    await a.getByText(charlie.username,{exact:true}).last().waitFor({timeout:30000});
    const offlineText='Сообщение первому офлайн-контакту';
    await fill(a,'Написать сообщение…',offlineText); await button(a,'Отправить').click();
    await a.getByRole('group',{name:new RegExp(offlineText)}).waitFor({timeout:30000});
    const rooms=(await request('http://localhost:8008','/_matrix/client/v3/joined_rooms',undefined,alice.access_token)).joined_rooms;
    let offlineRoom;
    for(const id of rooms) {
      const state=await request('http://localhost:8008',`/_matrix/client/v3/rooms/${encodeURIComponent(id)}/state`,undefined,alice.access_token);
      if(state.some(e=>e.type==='m.room.member' && e.state_key===charlie.user_id && e.content.membership==='invite')) offlineRoom=id;
    }
    assert(offlineRoom,'Recipient must still be invited while offline');
    let wire;
    for(let i=0;i<120;i++) {
      wire=await request('http://localhost:8008',`/_matrix/client/v3/rooms/${encodeURIComponent(offlineRoom)}/messages?dir=b&limit=10`,undefined,alice.access_token);
      if(wire.chunk.some(e=>e.type==='m.room.encrypted')) break;
      await a.waitForTimeout(500);
    }
    assert(wire.chunk.some(e=>e.type==='m.room.encrypted'),'First offline message must reach encrypted server history');
    assert(!JSON.stringify(wire).includes(offlineText),'Plaintext leaked to server');
    await c.goto('http://localhost:7357/');
    await c.locator('flt-semantics-placeholder').evaluate(el=>el.click());
    await c.getByRole('button',{name:new RegExp(alice.username)}).click({timeout:60000});
    await c.getByRole('group',{name:new RegExp(offlineText)}).waitFor({timeout:60000});
    await c.goto('about:blank');
    const roomPath=`/_matrix/client/v3/rooms/${encodeURIComponent(offlineRoom)}`;
    await request('http://localhost:8008',`${roomPath}/leave`,{},charlie.access_token);
    await request('http://localhost:8008',`${roomPath}/invite`,{user_id:charlie.user_id},alice.access_token);
    await request('http://localhost:8008',`${roomPath}/state/m.room.history_visibility`,{history_visibility:'joined'},alice.access_token,'PUT');
    await a.waitForTimeout(1000);
    const legacyText='Офлайн-доставка после обновления старого диалога';
    await fill(a,'Написать сообщение…',legacyText); await button(a,'Отправить').click();
    let migrated=false;
    for(let i=0;i<120;i++) {
      const state=await request('http://localhost:8008',`${roomPath}/state/m.room.history_visibility`,undefined,alice.access_token);
      wire=await request('http://localhost:8008',`${roomPath}/messages?dir=b&limit=15`,undefined,alice.access_token);
      migrated=state.history_visibility==='invited' && wire.chunk.filter(e=>e.type==='m.room.encrypted').length>=2;
      if(migrated) break;
      await a.waitForTimeout(500);
    }
    assert(migrated,'Legacy joined history did not migrate and deliver encrypted offline');
    await c.goto('http://localhost:7357/');
    await c.locator('flt-semantics-placeholder').evaluate(el=>el.click());
    await c.getByRole('button',{name:new RegExp(alice.username)}).click({timeout:60000});
    await c.getByRole('group',{name:new RegExp(legacyText)}).waitFor({timeout:60000});
    await c.goto('about:blank');
    await button(a,'Голосовой звонок').click();
    await button(a,'Завершить').waitFor({timeout:30000});
    await a.waitForFunction(()=>window.soundPlays.some(p=>p.src.includes('ringback.wav')));
    await a.waitForTimeout(1500);
    assert(await button(a,'Завершить').isVisible(),'Offline outgoing call disappeared');
    await button(a,'Завершить').click();
    await a.waitForFunction(()=>window.soundPlays.filter(p=>p.src.includes('ringback.wav')).every(p=>p.audio.paused));
    await button(a,'Закрыть').click();
    fs.mkdirSync(path.join(root,'.prototype/ui'),{recursive:true});
    await a.screenshot({path:path.join(root,'.prototype/ui/contacts.png')});
    console.log('PASS: private consent, two-browser E2EE replies, direct profile/rights, explicit group invitation acceptance, muted unread message/chat counts, read receipts first/legacy offline direct messages and persistent outgoing call window');
  } catch (error) {
    fs.mkdirSync(path.join(root,'.prototype/ui'),{recursive:true});
    for(let i=0;i<pages.length;i++) await pages[i].screenshot({path:path.join(root,`.prototype/ui/consent-failure-${i}.png`)});
    if(pages[1] && await pages[1].getByRole('button',{name:'Действия с сообщением',exact:true}).count()) fs.writeFileSync(path.join(root,'.prototype/ui/consent-accessibility.txt'),await pages[1].locator('body').ariaSnapshot());
    throw error;
  } finally { await browser.close(); }
})().catch(error=>{console.error(error.message);process.exitCode=1;});
