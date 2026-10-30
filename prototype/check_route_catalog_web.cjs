// A new browser/profile, synthetic account marker only; close it on every path.
const assert = require('node:assert/strict');
const {chromium} = require('playwright');

(async () => {
  const origin = process.env.ROUTE_CATALOG_PROBE_ORIGIN;
  assert.match(origin, /^http:\/\/127\.0\.0\.1:[0-9]+$/);
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true,
  });
  try {
    const page = await browser.newPage();
    page.on('pageerror', error => console.error('Probe browser error:', error.message));
    for (const suffix of ['', '/?reopen=1']) {
      await page.goto(origin + suffix);
      await page.waitForFunction(() => document.body?.dataset.routeResult, null, {timeout:60000});
      const result = await page.evaluate(() => JSON.parse(document.body.dataset.routeResult));
      assert.equal(result.ok, true, result.error);
      assert.equal(result.revision, 4);
    }
    console.log('PASS: JS web client / WASM crypto, signed D discovery, localStorage and real page reload');
  } finally {
    await browser.close();
  }
})().catch(error => {console.error(error); process.exitCode = 1;});
