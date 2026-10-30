// Isolated browser checks; Web Share is stubbed, not an iPhone hardware claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const {chromium} = require('playwright');
(async () => {
  const root = path.resolve(__dirname, '../apps/client/web');
  const server = http.createServer((req, res) => {
    if (req.url === '/') { res.setHeader('Content-Type', 'text/html'); res.end('<!doctype html><meta charset="utf-8"><title>VoiceChat isolated save check</title>'); return; }
    if (!['/files.js', '/files-worker.js'].includes(req.url)) { res.writeHead(404).end(); return; }
    res.setHeader('Content-Type', 'application/javascript'); res.end(fs.readFileSync(root + req.url));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch({headless: true, executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
    const context = await browser.newContext({acceptDownloads: true, userAgent: 'iPhone Safari VoiceChat Test', viewport: {width: 390, height: 844}});
    const page = await context.newPage();
    page.on('pageerror', error => console.error('PAGE:',error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.addScriptTag({url: '/files.js'});
    await page.evaluate(() => {
      Object.defineProperty(navigator, 'canShare', {value: () => true});
      Object.defineProperty(navigator, 'share', {value: async ({files}) => {
        window.shared = {name: files[0].name, bytes: Array.from(new Uint8Array(await files[0].arrayBuffer()))};
      }});
      window.result = null;
      voicechatFiles.download('<photo>.jpg', 'image/jpeg', 3, async () => new Uint8Array([7,8,9])).then(value => window.result = value);
    });
    await page.getByRole('button', {name: 'Сохранить', exact: true}).click();
    await page.waitForFunction(() => window.result === 'shared');
    assert.deepEqual(await page.evaluate(() => window.shared), {name:'<photo>.jpg',bytes:[7,8,9]});
    assert.equal(await page.locator('dialog,iframe').count(), 0);
    await page.evaluate(() => {
      window.result = null;
      voicechatFiles.download('empty.txt','text/plain',0,async()=>new Uint8Array()).then(value=>window.result=value);
    });
    await page.getByRole('button', {name: 'Отмена', exact:true}).click();
    await page.waitForFunction(() => window.result === 'cancelled');
    const downloadEvent = page.waitForEvent('download');
    const finished = page.evaluate(async () => {
      const size = 65 * 1024 * 1024;
      const result = await voicechatFiles.download('large.bin','application/pdf',size,async (from,to) => {
        if(to-from>4*1024*1024)throw Error('Unbounded export');
        const bytes=new Uint8Array(to-from);bytes.fill(42);return bytes;
      });
      if(result!=='download')throw Error('Wrong export result');
    });
    const download = await downloadEvent;
    const saved = await download.path(); await finished;
    assert.equal(fs.statSync(saved).size,65*1024*1024);
    const handle=fs.openSync(saved,'r');const bytes=Buffer.alloc(16);fs.readSync(handle,bytes,0,16,65*1024*1024-16);fs.closeSync(handle);assert(bytes.every(b=>b===42));
    await download.delete();
    assert.equal(await page.locator('iframe,dialog').count(),0);
    assert(page.url().endsWith('/'));
    console.log('PASS: share-ready dialog, safe name, cancel/return, 65 MiB bounded download and cleanup (share API stub only)');
  } finally { if(browser)await browser.close(); await new Promise(resolve=>server.close(resolve)); }
})().catch(error=>{console.error(error);process.exitCode=1;});
