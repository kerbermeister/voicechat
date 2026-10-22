// Sync the retained Bob fixture, without creating a replacement device or changing trust.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');
const root = path.join(__dirname, '..', '.prototype');
const account = JSON.parse(fs.readFileSync(path.join(root, 'accounts.json'))).bob;
const vault = JSON.parse(fs.readFileSync(path.join(root, 'demo-devices/bob.json')));
let step = 'open retained vault';
async function retainedIdentity({profile, phrase}) {
  const name = 'voicechat_probe_' + encodeURIComponent(profile);
  const available = await indexedDB.databases();
  if (!available.some(d => d.name === name + '.encrypted')) throw new Error('Retained vault missing');
  const read = r => new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result); r.onerror = () => reject(new Error('Vault read failed'));
  });
  if (phrase) await voicechatVault.open(name, phrase, false);
  let db;
  try {
    db = await read(indexedDB.open(name + '.encrypted'));
    const values = await Promise.all(['user_id', 'device_id'].map(async key => {
      const raw = await read(db.transaction('box_client', 'readonly').objectStore('box_client').get(key));
      return JSON.parse(await voicechatVault.decrypt(name, 'box_client', key, raw));
    }));
    if (values[0] !== '@bob:voicechat.local' || typeof values[1] !== 'string') throw new Error('Unexpected retained identity');
    return values[1];
  } finally {db?.close(); if (phrase) await voicechatVault.close(name);}
}

async function withRetainedBob(action) {
  assert.equal(account.username, 'bob');
  assert.equal(vault.profile, 'demo-bob');
  const context = await chromium.launchPersistentContext(path.join(root, 'demo-devices/bob'), {
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true, viewport: {width: 1280, height: 900},
  });
  try {
    const page = context.pages()[0] ?? await context.newPage();
    await page.goto('http://localhost:7357/manifest.json');
    await page.addScriptTag({url: 'http://localhost:7357/vault.js'});
    const identity = await page.evaluate(retainedIdentity, vault);
    let replacementLogin = false;
    await page.route('**/_matrix/client/v3/login', route => {
      if (route.request().method() !== 'POST') return route.continue();
      replacementLogin = true;
      return route.abort();
    });
    step = 'open login screen';
    await page.goto('http://localhost:7357/');
    await page.locator('flt-semantics-placeholder').evaluate(el => el.click());
    async function fill(label, value) {
      step = label;
      const field = page.getByRole('textbox', {name: label, exact: true});
      await field.click({timeout: 5000}); await page.waitForTimeout(150);
      await page.keyboard.press('ControlOrMeta+A'); await page.keyboard.insertText(value);
      await page.waitForTimeout(150); await page.keyboard.press('Tab');
    }
    await page.getByRole('button', {name: 'Открыть переписку', exact: true}).waitFor({timeout: 10000});
    await page.getByText('@bob:voicechat.local', {exact: true}).waitFor();
    await fill('Отдельная локальная фраза (от 12 символов)', vault.phrase);
    step = 'resume retained device';
    const synced = page.waitForResponse(r => new URL(r.url()).pathname.endsWith('/sync') && r.status() === 200, {timeout: 30000}).catch(error => error);
    await page.getByRole('button', {name: 'Открыть переписку', exact: true}).click();
    await page.getByRole('button', {name: 'Найти человека', exact: true}).waitFor({timeout: 30000});
    const response = await synced;
    assert(!(response instanceof Error), 'Retained device must sync');
    const sync = await response.json();
    assert.equal(replacementLogin, false, 'Must reuse the retained encrypted device');
    // Let the SDK durably process this sync; no microphone, camera or call is started.
    await page.waitForTimeout(2000);
    assert.equal(await page.evaluate(retainedIdentity, {profile: vault.profile}), identity);
    console.log(JSON.stringify({retainedDeviceReused: true, receivedToDeviceEvents: sync.to_device?.events?.length ?? 0}));
    if (action) await action(page);
  } finally {await context.close();}
}
module.exports = withRetainedBob;
if (require.main === module) withRetainedBob().catch(error => {
  console.error('Demo history sync failed at ' + step + ': ' + error.name); process.exitCode = 1;
});
