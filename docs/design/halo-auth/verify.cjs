// Built-web navigation only: no account submissions or external writes.
const {chromium} = require('playwright');
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless:true});
  const results = [];
  try {
    for (const [width,height] of [[1440,900],[1366,768],[390,844],[390,667],[320,568]]) {
      const page = await browser.newPage({viewport:{width,height},locale:'ru-RU'});
      const errors = [];
      async function fits(locator) {
        const box = await locator.boundingBox();
        assert.ok(box && box.y >= 0 && box.y + box.height <= height, `Action outside viewport ${width}x${height}: ${JSON.stringify(box)}`);
      }
      page.on('pageerror', error => errors.push(error.message));
      await page.goto('http://localhost:7362/');
      await page.locator('flt-semantics-placeholder').waitFor({timeout:60000});
      await page.locator('flt-semantics-placeholder').evaluate(e => e.click());
      const create = page.getByRole('button',{name:'Создать аккаунт',exact:true});
      await create.waitFor({timeout:30000});
      await page.waitForTimeout(250); // Let the shared 180 ms route transition finish.
      await page.screenshot({path:path.join(__dirname,`web-login-${width}-${height}.png`)});
      await fits(create);
      await page.getByRole('button',{name:'Параметры подключения',exact:true}).click();
      await page.getByRole('textbox',{name:'Matrix URL',exact:true}).waitFor();
      await page.waitForTimeout(250);
      await page.screenshot({path:path.join(__dirname,`web-modal-${width}-${height}.png`)});
      await page.getByRole('button',{name:'Готово',exact:true}).click();
      await create.waitFor();
      await create.click();
      await page.getByRole('textbox',{name:'Имя пользователя · латиницей',exact:true}).waitFor();
      await page.waitForTimeout(250); // Let the shared 180 ms route transition finish.
      await fits(page.getByRole('button',{name:'Уже есть аккаунт? Войти',exact:true}));
      await page.screenshot({path:path.join(__dirname,`web-register-${width}-${height}.png`)});
      await page.getByRole('button',{name:'Вернуться ко входу',exact:true}).first().click();
      await page.getByRole('button',{name:'Забыли пароль?',exact:true}).click();
      await page.getByRole('textbox',{name:'Электронная почта',exact:true}).waitFor();
      assert.equal(await page.getByRole('textbox',{name:'Имя пользователя · латиницей',exact:true}).count(),0);
      await page.waitForTimeout(250); // Let the shared 180 ms route transition finish.
      await page.screenshot({path:path.join(__dirname,`web-reset-${width}-${height}.png`)});
      await fits(page.getByRole('button',{name:'Вернуться ко входу',exact:true}).last());
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      assert.equal(overflow,false);
      assert.deepEqual(errors,[]);
      results.push({width,height,actionsFit:true,connectionDialog:true,login:true,registration:true,passwordReset:true,horizontalOverflow:overflow,errors});
      await page.close();
    }
    fs.writeFileSync(path.join(__dirname,'verification.json'),JSON.stringify({results,limits:'Navigation only. Email and authenticated network workflows were not run.'},null,2));
    console.log(JSON.stringify(results));
  } finally {await browser.close();}
})().catch(error => {console.error(error);process.exitCode = 1;});
