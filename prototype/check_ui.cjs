// Run after check_registration.py against a normal (not laboratory) web build.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');

(async () => {
  const root = path.join(__dirname, '..');
  const account = JSON.parse(fs.readFileSync(path.join(root, '.prototype/registered-account.json')));
  const output = path.join(root, '.prototype/ui');
  fs.mkdirSync(output, {recursive: true});
  const phrase = 'independent UI test vault passphrase';
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required'],
  });
  let page;
  try {
    const context = await browser.newContext({permissions: ['microphone','camera'], viewport: {width: 1280, height: 900}});
    page = await context.newPage();
    const button = name => page.getByRole('button', {name, exact: true});
    async function fill(input, text) {
      // Flutter activates a text client on pointer focus; allow the semantics edit to commit before blur.
      await input.click(); await page.waitForTimeout(200);
      await page.keyboard.press('ControlOrMeta+A');
      if(text) await page.keyboard.insertText(text); else await page.keyboard.press('Backspace');
      await page.waitForTimeout(150); await page.keyboard.press('Tab');
    }
    const field = name => page.getByRole('textbox', {name, exact: true});
    await page.goto('http://localhost:7357/');
    await page.locator('flt-semantics-placeholder').waitFor();
    await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
    await page.screenshot({path: path.join(output, 'welcome.png')});
    await fill(field('Имя пользователя'), account.username);
    await fill(field('Пароль аккаунта'), account.password);
    await page.getByText('Параметры подключения', {exact: true}).click();
    await fill(field('Профиль устройства'), 'ui-' + Date.now());
    await fill(field('Отдельная локальная фраза (от 12 символов)'), phrase);
    await button('Войти').click();
    await button('Найти человека').waitFor({timeout: 60000});
    await button('Найти человека').click();
    await fill(field('Поиск пользователей'), 'bob'); await button('Найти').click();
    await page.getByRole('checkbox', {name: 'bob @bob:voicechat.local', exact: true}).click();
    await button('Отправить').waitFor({timeout: 30000});
    const offlineDemoText='Сообщение подготовленному демо-получателю офлайн';
    await fill(field('Написать сообщение…'),offlineDemoText);
    await button('Отправить').click();
    await button('Действия с сообщением').first().waitFor({timeout:30000});
    async function matrix(route, body, token) {
      const response=await fetch('http://localhost:8008/_matrix/client/v3/'+route, {
        method:body ? 'POST' : 'GET',headers:{'Content-Type':'application/json',...(token ? {Authorization:`Bearer ${token}`} : {})},
        ...(body ? {body:JSON.stringify(body)} : {}),
      });
      assert.equal(response.status,200,route);
      return response.json();
    }
    const session=await matrix('login',{type:'m.login.password',user:account.username,password:account.password});
    try {
      let delivered=false;
      for(const room of (await matrix('joined_rooms',undefined,session.access_token)).joined_rooms) {
        const prefix='rooms/'+encodeURIComponent(room)+'/';
        const state=await matrix(prefix+'state',undefined,session.access_token);
        if(!state.some(e=>e.type==='m.room.member' && e.state_key==='@bob:voicechat.local' && ['invite','join'].includes(e.content.membership))) continue;
        const history=await matrix(prefix+'messages?dir=b&limit=10',undefined,session.access_token);
        assert(!JSON.stringify(history).includes(offlineDemoText),'Demo message plaintext leaked');
        delivered=history.chunk.some(e=>e.type==='m.room.encrypted');
      }
      assert(delivered,'Message to offline demo Bob must be on the server, not stuck in a local queue');
    } finally { await matrix('logout',{},session.access_token); }
    await page.getByText('Группы', {exact: true}).click();
    await button('Создать группу').click();
    await fill(field('Поиск пользователей'), 'bob'); await button('Найти').click();
    await page.getByRole('checkbox', {name: 'bob @bob:voicechat.local', exact: true}).click();
    await button('Добавить').click();
    await fill(page.getByRole('alertdialog').getByRole('textbox'), 'Семья');
    await button('Сохранить').click();
    await page.getByText('Семья', {exact: true}).waitFor({timeout: 30000});
    await button('Отправить').waitFor({timeout: 30000});
    await fill(field('Написать сообщение…'), 'Привет! Проверяем новый чат 😊');
    await field('Написать сообщение…').click();
    await page.waitForTimeout(200);
    await page.keyboard.press('Meta+Enter');
    await page.keyboard.insertText('Вторая строка');
    await page.waitForTimeout(150);
    assert((await field('Написать сообщение…').inputValue()).includes('\n'),'Command+Enter must insert a line break');
    await page.keyboard.press('Enter');
    await button('Действия с сообщением').first().waitFor({timeout: 20000});
    await button('Действия с сообщением').first().click();
    await page.getByRole('menuitem', {name: 'Редактировать', exact: true}).click();
    await fill(page.getByRole('textbox').last(), 'Привет! Сообщение изменено ✨');
    await button('Отправить').click();
    await page.getByRole('group', {name: /изменено/}).waitFor({timeout: 20000});
    await button('Действия с сообщением').first().click();
    await page.getByRole('menuitem', {name: 'Реакция…', exact: true}).click();
    await button('👍').click();
    await page.getByRole('checkbox', {name: '👍 1', exact: true}).waitFor({timeout: 20000});
    await button('Действия с сообщением').first().click();
    await page.getByRole('menuitem', {name:'Реакция…',exact:true}).click();
    await button('❤️').click();
    await page.getByRole('checkbox', {name:'❤️ 1',exact:true}).waitFor({timeout:20000});
    await page.getByRole('checkbox', {name:'👍 1',exact:true}).waitFor({state:'hidden'});

    const chooser = page.waitForEvent('filechooser');
    await button('Отправить изображение').click();
    await (await chooser).setFiles([1,2].map(i => ({name: `Фото${i}.png`, mimeType: 'image/png', buffer: fs.readFileSync(path.join(root, 'apps/client/web/icons/Icon-192.png'))})));
    await page.getByRole('img').first().waitFor({timeout: 20000});
    await page.getByText('Прикреплено фото: 2 / 24', {exact:true}).waitFor();
    await page.getByRole('img', {name:'Прикреплённое фото 1', exact:true}).click();
    await button('Следующее фото').click(); await page.getByText('2 / 2', {exact:true}).waitFor();
    await button('Закрыть просмотр').click();
    await fill(field('Написать сообщение…'), 'Фото одним альбомом');
    await button('Отправить').click();
    await page.getByRole('img', {name:'Фото 1 из 2', exact:true}).waitFor({timeout:30000});
    await button('Эмодзи').click(); await button('😀').click();
    await button('Записать голосовое').click(); await button('Остановить запись').waitFor();
    await page.waitForTimeout(1200); await button('Остановить запись').click();
    await button('Прослушать запись').waitFor();
    await fill(page.getByRole('textbox').last(), 'Подпись к голосовому');
    await button('Отправить').click();
    await button('Прослушать').waitFor({timeout:20000}); await button('Прослушать').click();
    await page.getByRole('button', {name:/Приостановить/}).waitFor();
    const fileChooser = page.waitForEvent('filechooser');
    await button('Прикрепить файл или видео').click();
    await page.getByRole('menuitem', {name:'Файл',exact:true}).click();
    const pdf = Buffer.from('%PDF-1.7\nLocal encrypted attachment test\n');
    await (await fileChooser).setFiles(Array.from({length:5},(_,i)=>({name:`test-${i+1}.pdf`,mimeType:'application/pdf',buffer:pdf})));
    await button('Убрать файл 1').waitFor();
    assert.equal(await page.getByText('test-5.pdf 0.0 МБ · 5/5',{exact:true}).count(),1);
    await button('Отправить').click();
    await page.getByRole('group',{name:/test-5.pdf.*отправлено/}).waitFor({timeout:30000});
    await page.evaluate(() => { window.savedBytes=[]; window.showSaveFilePicker=async()=>({createWritable:async()=>({write:async bytes=>window.savedBytes.push(...bytes),close:async()=>{},abort:async()=>{window.savedBytes=[]}})}); });
    await button('Сохранить файл').last().click();
    await page.waitForFunction(() => window.savedBytes.length > 0);
    assert.deepEqual(Buffer.from(await page.evaluate(()=>window.savedBytes)),pdf);
    await button('Видеокружок · удерживайте для записи').click();
    await button('Записать').click(); await page.waitForTimeout(1500);
    await button('Прикрепить').click();
    await page.getByRole('button',{name:/Предпросмотр видео/}).waitFor();
    await page.waitForFunction(()=>[...document.querySelectorAll('video')].some(v=>v.readyState>=2 && v.videoWidth>0 && v.duration>0 && v.paused));
    await page.getByRole('button',{name:/Предпросмотр видео/}).click();
    await button('Закрыть видео').click();
    await button('Отправить').click();
    await button('Воспроизвести видео').waitFor({timeout:30000});
    await button('Воспроизвести видео').click();
    await page.waitForFunction(()=>[...document.querySelectorAll('video')].some(v=>v.readyState>=2 && v.videoWidth>0 && v.duration>0));
    const pauseVideo=page.getByRole('button',{name:/^Пауза видео/});
    if(await pauseVideo.count()) await pauseVideo.click();

    await button('Поиск по чатам и сообщениям').click();
    await fill(field('Чат или фраза из сообщения'),'Подпись к голосовому');
    await page.getByRole('button',{name:/Подпись к голосовому.*Семья/}).click({timeout:30000});
    await button('Вернуться к новым сообщениям').click();
    await button('Вернуться к новым сообщениям').waitFor({state:'hidden'});
    await button('Перейти к дате').click();
    await button('Перейти').click();
    await button('Вернуться к новым сообщениям').waitFor({timeout:30000});
    await button('Вернуться к новым сообщениям').click();
    await button('Вернуться к новым сообщениям').waitFor({state:'hidden'});
    await button('Участники и настройки чата').click();
    const avatarChooser=page.waitForEvent('filechooser');
    await button('Аватар').click();
    await (await avatarChooser).setFiles({name:'avatar.png',mimeType:'image/png',buffer:fs.readFileSync(path.join(root,'apps/client/web/icons/Icon-192.png'))});
    await page.getByText('Масштаб',{exact:true}).waitFor();
    await page.getByRole('slider').first().press('ArrowRight');
    const [avatarSaved] = await Promise.all([
      page.waitForResponse(r=>r.request().method()==='PUT' && decodeURIComponent(r.url()).includes('/state/m.room.avatar')),
      // Flutter's scroll semantics overlaps the actions; exercise the painted button with a real pointer.
      (async()=>{const box=await button('Сохранить').boundingBox(); assert(box); await page.mouse.click(box.x+box.width/2,box.y+box.height/2);})(),
    ]);
    assert.equal(avatarSaved.status(),200);
    await page.getByText('Масштаб',{exact:true}).waitFor({state:'hidden'});
    let previewRequests=0;
    page.on('request',r=>{if(r.url()==='http://localhost:8090/link-preview')previewRequests++;});
    await fill(field('Написать сообщение…'),'https://example.com');
    assert.equal(previewRequests,0,'A private URL must not be disclosed before explicit preview action');
    await button('Добавить превью · example.com').click();
    await button('Превью добавлено · example.com').waitFor({timeout:25000});
    assert.equal(previewRequests,1);
    await button('Отправить').click();
    await page.getByRole('button',{name:/Example Domain/}).waitFor({timeout:30000});
    await fill(field('Написать сообщение…'),'https://www.youtube.com/watch?v=M7lc1UVf-VE');
    await button('Отправить').click();
    await button('Смотреть видео').waitFor({timeout:30000});
    assert.equal(await page.locator('iframe').count(),0,'Embedded provider must not load before a user action');
    await button('Смотреть видео').click();
    const frame=page.locator('iframe');
    await frame.waitFor();
    assert.match(await frame.getAttribute('src'),/^https:\/\/www\.youtube-nocookie\.com\/embed\/M7lc1UVf-VE\?autoplay=0/);
    assert.equal(await frame.getAttribute('credentialless'),'');
    await button('Закрыть видео').click();
    await frame.waitFor({state:'detached'});
    await page.screenshot({path: path.join(output, 'media-desktop.png')});
    for (let i=0;i<35;i++) {
      await fill(field('Написать сообщение…'), `История ${i}`);
      await button('Отправить').click();
    }
    await button('Настройки').click();
    await page.getByRole('button',{name:/Локальное хранилище/}).click();
    await page.getByText(/Этот профиль:/).waitFor();
    await page.screenshot({path:path.join(output,'storage.png')});
    await button('Закрыть').click();
    await button('Настройки').click();
    const device = await page.getByText(/Устройство:/).innerText();
    await button('Закрыть').click();
    assert(!(await page.evaluate(() => JSON.stringify({...localStorage, ...sessionStorage}))).includes(account.password));
    assert(!(await page.evaluate(() => JSON.stringify({...localStorage, ...sessionStorage}))).includes(phrase));
    // A second tab can change the shared last-account preference; this tab must keep its own identity.
    const sharedAccount = await page.evaluate(() => {
      const key = Object.keys(localStorage).find(k => k.endsWith('lastAccount'));
      const value = localStorage.getItem(key);
      localStorage.setItem(key, 'invalid-shared-account');
      return {key, value};
    });
    await page.reload();
    await page.locator('flt-semantics-placeholder').waitFor();
    await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
    await button('Отправить').waitFor({timeout: 60000});
    await button('Показать более ранние сообщения').click();
    await button('Показать более ранние сообщения').waitFor({state:'hidden',timeout:30000});
    await button('Настройки').click();
    assert.equal(await page.getByText(/Устройство:/).innerText(), device, 'Reload created a new device');
    await page.evaluate(({key, value}) => localStorage.setItem(key, value), sharedAccount);
    await button('Закрыть').click();
    await page.getByText('Люди', {exact: true}).click();
    await page.getByText('Ваши группы', {exact: true}).waitFor({state: 'hidden'});
    await button('Найти человека').click();
    await fill(field('Поиск пользователей'), 'bob'); await button('Найти').click();
    await page.getByRole('checkbox', {name: 'bob @bob:voicechat.local', exact: true}).click();
    await button('Отправить').waitFor({timeout: 30000});
    await page.getByText('Группы', {exact: true}).click();
    await page.getByRole('button', {name: /Семья/}).click();
    await button('Отправить').waitFor();
    await button('Показать более ранние сообщения').waitFor({state:'hidden'});
    await page.screenshot({path: path.join(output, 'desktop.png')});
    await page.setViewportSize({width: 390, height: 844}); await page.waitForTimeout(500);
    await page.screenshot({path: path.join(output, 'mobile.png')});
    await button('Участники и настройки чата').click();
    await page.getByRole('alertdialog').waitFor();
    await page.getByRole('tab', {name:'Вступили · 1', exact:true}).waitFor();
    await page.getByRole('tab', {name:'Приглашены · 1', exact:true}).click();
    assert(await page.getByRole('alertdialog').getByRole('button', {name: 'Пригласить', exact: true}).count() > 0);
    await page.getByRole('alertdialog').getByRole('button', {name: 'Закрыть', exact: true}).click();
    await button('Закрыть чат').click(); await button('Настройки').click();
    await page.getByRole('button', {name: /^Заблокировать/}).click();
    await button('Открыть переписку').waitFor({timeout: 20000});
    await page.reload();
    await page.locator('flt-semantics-placeholder').waitFor();
    await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
    await button('Открыть переписку').waitFor({timeout: 20000});
    assert.equal(await field('Пароль аккаунта').count(), 0);
    await fill(field('Отдельная локальная фраза (от 12 символов)'), phrase); await button('Открыть переписку').click();
    await button('Отправить').waitFor({timeout: 30000});
    await button('Закрыть чат').click(); await button('Настройки').click();
    await page.getByRole('button', {name: /^Выйти/}).click();
    await page.getByRole('alertdialog').getByRole('button', {name: 'Выйти', exact: true}).click();
    await button('Войти').waitFor({timeout: 30000});
    console.log('PASS: UI login, directory/group, text/image/record/playback, edit/reaction, narrow layout, settings, same-device reload without credentials, retained expanded history after reload/reopen, people/groups tabs, lock/reload/unlock/logout');
  } catch (error) { if (page) fs.writeFileSync(path.join(output, 'aria.txt'), await page.locator('body').ariaSnapshot()); if (page) fs.writeFileSync(path.join(output, 'semantics.json'), JSON.stringify(await page.locator('[aria-label]').evaluateAll(elements => elements.map(e => ({role: e.getAttribute('role'), label: e.getAttribute('aria-label')}))), null, 2)); await page?.screenshot({path: path.join(output, 'failure.png')}).catch(() => {}); throw error; }
  finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
