// Synthetic public data only; exercise our locally served binary QR decoder.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');
(async()=>{
  const image=fs.readFileSync(path.join(__dirname,'../.prototype/qr-fixture.png'));
  const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
  try {
    const page=await browser.newPage();
    const external=[];
    await page.route('**/*',route=>{
      const url=new URL(route.request().url());
      if(url.protocol==='data:' || url.hostname==='localhost') return route.continue();
      external.push(url.origin); return route.abort();
    });
    await page.route('http://localhost:7358/',route=>route.fulfill({contentType:'text/html',body:'<!doctype html><title>Local QR decoder</title>'}));
    await page.goto('http://localhost:7358/',{waitUntil:'domcontentloaded'});
    await page.addScriptTag({url:'http://localhost:7358/zxing.js'});
    const decoded=await page.evaluate(async data=>{
      const image=new Image();image.src='data:image/png;base64,'+data;await image.decode();
      const canvas=document.createElement('canvas');canvas.width=canvas.height=512;
      const context=canvas.getContext('2d');context.drawImage(image,0,0);
      const results=await ZXingWASM.readBarcodes(context.getImageData(0,0,512,512),{formats:['QRCode'],tryHarder:true});
      const bytes=results.find(result=>result.isValid)?.bytes;
      const txn=new TextEncoder().encode('current-request');
      const expected=new Uint8Array([...new TextEncoder().encode('MATRIX'),2,0,0,txn.length,...txn,...Array(32).fill(2),...Array(32).fill(1),...Array(11).fill(99)]);
      return bytes?.length===expected.length && bytes.every((value,index)=>value===expected[index]);
    },image.toString('base64'));
    assert(decoded,'Binary Matrix QR did not survive render/decode');
    assert.equal(external.length,0,'QR decoder attempted external code loading');
    console.log('PASS: Flutter binary QR decoded by local web WASM; no external requests');
  } finally {await browser.close();}
})().catch(error=>{console.error(error.message);process.exitCode=1;});
