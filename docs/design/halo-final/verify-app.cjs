// Smoke check of a built, unauthenticated web client. Never submits account forms.
const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 const results=[];
 try {
  for(const width of [1440,390,320]) {
   const page=await browser.newPage({viewport:{width,height:900},locale:'ru-RU'});const errors=[];
   page.on('pageerror',e=>errors.push(e.message));
   await page.goto('http://localhost:7362/');
   await page.locator('flt-semantics-placeholder').waitFor({timeout:60000});
   await page.locator('flt-semantics-placeholder').evaluate(e=>e.click());
   const create=page.getByRole('button',{name:'Создать аккаунт',exact:true});
   await create.waitFor({timeout:30000});
   await page.screenshot({path:path.join(__dirname,`runtime-web-${width}.png`)});
   await create.click();
   await page.getByRole('textbox',{name:'Имя пользователя · латиницей',exact:true}).waitFor();
   assert.equal(await page.getByRole('textbox',{name:'Отдельная локальная фраза',exact:true}).count(),0);
   const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth);
   results.push({width,errors,horizontalOverflow:overflow,registrationReached:true});
   assert.equal(errors.length,0);assert.equal(overflow,false);
   await page.close();
  }
  fs.writeFileSync(path.join(__dirname,'runtime-web-verification.json'),JSON.stringify({results,limits:'Unauthenticated browser smoke only. No account forms submitted, no network workflows or calls verified.'},null,2));
  console.log(JSON.stringify(results));
 } finally {await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
