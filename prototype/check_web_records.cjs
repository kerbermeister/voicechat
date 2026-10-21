// Inspect only disposable lab profiles; never prints stored values or secrets.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');
(async () => {
  const run = JSON.parse(fs.readFileSync(path.join(__dirname, '../.prototype/web.json'))).RUN_ID;
  const browser = await chromium.connectOverCDP(process.env.CDP_URL || 'http://localhost:9223');
  try {
    const page = browser.contexts()[0].pages().find(p => p.url() === 'http://localhost:7358/');
    assert(page, 'Laboratory web tab required');
    const counts = await page.evaluate(async run => {
      const request = r => new Promise((resolve,reject) => {r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});
      const databases = await indexedDB.databases();
      const selected = databases.filter(d=>d.name.startsWith(`voicechat_probe_${run}-`) && d.name.endsWith('.encrypted'));
      const counts=[];
      for (const info of selected) {
        const db = await request(indexedDB.open(info.name)); let records=0;
        try {
          for (const store of db.objectStoreNames) {
            const values = await request(db.transaction(store).objectStore(store).getAll());
            for (const value of values) {
              if(typeof value !== 'string') throw new Error('Plaintext record detected');
              const envelope=JSON.parse(value);
              if(envelope.v!==1 || typeof envelope.iv!=='string' || typeof envelope.body!=='string' || Object.keys(envelope).length!==3) throw new Error('Invalid encrypted envelope');
              records++;
            }
          }
        } finally {db.close();}
        counts.push(records);
      }
      return counts;
    }, run);
    assert.equal(counts.length,3, 'Expected original Alice, restored Alice and Carol vaults');
    assert(counts.every(n=>n>20));
    console.log(`PASS: all persisted values are encrypted envelopes across ${counts.length} web profiles (${counts.reduce((a,b)=>a+b,0)} records)`);
  } finally {await browser.close();}
})().catch(error=>{console.error(error.message);process.exitCode=1;});
