// Ordinary client, real Matrix E2EE, disposable accounts; no credentials in output.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const { chromium } = require('playwright');
const web = process.env.WEB_URL || 'http://localhost:7366';
const matrix = process.env.MATRIX_URL || 'http://localhost:8008';
const control = process.env.CONTROL_URL || 'http://localhost:8096';
const secretFile = process.env.VOICECHAT_SECRETS_FILE;
assert(secretFile, 'Set VOICECHAT_SECRETS_FILE for the local disposable-account test');
const output = path.join(__dirname, '../.prototype/contact-links');
fs.mkdirSync(output, {recursive: true});
const button = (page, name) => page.getByRole('button', {name, exact: true});
async function api(base, route, body, token, method) {
  const response = await fetch(base + route, {
    method: method || (body ? 'POST' : 'GET'), signal: AbortSignal.timeout(25000),
    headers: {'Content-Type': 'application/json', ...(token ? {Authorization: `Bearer ${token}`} : {})},
    ...(body ? {body: JSON.stringify(body)} : {}),
  });
  const data = await response.json();
  return {status: response.status, data};
}
async function good(...args) {
  const response = await api(...args); assert.equal(response.status, 200, args[1]); return response.data;
}
async function fill(page, label, value) {
  const field = page.getByRole('textbox', {name: label, exact: true});
  await field.click(); await page.waitForTimeout(150);
  await page.keyboard.press('ControlOrMeta+A'); await page.keyboard.insertText(value);
  await page.waitForTimeout(150); await page.keyboard.press('Tab');
  assert.equal(await field.inputValue() === value, true, 'Input did not settle');
}
async function semantics(page) {
  const enable = page.locator('flt-semantics-placeholder');
  await enable.waitFor({state:'attached',timeout:60000}); await enable.evaluate(el => el.click());
}
async function first(page, account, url = web) {
  await page.goto(url); await semantics(page);
  await button(page,'Войти').waitFor({timeout:60000});
  await fill(page,'Имя пользователя',account.username); await fill(page,'Пароль аккаунта',account.password);
  await page.route('**/_matrix/client/v3/login', async route => {
    const response = await route.fetch();
    account.session = await response.json();
    await route.fulfill({response});
  });
  await button(page,'Войти').click();
  await button(page,'Я сохранил ключ').waitFor({timeout:60000}); await button(page,'Я сохранил ключ').click();
  await button(page,'Настройки').waitFor({timeout:30000});
  await page.unroute('**/_matrix/client/v3/login');
}
async function visible(page, text) {
  for(let i=0; i<100; i++) {
    if((await page.locator('body').ariaSnapshot()).includes(text)) return;
    await page.waitForTimeout(200);
  }
  throw new Error('Expected UI text: ' + text);
}

(async () => {
  const accounts = [], pages = [];
  const browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless:true});
  const report = {passed:false};
  try {
    const secret = JSON.parse(fs.readFileSync(secretFile)).registration;
    for(const role of ['owner','recipient','other']) {
      const username = `contact_link_${role}_${Date.now()}`, password = crypto.randomBytes(24).toString('base64url');
      const {nonce} = await good(matrix,'/_synapse/admin/v1/register');
      const mac = crypto.createHmac('sha1',secret).update([nonce,username,password,'notadmin'].join('\0')).digest('hex');
      const registered = await good(matrix,'/_synapse/admin/v1/register',{nonce,username,password,admin:false,mac});
      if(registered.access_token) await good(matrix,'/_matrix/client/v3/logout',{},registered.access_token);
      accounts.push({username,password,user_id:registered.user_id});
    }
    const owner = await (await browser.newContext({viewport:{width:1100,height:900}})).newPage(); pages.push(owner);
    const recipient = await (await browser.newContext({viewport:{width:390,height:844}})).newPage(); pages.push(recipient);
    await first(owner,accounts[0]);
    console.log('PASS: owner signed in');
    const ot = accounts[0].session.access_token;
    await good(control,'/contacts',{action:'policy',allow_direct:false},ot);
    await owner.getByRole('button',{name:/^Мой профиль/}).click(); await button(owner,'Пригласить по ссылке').click();
    await button(owner,'Создать ссылку').click();
    await visible(owner,'Одноразовое приглашение');
    const token = (await owner.locator('body').ariaSnapshot()).match(/\/#\/contact\/([A-Za-z0-9_-]{43})/)[1];
    const url = web+'/#/contact/'+token;
    await visible(owner,url);
    await owner.screenshot({path:path.join(output,'share.png')});
    if(process.env.TEST_SHARE === '1') {
      await owner.evaluate(() => Object.defineProperty(navigator,'share',{configurable:true,value:data=>{
        window.sharedInvitation=data; window.shareHadActivation=navigator.userActivation.isActive; return Promise.resolve();
      }}));
      await button(owner,'Поделиться').click();
      assert.equal(await owner.evaluate(()=>window.sharedInvitation.url),url);
      assert.equal(await owner.evaluate(()=>window.shareHadActivation),true);
      await owner.evaluate(() => Object.defineProperty(navigator,'share',{configurable:true,value:()=>Promise.reject(new DOMException('cancelled','AbortError'))}));
      await button(owner,'Поделиться').click();
      await owner.waitForTimeout(200);
      assert(!(await owner.locator('body').ariaSnapshot()).includes('недоступно'));
      await owner.evaluate(() => Object.defineProperty(navigator,'share',{configurable:true,value:undefined}));
      await button(owner,'Поделиться').click();
      await visible(owner,'Меню «Поделиться» недоступно');
      report.web_share_api_stub = 'success, cancellation, unsupported; URL and user activation checked';
    }
    await button(owner,'Закрыть').last().click();
    console.log('PASS: invitation created through UI');
    await first(recipient,accounts[1],url);
    console.log('PASS: recipient signed in from invitation URL');
    const rt = accounts[1].session.access_token;
    await visible(recipient,'Приглашение в контакты');
    await recipient.getByRole('button',{name:/^Приглашение в контакты Откройте/}).click();
    await visible(recipient,accounts[0].session.user_id);
    let inspected = await good(control,'/contact-links',{action:'inspect',token},rt);
    assert.equal(inspected.claimed,false);
    assert.equal((await good(control,'/contacts',null,rt)).requests.length,0);
    await button(recipient,'Закрыть').last().click();
    await button(recipient,'Скрыть приглашение').click();
    await recipient.evaluate(() => { location.hash = '/'; });
    await recipient.evaluate(value => { location.hash = '/contact/' + value; }, token);
    await recipient.getByRole('button',{name:/^Приглашение в контакты Откройте/}).click();
    await visible(recipient,accounts[0].session.user_id);
    console.log('PASS: preview does not consume; same-tab link opens again');
    let lostRoomReply = false;
    const steps = [];
    recipient.on('response', response => {
      const p = new URL(response.url()).pathname;
      const step = p.includes('/directory/room/') ? 'room-alias' : p.endsWith('/state') ? 'room-state' : p.endsWith('/account_data/m.direct') ? 'direct-metadata' : null;
      if(step) steps.push([step,response.status()]);
    });
    await recipient.route('**/_matrix/client/v3/createRoom', async route => {
      if(!lostRoomReply) {
        const response = await route.fetch();
        steps.push(['create-room',response.status()]);
        if(response.status() === 200) { lostRoomReply = true; await route.abort('failed'); }
        else await route.fulfill({response});
      } else await route.continue();
    });
    // Lose the successful greeting HTTP reply, then resume from the durable receipt.
    let lost = false;
    let greetingStatus;
    await recipient.route(control+'/contact-links', async route => {
      const action = route.request().postDataJSON()?.action;
      const response = await route.fetch();
      const data = await response.json();
      steps.push([action,response.status(),data.error || 'ok']);
      if(!lost && action === 'greet') {
        greetingStatus = response.status();
        if(greetingStatus === 200) { lost = true; await route.abort('failed'); }
        else await route.fulfill({response});
      } else await route.fulfill({response});
    });
    await button(recipient,'Добавить и отправить «Привет»').click();
    await visible(recipient,'Проверьте связь и повторите');
    console.log('Invitation stages:',JSON.stringify(steps));
    assert.equal(greetingStatus,200,'Real greeting publication');
    assert(lost,'Injected lost reply was not reached');
    assert(lostRoomReply,'Lost room creation reply was not recovered');
    inspected = await good(control,'/contact-links',{action:'inspect',token},rt);
    assert(inspected.event_id?.startsWith('$'));
    const eventId = inspected.event_id, roomId = inspected.room_id;
    await button(recipient,'Добавить и отправить «Привет»').click();
    await visible(recipient,'Привет');
    const contacts = await good(control,'/contacts',null,ot);
    assert.equal(contacts.allow_direct,false);
    assert.equal(contacts.requests.length,1);
    assert.equal(contacts.requests[0].state,'accepted');
    await owner.getByRole('button',{name:new RegExp(accounts[1].username)}).first().click({timeout:30000});
    await visible(owner,'Привет');
    const encrypted = await good(matrix,'/_matrix/client/v3/rooms/'+encodeURIComponent(roomId)+'/event/'+encodeURIComponent(eventId),null,ot);
    assert.equal(encrypted.type,'m.room.encrypted'); assert(!JSON.stringify(encrypted.content).includes('Привет'));
    const third = accounts[2];
    third.session = await good(matrix,'/_matrix/client/v3/login',{type:'m.login.password',user:third.username,password:third.password});
    const used = await api(control,'/contact-links',{action:'accept',token,room_id:roomId},third.session.access_token);
    assert.equal(used.status,403); assert.equal(used.data.error,'link_used');
    await good(control,'/contact-links',{action:'greet',id:inspected.id},rt);
    const messages = await good(matrix,'/_matrix/client/v3/rooms/'+encodeURIComponent(roomId)+'/messages?dir=b&limit=100',null,ot);
    assert.equal(messages.chunk.filter(e=>e.type==='m.room.encrypted').length,1,'Exactly one greeting after retry');
    await recipient.reload(); await semantics(recipient); await visible(recipient,'Привет');
    await owner.screenshot({path:path.join(output,'owner.png')});
    await recipient.screenshot({path:path.join(output,'recipient.png')});
    Object.assign(report,{passed:true,closed_inbox:true,preview_no_consent:true,explicit_confirmation:true,real_e2ee_decrypt:true,lost_room_reply_recovered:true,lost_reply_retry:true,one_encrypted_event:true,other_account_rejected:true,reload:true});
    console.log('PASS: closed inbox, explicit invitation consent, real E2EE greeting, lost reply/retry, one event, other account rejected, reload');
  } catch(error) {
    for(let i=0;i<pages.length;i++) {
      // The failure snapshot can contain an unused invitation token; keep it local.
      fs.writeFileSync(path.join(output,`failure-${i}.txt`),await pages[i].locator('body').ariaSnapshot().catch(()=>''),{mode:0o600});
    }
    throw error;
  } finally {
    let cleaned = 0;
    for(const account of accounts) {
      try {
        const session=account.session || await good(matrix,'/_matrix/client/v3/login',{type:'m.login.password',user:account.username,password:account.password});
        await good(matrix,'/_matrix/client/v3/account/deactivate',{auth:{type:'m.login.password',identifier:{type:'m.id.user',user:session.user_id},password:account.password},erase:true},session.access_token);
        cleaned++;
      } catch (_) {}
    }
    report.accounts_deactivated=cleaned;
    if(process.env.CONTACT_LINKS_DB && cleaned === accounts.length) {
      execFileSync('python3',['-c',`
import json, sqlite3, sys
users=json.load(sys.stdin)
assert all(user.startswith('@contact_link_') for user in users)
with sqlite3.connect(sys.argv[1],timeout=10) as db:
    for user in users:
        db.execute('DELETE FROM contact_links WHERE owner=? OR claimant=?',(user,user))
        db.execute('DELETE FROM contacts WHERE sender=? OR recipient=?',(user,user))
        db.execute('DELETE FROM policies WHERE user_id=?',(user,))
`,process.env.CONTACT_LINKS_DB],{input:JSON.stringify(accounts.map(a=>a.user_id))});
      report.contact_fixtures_removed=true;
    }
    fs.writeFileSync(path.join(__dirname,'verified-contact-links-run.json'),JSON.stringify(report,null,2)+'\n');
    await browser.close();
  }
})().catch(error => {
  console.error(error.message);
  console.error(error.stack?.split('\n').find(line=>line.includes('check_contact_links.cjs:')) || '');
  process.exitCode=1;
});
