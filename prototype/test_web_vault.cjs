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
    await page.evaluate(() => voicechatVault.writeAccount('{"profile":"first"}'));
    assert.equal(await other.evaluate(() => voicechatVault.readAccount()), null);
    await other.evaluate(() => voicechatVault.writeAccount('{"profile":"second"}'));
    assert.equal(await page.evaluate(() => voicechatVault.readAccount()), '{"profile":"first"}');
    await page.evaluate(() => voicechatVault.writeAccount(null));
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
    await assert.rejects(page.evaluate(n => voicechatVault.open(n, null, true), name));
    await page.evaluate(([n,p]) => voicechatVault.open(n,p,true), [name,password]);
    const storage = await page.evaluate(() => JSON.stringify({...sessionStorage}));
    assert(!storage.includes(password)); assert(!storage.includes('PRIVATE_TEST_TOKEN'));
    assert(storage.includes('voicechat.unlock:'));
    await page.reload(); await page.addScriptTag({url: `${url}/vault.js`});
    await page.evaluate(n => voicechatVault.open(n,null,true), name);
    assert.equal(await page.evaluate(([n,c]) => voicechatVault.decrypt(n,'client','token',c), [name,cipher]), 'PRIVATE_TEST_TOKEN');
    await assert.rejects(other.evaluate(n => voicechatVault.open(n,null,true), name));
    await page.evaluate(n => voicechatVault.close(n), name);
    assert(!await page.evaluate(n => sessionStorage.getItem(`voicechat.unlock:${n}`), name));
    await page.reload(); await page.addScriptTag({url: `${url}/vault.js`});
    await assert.rejects(page.evaluate(n => voicechatVault.open(n,null,true), name));
    await page.evaluate(([n,p]) => voicechatVault.open(n,p,true), [name,password]);
    await page.evaluate(n => voicechatVault.close(n), name);
    await page.evaluate(([n,p]) => voicechatVault.open(n,p,false), [name,password]);
    assert(!await page.evaluate(n => sessionStorage.getItem(`voicechat.unlock:${n}`), name));
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
    // Existing version-1 vaults used deriveKey; deriving bits then importing must stay compatible.
    await page.evaluate(async ([n, password]) => {
      const encoder = new TextEncoder();
      const b64 = data => btoa(String.fromCharCode(...new Uint8Array(data)));
      const salt = crypto.getRandomValues(new Uint8Array(16));
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const material = await crypto.subtle.importKey('raw', encoder.encode(password), 'PBKDF2', false, ['deriveKey']);
      const key = await crypto.subtle.deriveKey({name:'PBKDF2', hash:'SHA-256', salt, iterations:600000}, material, {name:'AES-GCM',length:256}, false, ['encrypt','decrypt']);
      const body = await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:encoder.encode(JSON.stringify([n,'meta','header',1]))}, key, encoder.encode('voicechat-vault-v1'));
      const req = indexedDB.open(`${n}.vault`,1); req.onupgradeneeded=()=>req.result.createObjectStore('meta');
      const db = await new Promise((resolve,reject)=>{req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error);});
      const txn = db.transaction('meta','readwrite');
      txn.objectStore('meta').put({v:1,salt:b64(salt),check:JSON.stringify({v:1,iv:b64(iv),body:b64(body)})},'header');
      await new Promise((resolve,reject)=>{txn.oncomplete=resolve;txn.onabort=()=>reject(txn.error);}); db.close();
    }, [name,password]);
    await page.evaluate(([n,p]) => voicechatVault.open(n,p,true), [name,password]);
    await page.evaluate(n => sessionStorage.setItem(`voicechat.unlock:${n}`, btoa(String.fromCharCode(...new Uint8Array(32)))), name);
    await page.reload(); await page.addScriptTag({url: `${url}/vault.js`});
    await assert.rejects(page.evaluate(n => voicechatVault.open(n,null,true), name));
    await page.evaluate(([n,p]) => voicechatVault.open(n,p,false), [name,password]);
    await page.evaluate(n => voicechatVault.close(n), name);
    await page.evaluate(n => voicechatVault.erase(n), name);
    console.log('PASS: legacy preservation, missing-header refusal, vault encryption, tampering, record binding, lock, wrong password, reload, opt-in tab resume, lock clears resume, opt-out, version-1 compatibility, corrupt resume rejection, exclusive tabs, erase');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode=1; });
