// Verify the real registration screen, including the SDK's UIA flow, against local Mailpit.
const crypto = require('node:crypto');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const {chromium} = require('playwright');

(async () => {
  const browser = await chromium.launch({executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});
  let page;
  try {
    page = await browser.newPage({viewport: {width: 1100, height: 900}});
    const button = name => page.getByRole('button', {name, exact: true});
    async function fill(name, value) {
      await page.getByRole('textbox', {name, exact: true}).click(); await page.waitForTimeout(200);
      await page.keyboard.press('ControlOrMeta+A'); await page.keyboard.insertText(value);
      await page.waitForTimeout(150); await page.keyboard.press('Tab');
    }
    await page.goto('http://localhost:7357/');
    await page.locator('flt-semantics-placeholder').waitFor();
    await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
    const username = 'signup' + Date.now();
    const email = username + '@example.test';
    const password = crypto.randomBytes(24).toString('base64url');
    await button('Создать аккаунт').click();
    await page.getByRole('textbox', {name: 'Имя пользователя · латиницей', exact: true}).waitFor({timeout: 30000});
    await fill('Имя пользователя · латиницей', username);
    await fill('Отображаемое имя', 'Проверка регистрации');
    await fill('Электронная почта', email);
    await fill('Пароль аккаунта · от 12 символов', password);
    await fill('Повторите пароль', password);
    await button('Отправить письмо').click();
    await page.getByText('Ожидаем подтверждения почты. Вход произойдёт автоматически.',{exact:true}).waitFor({timeout:30000});
    if(await button('Почта подтверждена · создать аккаунт').count()) throw new Error('Manual registration confirmation must not be required');
    // Reuse the same local email/form verification helper as the backend acceptance test.
    execFileSync('python3', ['-c', 'import sys; from check_registration import validate_email; validate_email(sys.argv[1])', email], {cwd: __dirname, stdio: 'pipe'});
    await page.getByText('Добро пожаловать в VoiceChat!',{exact:true}).waitFor({timeout:60000});
    await button('Продолжить').click();
    await button('Я сохранил ключ').waitFor({timeout: 60000});
    await button('Я сохранил ключ').click();
    await button('Настройки').waitFor({timeout: 60000});
    await button('Настройки').click();
    await page.getByRole('button', {name: /^Выйти/}).click();
    await page.getByRole('alertdialog').getByRole('button', {name: 'Выйти', exact: true}).click();
    await button('Войти').waitFor({timeout: 30000});
    console.log('PASS: registration UI, confirmed email, SDK login, profile and logout');
  } catch (error) { await page?.screenshot({path: path.join(__dirname, '../.prototype/ui/signup-failure.png')}).catch(() => {}); throw error; } finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
