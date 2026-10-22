// Local demo only: sequential browsers, real E2EE, credentials stay outside Git.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');
const root = path.join(__dirname, '..', '.prototype');
const stateFile = path.join(root, 'demo-suite.json');
const credentialsFile = path.join(root, 'DEMO-ACCOUNTS.md');
const roles = ['alice','bob','carol','david','elena','felix','galina','hugo','irina','julia','kirill','lena','max','nina','oscar'];
const names = ['Алиса','Боб','Кэрол','Давид','Елена','Феликс','Галина','Хьюго','Ирина','Юлия','Кирилл','Лена','Макс','Нина','Оскар'];
const approval = new Set(['felix','hugo','julia','lena','oscar']);
const state = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile)) : {
  version:1, users:roles.map((role,i) => ({role,username:'demo_'+role,name:names[i],
    password:crypto.randomBytes(18).toString('base64url'),
    phrase:'Local-'+crypto.randomBytes(18).toString('base64url'),
    profile:'demo-'+role+'-v1',allowDirect:!approval.has(role)})), rooms:{}, messages:[],
};
assert.equal(state.version,1);
assert.deepEqual(state.users.map(u=>u.username),roles.map(r=>'demo_'+r));
const user = role => state.users.find(u=>u.role===role);
const id = role => '@'+user(role).username+':voicechat.local';
const tokens = new Map();
let stage = 'start';

function save() {
  fs.writeFileSync(stateFile,JSON.stringify(state,null,2),{mode:0o600});
  fs.chmodSync(stateFile,0o600);
  const rows = state.users.map(u=>`| ${u.name} | ${u.username} | ${u.password} | ${u.phrase} | ${u.profile} | ${u.allowDirect?'Сразу':'По подтверждению'} |`);
  const keys = state.users.map(u=>`- **${u.username}**: ${u.recovery || 'ещё создаётся'}`);
  fs.writeFileSync(credentialsFile,[
    '# Локальные демо-аккаунты VoiceChat','',
    'Только локальный стенд: http://localhost:7357/. Основной аккаунт — **demo_alice**. Данные ниже не предназначены для настоящих пользователей и не добавляются в Git.','',
    '## Вход','',
    'На экране входа укажите логин, пароль аккаунта и локальную фразу из строки ниже. В «Параметры подключения» задайте профиль этой строки: разные аккаунты должны использовать разные локальные профили. Сервер Matrix: http://localhost:8008; API: http://localhost:8090.','',
    'Если открыта прежняя Элис, сначала «Настройки → Заблокировать», затем «Другой аккаунт или профиль». Для одновременной проверки собеседников используйте разные вкладки и разные имена профилей.','',
    'После блокировки прежнего профиля нужен только его локальный пароль (фраза). В новом браузере/устройстве после входа откройте «Настройки → Восстановить» и введите ключ восстановления ниже, чтобы прочитать подготовленную историю. Не создавайте новый ключ вместо восстановления существующего.','',
    '| Имя | Логин | Пароль аккаунта | Локальная фраза | Профиль устройства | Новые контакты |',
    '|---|---|---|---|---|---|',...rows,'',
    '## Ключи восстановления истории','',...keys,'',
    '## Что посмотреть','',
    '- У demo_alice добавлены demo_bob, demo_carol, demo_david и demo_elena. Есть личные сообщения и группы «Семья · демо» и «Планы на выходные · демо».',
    '- В приглашениях: исходящее приглашение demo_felix и приглашение в «Книжный клуб · демо» от Боба. Группы всегда требуют подтверждения вступления.',
    '- Для поиска нового открытого контакта: demo_galina, demo_irina, demo_kirill, demo_max, demo_nina.',
    '- Для проверки подтверждения контакта: demo_hugo, demo_julia, demo_lena, demo_oscar. Войдите за адресата и примите/отклоните приглашение.',
    '- Это обычные аккаунты, не боты. Закрытые демо-браузеры не отвечают автоматически. Старые alice/bob/carol не удалены.',
    '',`Готовность подготовки: ${state.complete?'проверена':'в процессе; пока не считать все примеры готовыми'}.`,
  ].join('\n')+'\n',{mode:0o600});
  fs.chmodSync(credentialsFile,0o600);
}

async function request(base,route,body,token,method=body?'POST':'GET') {
  for(let attempt=0;attempt<8;attempt++) {
    const response = await fetch(base+route,{method,headers:{'Content-Type':'application/json',
      ...(token?{Authorization:'Bearer '+token}:{})},...(body?{body:JSON.stringify(body)}:{})});
    const data = await response.json();
    if(response.status===429) {
      await new Promise(resolve=>setTimeout(resolve,Math.min(30000,Math.max(1000,data.retry_after_ms||1000))));
      continue;
    }
    if(!response.ok) {
      const error = new Error(`HTTP ${response.status} at ${route.split('?')[0]}`);
      error.status = response.status;
      error.errcode = data.errcode;
      throw error;
    }
    return data;
  }
  throw new Error('Local rate limit did not clear');
}
const matrix = (route,body,role,method) => request('http://localhost:8008','/_matrix/client/v3/'+route,body,tokens.get(role),method);
const contact = (role,body) => request('http://localhost:8090','/contacts',body,tokens.get(role));
const button = (page,name) => page.getByRole('button',{name,exact:true});
async function fill(page,label,value) {
  const input = page.getByRole('textbox',{name:label,exact:true});
  await input.click(); await page.waitForTimeout(150);
  await page.keyboard.press('ControlOrMeta+A'); await page.keyboard.insertText(value);
  await page.waitForTimeout(150); await page.keyboard.press('Tab');
}
async function announce(page,text) {
  for(let i=0;i<100;i++) {
    if((await page.locator('flt-semantics-host').ariaSnapshot()).includes(text)) return;
    await page.waitForTimeout(200);
  }
  throw new Error('Expected interface result missing');
}
async function settings(page,item) {
  await page.getByRole('button',{name:/^Настройки(?: Настройки)?$/}).click();
  await page.mouse.move(2,2);
  await page.getByRole('button',{name:new RegExp('^'+item)}).click();
}
async function device(role,action) {
  stage = role+': open encrypted device';
  const account = user(role);
  const directory = path.join(root,'demo-suite-devices',role);
  const context = await chromium.launchPersistentContext(directory,{
    executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,viewport:{width:1280,height:900},
  });
  let page;
  try {
    page = context.pages()[0] || await context.newPage();
    await page.goto('http://localhost:7357/');
    await page.locator('flt-semantics-placeholder').evaluate(el=>el.click());
    await page.getByRole('button',{name:/^(Открыть переписку|Войти|Найти человека)$/}).first().waitFor({timeout:60000});
    if(!await button(page,'Найти человека').count()) {
      const resume = await button(page,'Открыть переписку').count();
      if(!resume) {
        await fill(page,'Имя пользователя',account.username);
        await fill(page,'Пароль аккаунта',account.password);
        await page.getByText('Параметры подключения',{exact:true}).click();
        await fill(page,'Профиль устройства',account.profile);
      }
      await fill(page,'Отдельная локальная фраза (от 12 символов)',account.phrase);
      await button(page,resume?'Открыть переписку':'Войти').click();
      await button(page,'Найти человека').waitFor({timeout:60000});
    }
    await action(page,account);
  } catch(error) {
    if(page) fs.writeFileSync(path.join(root,'demo-prepare-error-aria.txt'),await page.locator('flt-semantics-host').ariaSnapshot(),{mode:0o600});
    throw error;
  } finally {await context.close();}
}

async function direct(first,second,{pending=false}={}) {
  const key = first+'-'+second;
  if(!state.rooms[key]) {
    const result = await matrix('createRoom',{is_direct:true,preset:'private_chat',invite:[id(second)],initial_state:[
      {type:'m.room.encryption',state_key:'',content:{algorithm:'m.megolm.v1.aes-sha2'}},
      {type:'m.room.history_visibility',state_key:'',content:{history_visibility:'invited'}},
      {type:'dev.voicechat.kind',state_key:'',content:{kind:'direct',owner:id(first),peer:id(second)}},
    ]},first);
    state.rooms[key] = result.room_id; save();
  }
  const room = state.rooms[key];
  const consent = await contact(first,{action:'request',recipient:id(second),room_id:room});
  assert.equal(consent.state,pending?'pending':'accepted');
  for(const role of pending?[first]:[first,second]) {
    const peer = role===first?second:first;
    const route = 'user/'+encodeURIComponent(id(role))+'/account_data/m.direct';
    const directMap = await matrix(route,undefined,role).catch(error=>{
      if(error.status===404) return {};
      throw error;
    });
    directMap[id(peer)] = [...new Set([...(directMap[id(peer)]||[]),room])];
    await matrix(route,directMap,role,'PUT');
  }
  if(!pending) await matrix('join/'+encodeURIComponent(room),{},second);
  return room;
}
async function group(key,name,owner,members,invited=[]) {
  if(!state.rooms[key]) {
    const result = await matrix('createRoom',{name,preset:'private_chat',invite:[...members,...invited].map(id),
    power_level_content_override:{invite:50,kick:50,ban:50},initial_state:[
      {type:'m.room.encryption',state_key:'',content:{algorithm:'m.megolm.v1.aes-sha2'}},
      {type:'m.room.history_visibility',state_key:'',content:{history_visibility:'joined'}},
    ]},owner);
    state.rooms[key] = result.room_id; save();
  }
  for(const member of members) await matrix('join/'+encodeURIComponent(state.rooms[key]),{},member);
}

async function send(page,role,roomKey,label,text,groupChat=false) {
  const marker = role+':'+roomKey+':'+text;
  if(state.messages.some(m=>m.marker===marker)) return;
  stage = role+': select '+roomKey;
  await page.getByRole('button',{name:new RegExp('^'+(groupChat?'Группы':'Люди')+'(?: \\d+)?$')}).click();
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  await page.getByRole('button',{name:new RegExp('(?:^| )'+escaped+'(?: |$)')}).first().click();
  await button(page,'Отправить').waitFor();
  stage = role+': send '+roomKey;
  await fill(page,'Написать сообщение…',text);
  const accepted = page.waitForResponse(r=>r.request().method()==='PUT' && new URL(r.url()).pathname.includes('/rooms/'+encodeURIComponent(state.rooms[roomKey])+'/send/m.room.encrypted/'),{timeout:30000});
  await button(page,'Отправить').click();
  const response = await accepted;
  assert.equal(response.status(),200,'Demo message must reach the server encrypted');
  const event = (await response.json()).event_id;
  assert.equal(typeof event,'string');
  state.messages.push({marker,room:roomKey,event}); save();
}

async function prepare() {
  save();
  const registration = JSON.parse(fs.readFileSync(path.join(root,'secrets.json'))).registration;
  for(const account of state.users) {
    stage = account.role+': register';
    if(!account.registered) {
      const route = '/_synapse/admin/v1/register';
      const {nonce} = await request('http://localhost:8008',route);
      const mac = crypto.createHmac('sha1',registration).update([nonce,account.username,account.password,'notadmin'].join('\0')).digest('hex');
      await request('http://localhost:8008',route,{nonce,username:account.username,password:account.password,admin:false,mac}).catch(error=>{
        if(error.errcode!=='M_USER_IN_USE') throw error;
      });
      account.registered = true; save();
    }
    const login = await matrix('login',{type:'m.login.password',user:account.username,password:account.password});
    assert.equal(login.user_id,id(account.role)); tokens.set(account.role,login.access_token);
    await matrix('profile/'+encodeURIComponent(id(account.role))+'/displayname',{displayname:account.name},account.role,'PUT');
    await contact(account.role,{action:'policy',allow_direct:account.allowDirect});
  }
  for(const account of [...state.users.slice(1),state.users[0]]) {
    if(account.recovery) continue;
    await device(account.role,async page=>{
      stage = account.role+': recovery setup';
      await settings(page,'Создать ключ');
      await fill(page,'Пароль',account.password); await button(page,'Подтвердить').click();
      await page.getByText('Сохраните ключ восстановления',{exact:true}).waitFor({timeout:30000});
      const pattern = /Es[1-9A-HJ-NP-Za-km-z]{2}(?:\s+[1-9A-HJ-NP-Za-km-z]{4}){11}/;
      // shortcut: focus SelectableText at the fixed demo dialog offset; update if its layout changes.
      const title = await page.getByText('Сохраните ключ восстановления',{exact:true}).boundingBox();
      await page.mouse.click(title.x+20,title.y+title.height+58,{button:'right'});
      let key;
      for(let attempt=0;!key && attempt<10;attempt++) {
        key = (await page.locator('flt-semantics-host').ariaSnapshot()).match(pattern)?.[0];
        if(!key) await page.waitForTimeout(150);
      }
      assert(key,'Recovery key must be captured before closing its dialog');
      account.recovery = key.replaceAll(/\s+/g,' '); save();
      await button(page,'Я сохранил ключ').click();
      const keys = await matrix('keys/query',{device_keys:{[id(account.role)]:[]}},account.role);
      assert(Object.keys(keys.device_keys[id(account.role)]||{}).length>0);
    });
    console.log(account.username+': encrypted device and recovery ready');
  }
  stage = 'contacts and rooms';
  for(const peer of ['bob','carol','david','elena']) await direct('alice',peer);
  await direct('alice','felix',{pending:true});
  for(const peer of ['carol','david','elena']) await direct('bob',peer);
  await group('family','Семья · демо','alice',['bob','carol','elena']);
  await group('weekend','Планы на выходные · демо','alice',['david','elena']);
  await group('books','Книжный клуб · демо','bob',['carol'],['alice']);
  await device('alice',async page=>{
    for(const [peer,text] of [
      ['bob','Привет, Боб! Это наш новый демо-чат 👋'],
      ['carol','Кэрол, привет! Здесь можно проверить ответы и реакции 😊'],
      ['david','Привет! Куда отправимся на выходных?'],
      ['elena','Привет, Елена! Вечером созвонимся?'],
    ]) await send(page,'alice','alice-'+peer,user(peer).name,text);
    await send(page,'alice','family','Семья · демо','Добро пожаловать в семейный чат! Здесь наши общие планы 💜',true);
    await send(page,'alice','weekend','Планы на выходные · демо','Предлагаю в субботу прогуляться у озера 🌿',true);
  });
  await device('bob',async page=>{
    await send(page,'bob','alice-bob','Алиса','Привет! Всё получил. Можешь написать мне, даже когда я офлайн 👍');
    await send(page,'bob','family','Семья · демо','Я тоже здесь! Вечером буду свободен.',true);
    await send(page,'bob','books','Книжный клуб · демо','В этом клубе обсуждаем книги. Алисе отправлено приглашение 📚',true);
  });
  await device('carol',async page=>{
    await send(page,'carol','alice-carol','Алиса','Отлично, проверим! На это сообщение можно ответить или поставить реакцию ✨');
    await send(page,'carol','family','Семья · демо','Всем привет! Рада вас видеть 😊',true);
  });
  for(const account of state.users) {
    if(account.backedUp) continue;
    await device(account.role,async page=>{
      stage = account.role+': back up history';
      await settings(page,'Обновить backup');
      await announce(page,'Резервная копия ключей обновлена.');
      const backup = await matrix('room_keys/version',undefined,account.role);
      assert.equal(typeof backup.version,'string');
      account.backedUp = true; save();
    });
    console.log(account.username+': history backup checked');
  }
  stage = 'verify demo metadata';
  for(const account of state.users) {
    const consent = await contact(account.role);
    assert.equal(consent.allow_direct,account.allowDirect);
  }
  const contacts = await contact('alice');
  assert.equal(contacts.requests.filter(r=>r.state==='accepted').length,4);
  assert(contacts.requests.some(r=>r.recipient===id('felix') && r.state==='pending'));
  for(const message of state.messages) {
    const wire = await matrix('rooms/'+encodeURIComponent(state.rooms[message.room])+'/event/'+encodeURIComponent(message.event),undefined,message.marker.split(':')[0]);
    assert.equal(wire.type,'m.room.encrypted');
    assert(!JSON.stringify(wire).includes(message.marker.split(':').slice(2).join(':')));
  }
  state.complete = true; save();
  console.log('Demo ready: 15 users, 3 groups, encrypted examples. Credentials: .prototype/DEMO-ACCOUNTS.md');
}
if(require.main===module) prepare()
  .catch(error=>{console.error('Demo preparation failed at '+stage+': '+error.name);process.exitCode=1;})
  .finally(async()=>{for(const [role] of tokens) {try {await matrix('logout',{},role);} catch {process.exitCode=1;}}});
