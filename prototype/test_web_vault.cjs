// Run with Playwright available in NODE_PATH, against the locally built web app.
const assert = require('node:assert/strict');
const {chromium} = require('playwright');
(async () => {
  const browser = await chromium.launch({executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    const other = await context.newPage();
    const url = process.env.WEB_URL || 'http://localhost:7357';
    for (const p of [page, other]) { await p.goto(`${url}/favicon.png`); await p.addScriptTag({url: `${url}/vault.js`}); }
    const name = `vault-test-${Date.now()}`;
    const password = 'independent local test passphrase';
    await page.evaluate(([n,p]) => voicechatVault.open(n,p), [name,password]);
    const cipher = await page.evaluate(n => voicechatVault.encrypt(n,'client','token','PRIVATE_TEST_TOKEN'), name);
    assert(!cipher.includes('PRIVATE_TEST_TOKEN'));
    assert.equal(await page.evaluate(([n,c]) => voicechatVault.decrypt(n,'client','token',c), [name,cipher]), 'PRIVATE_TEST_TOKEN');
    await assert.rejects(other.evaluate(([n,p]) => voicechatVault.open(n,p), [name,password]));
    await assert.rejects(other.evaluate(n => voicechatVault.erase(n), name));
    await assert.rejects(page.evaluate(([n,c]) => voicechatVault.decrypt(n,'client','different-record',c), [name,cipher]));
    const tampered = JSON.parse(cipher); tampered.body = 'AAAA' + tampered.body.slice(4);
    await assert.rejects(page.evaluate(([n,c]) => voicechatVault.decrypt(n,'client','token',c), [name,JSON.stringify(tampered)]));
    const header = await page.evaluate(async n => {
      const req = indexedDB.open(`${n}.vault`);
      const db = await new Promise((r,j) => {req.onsuccess=()=>r(req.result);req.onerror=()=>j(req.error);});
      const get = db.transaction('meta').objectStore('meta').get('header');
      const value = await new Promise(r => {get.onsuccess=()=>r(get.result);}); db.close();return value;
    }, name);
    assert(!JSON.stringify(header).includes(password));
    await page.evaluate(n => voicechatVault.close(n), name);
    await assert.rejects(page.evaluate(([n,c]) => voicechatVault.decrypt(n,'client','token',c), [name,cipher]));
    await assert.rejects(page.evaluate(n => voicechatVault.open(n,'incorrect local passphrase'), name));
    await page.reload(); await page.addScriptTag({url: `${url}/vault.js`});
    await page.evaluate(([n,p]) => voicechatVault.open(n,p), [name,password]);
    assert.equal(await page.evaluate(([n,c]) => voicechatVault.decrypt(n,'client','token',c), [name,cipher]), 'PRIVATE_TEST_TOKEN');
    await page.evaluate(n => voicechatVault.close(n), name);
    await page.evaluate(n => voicechatVault.erase(n), name);
    assert(!await page.evaluate(async n => (await indexedDB.databases()).some(d => d.name.startsWith(n)), name));
    await page.evaluate(async n => {
      const request = r => new Promise((resolve,reject) => { r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error); });
      for (const suffix of ['', '.encrypted']) {
        const db = await request(indexedDB.open(n + suffix, 1)); db.close();
        let refused = false;
        try { await voicechatVault.open(n, 'independent local test passphrase'); } catch (_) { refused = true; }
        if (!refused) throw new Error('Legacy/missing-header store was accepted');
        if (!(await indexedDB.databases()).some(d=>d.name===n+suffix)) throw new Error('Existing data was removed');
        await request(indexedDB.deleteDatabase(n + suffix));
        await request(indexedDB.deleteDatabase(n + '.vault'));
      }
    }, name);
    console.log('PASS: legacy preservation, missing-header refusal, vault encryption, tampering, record binding, lock, wrong password, reload, exclusive tabs, erase');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode=1; });
