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
    const context = await browser.newContext({permissions: ['microphone'], viewport: {width: 1280, height: 900}});
    page = await context.newPage();
    const button = name => page.getByRole('button', {name, exact: true});
    async function fill(input, text) {
      // Flutter activates a text client on pointer focus; allow the semantics edit to commit before blur.
      await input.click(); await page.waitForTimeout(200);
      await page.keyboard.press('ControlOrMeta+A'); await page.keyboard.insertText(text);
      await page.waitForTimeout(150); await page.keyboard.press('Tab');
    }
    const field = name => page.getByRole('textbox', {name, exact: true});
    await page.goto('http://localhost:7357/');
    await page.locator('flt-semantics-placeholder').waitFor();
    await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
    await fill(field('Имя пользователя'), account.username);
    await fill(field('Пароль аккаунта'), account.password);
    await fill(field('Профиль устройства'), 'ui-' + Date.now());
    await fill(field('Отдельная локальная фраза (от 12 символов)'), phrase);
    await button('Войти').click();
    await button('Создать группу').waitFor({timeout: 60000});
    await button('Создать группу').click();
    await fill(field('Поиск пользователей'), 'bob'); await button('Найти').click();
    await page.getByRole('checkbox', {name: 'bob @bob:voicechat.local', exact: true}).click();
    await button('Добавить').click();
    await fill(page.getByRole('alertdialog').getByRole('textbox'), 'Проверка интерфейса');
    await button('Сохранить').click(); await button('Отправить').waitFor({timeout: 30000});
    await fill(field('Написать сообщение…'), 'Привет! Проверяем новый чат 😊');
    await button('Отправить').click();
    await button('Действия с сообщением').first().waitFor({timeout: 20000});
    const chooser = page.waitForEvent('filechooser');
    await button('Отправить изображение').click();
    await (await chooser).setFiles({name: 'Пример.png', mimeType: 'image/png', buffer: fs.readFileSync(path.join(root, 'apps/client/web/icons/Icon-192.png'))});
    await page.getByRole('img').first().waitFor({timeout: 20000});
    await button('Записать голосовое').click(); await button('Отправить запись').waitFor();
    await page.waitForTimeout(1200); await button('Отправить запись').click();
    await button('Прослушать').waitFor({timeout: 20000}); await button('Прослушать').click();
    await page.getByRole('button', {name: /Приостановить/}).waitFor();
    await button('Действия с сообщением').first().click();
    await page.getByRole('menuitem', {name: 'Редактировать', exact: true}).click();
    await fill(page.getByRole('textbox').last(), 'Привет! Сообщение изменено ✨');
    await button('Отправить').click();
    await page.getByRole('textbox', {name: /изменено/}).waitFor({timeout: 20000});
    await button('Действия с сообщением').first().click();
    await page.getByRole('menuitem', {name: '👍', exact: true}).click();
    await page.getByRole('checkbox', {name: '👍 1', exact: true}).waitFor({timeout: 20000});
    await page.screenshot({path: path.join(output, 'desktop.png')});
    await page.setViewportSize({width: 390, height: 844}); await page.waitForTimeout(500);
    await page.screenshot({path: path.join(output, 'mobile.png')});
    await button('Участники и настройки чата').click();
    await page.getByRole('alertdialog').waitFor();
    assert(await page.getByRole('alertdialog').getByRole('button', {name: 'Пригласить', exact: true}).count() > 0);
    await page.getByRole('alertdialog').getByRole('button', {name: 'Закрыть', exact: true}).click();
    await button('Закрыть чат').click(); await button('Заблокировать').click();
    await button('Войти').waitFor({timeout: 20000});
    await fill(field('Отдельная локальная фраза (от 12 символов)'), phrase); await button('Войти').click();
    await button('Создать группу').waitFor({timeout: 30000});
    await button('Выйти').click();
    await page.getByRole('alertdialog').getByRole('button', {name: 'Выйти', exact: true}).click();
    await button('Войти').waitFor({timeout: 30000});
    console.log('PASS: UI login, directory/group, text/image/record/playback, edit/reaction, narrow layout, settings, lock/unlock/logout');
  } catch (error) { await page?.screenshot({path: path.join(output, 'failure.png')}).catch(() => {}); throw error; }
  finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
