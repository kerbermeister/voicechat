const assert = require('node:assert/strict');
const fs = require('node:fs');
const {chromium} = require('playwright');
(async () => {
  const browser = await chromium.launch({executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});
  try {
    const context = await browser.newContext({acceptDownloads: true});
    const page = await context.newPage();
    await page.goto('http://localhost:7357/favicon.png');
    await page.addScriptTag({url:'http://localhost:7357/files.js'});
    await page.exposeFunction('checkOtherClient', async url => {
      const other = await context.newPage(); await other.goto('http://localhost:7357/favicon.png');
      assert.equal(await other.evaluate(async url => (await fetch(url)).status, url),404);
      await other.close();
    });
    const result = await page.evaluate(async () => {
      let maxRead = 0, reads = 0;
      const source = await voicechatFiles.stream('large.bin', 'application/octet-stream', 314572800, async (start,end) => {
        if (end-start > 4194304) throw new Error('Unbounded read');
        maxRead = Math.max(maxRead,end-start); reads++;
        const part = new Uint8Array(end-start); part.fill(Math.floor(start/4194304)); return part;
      });
      await window.checkOtherClient(source);
      const partial = await fetch(source, {headers:{Range:'bytes=4194304-4194319'}});
      const data = new Uint8Array(await partial.arrayBuffer());
      if (partial.status !== 206 || data.length !== 16 || !data.every(b=>b===1)) throw new Error('Range mismatch');
      if ((await fetch(source,{headers:{Range:'bytes=314572800-'}})).status !== 416) throw new Error('Invalid range accepted');
      const response = await fetch(source);
      const reader = response.body.getReader(); let total = 0;
      while (true) { const {done,value} = await reader.read(); if (done) break; total+=value.length; }
      const cache = response.headers.get('Cache-Control');
      voicechatFiles.revoke(source);
      if ((await fetch(source)).status !== 404) throw new Error('Revoked source available');
      return {maxRead, reads,total,cache};
    });
    assert.equal(result.total,314572800); assert.equal(result.maxRead,4194304); assert.equal(result.cache,'no-store');
    const downloadEvent = page.waitForEvent('download');
    const finished = page.evaluate(() => voicechatFiles.download('large-stream.bin', 'application/octet-stream', 314572800, async (start,end) => {
      if (end-start > 4194304) throw new Error('Unbounded download');
      return new Uint8Array(end-start);
    }));
    finished.catch(() => {});
    const download = await downloadEvent;
    const location = await download.path();
    assert.equal(fs.statSync(location).size,314572800);
    await finished;
    console.log('PASS: real 300 MiB stream and browser download, bounded reads, byte ranges, no-store and revocation');
  } finally { await browser.close(); }
})().catch(error => {console.error(error);process.exitCode=1;});
