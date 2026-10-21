// Local demo provisioning: publish real keys, retain their encrypted device vaults, then go offline.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');
const root = path.join(__dirname, '..', '.prototype');
const accounts = JSON.parse(fs.readFileSync(path.join(root, 'accounts.json')));

async function matrix(route, body, token) {
  const response = await fetch('http://localhost:8008/_matrix/client/v3/' + route, {
    method: 'POST', headers: {'Content-Type':'application/json', ...(token ? {Authorization:`Bearer ${token}`} : {})},
    body: JSON.stringify(body),
  });
  assert.equal(response.status, 200, route);
  return response.json();
}

async function published(account) {
  const login = await matrix('login', {type:'m.login.password',user:account.username,password:account.password});
  try {
    const keys = await matrix('keys/query', {device_keys:{[login.user_id]:[]}}, login.access_token);
    return Object.keys(keys.device_keys[login.user_id] ?? {}).length;
  } finally { await matrix('logout', {}, login.access_token); }
}

(async () => {
  const directory = path.join(root, 'demo-devices');
  fs.mkdirSync(directory, {recursive:true,mode:0o700});
  for (const name of ['bob','carol']) {
    const account = accounts[name];
    assert.equal(account.username, name, 'Only named local demo users may be provisioned');
    if (await published(account)) { console.log(`${name}: already has published E2EE keys`); continue; }
    const file = path.join(directory, name + '.json');
    if (!fs.existsSync(file)) fs.writeFileSync(file, JSON.stringify({profile:'demo-'+name,phrase:crypto.randomBytes(32).toString('base64url')}), {mode:0o600,flag:'wx'});
    const vault = JSON.parse(fs.readFileSync(file));
    const context = await chromium.launchPersistentContext(path.join(directory,name), {
      executablePath:process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      headless:true,viewport:{width:1280,height:900},
    });
    try {
      const page = context.pages()[0] ?? await context.newPage();
      await page.goto('http://localhost:7357/');
      await page.locator('flt-semantics-placeholder').evaluate(el=>el.click());
      async function fill(label, value) {
        const field = page.getByRole('textbox',{name:label,exact:true});
        await field.click(); await page.waitForTimeout(200);
        await page.keyboard.press('ControlOrMeta+A'); await page.keyboard.insertText(value);
        await page.waitForTimeout(150); await page.keyboard.press('Tab');
      }
      await fill('Имя пользователя',name);
      await fill('Пароль аккаунта',account.password);
      await page.getByText('Параметры подключения',{exact:true}).click();
      await fill('Профиль устройства',vault.profile);
      await fill('Отдельная локальная фраза (от 12 символов)',vault.phrase);
      await page.getByRole('button',{name:'Войти',exact:true}).click();
      await page.getByRole('button',{name:'Найти человека',exact:true}).waitFor({timeout:60000});
      for(let attempt=0;attempt<30;attempt++) {
        if(await published(account)) break;
        assert(attempt<29,'Demo device did not publish its keys');
        await page.waitForTimeout(500);
      }
      console.log(`${name}: real encrypted device provisioned; browser will now close`);
    } finally { await context.close(); }
  }
})().catch(error=>{ console.error(error.message); process.exitCode=1; });
