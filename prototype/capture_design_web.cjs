// Run against a web build of integration_test/design_gallery_test.dart.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');

(async () => {
  const [url, output] = process.argv.slice(2);
  assert(url && output, 'Usage: node prototype/capture_design_web.cjs URL OUTPUT');
  assert.equal(new URL(url).hostname, 'localhost');
  fs.mkdirSync(output, {recursive: true});
  const browser = await chromium.launch({
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true,
  });
  try {
    const page = await browser.newPage({viewport: {width: 390, height: 844}, deviceScaleFactor: 1, isMobile: true, hasTouch: true});
    page.on('console', msg => {
      if (/GALLERY:|EXCEPTION|Test failed|Expected:|Actual:/.test(msg.text())) console.log(msg.text());
    });
    await page.goto(url);
    await page.waitForFunction(() => typeof window.$flutterDriver === 'function', null, {timeout: 60000});
    async function request(message) {
      await page.evaluate(message => {
        window.$flutterDriverResult = null;
        window.$flutterDriver(JSON.stringify({command: 'request_data', ...(message ? {message} : {})}));
      }, message);
      await page.waitForFunction(() => window.$flutterDriverResult != null, null, {timeout: 120000});
      return page.evaluate(() => {
        const result = JSON.parse(window.$flutterDriverResult);
        window.$flutterDriverResult = null;
        if (result.isError) throw new Error(JSON.stringify(result.response));
        return JSON.parse(result.response.message);
      });
    }
    let result = await request('pending');
    while (result.data?.web_driver_command?.endsWith('.screenshot') || result.data?.web_driver_command?.endsWith('.ack')) {
      if (result.data.web_driver_command.endsWith('.screenshot')) {
        const name = result.data.screenshot_name;
        assert(/^[a-z0-9-]+$/.test(name));
        await page.screenshot({path: path.join(output, name + '.png')});
        result = await request('complete');
      } else {
        result = await request('pending');
      }
    }
    result = await request(null);
    assert.equal(result.result, 'true', JSON.stringify(result.failureDetails));
    console.log('PASS: mobile web screen inventory');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
