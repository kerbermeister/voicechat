// Uses an existing Playwright installation; set NODE_PATH if it is in a shared runtime.
const {chromium}=require('playwright');
const fs=require('node:fs');const path=require('node:path');const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 const page=await browser.newPage({viewport:{width:1500,height:1100},deviceScaleFactor:1});
 const base=__dirname;const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('file://'+path.join(base,'index.html'));await page.evaluate(()=>document.fonts.ready);
 await page.addStyleTag({content:'.booknav{position:relative!important}'});
 const ids=await page.locator('.chapter').evaluateAll(es=>es.map(e=>e.id));
 assert.equal(ids.length,10);assert.equal(await page.locator('.screenfigure').count(),60);
 const missingActions=await page.locator('[data-action]').evaluateAll(es=>[...new Set(es.map(e=>e.dataset.action))].filter(x=>!routeDetails[x]));
 const overflow=()=>page.locator('.phone .screen').evaluateAll(es=>es.filter(e=>e.scrollHeight>e.clientHeight+2||e.scrollWidth>e.clientWidth+2).map(e=>({variant:e.closest('.chapter').id,screen:e.closest('figure').dataset.screen,y:e.scrollHeight-e.clientHeight,x:e.scrollWidth-e.clientWidth})));
 const overlaps=()=>page.locator('.phone.screen-0').evaluateAll(es=>es.flatMap(e=>{const a=e.querySelector('.addperson').getBoundingClientRect(),b=e.querySelector('.appnav').getBoundingClientRect(),c=e.querySelector('.peoplelist').getBoundingClientRect();return a.bottom>b.top+1||c.bottom>a.top+1?[{variant:e.closest('.chapter').id,navOverlap:a.bottom-b.top,listOverlap:c.bottom-a.top}]:[]}));
 const layout=[];
 for(const width of [320,375,390,768,1500]){
  await page.setViewportSize({width,height:1100});layout.push({width,pageOverflow:await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),screens:await overflow(),overlaps:await overlaps()});
 }
 await page.setViewportSize({width:1500,height:1100});
 for(const id of ids) await page.locator('#'+id).screenshot({path:path.join(base,id+'.png')});
 await page.selectOption('#screenfilter','1');assert.equal(await page.locator('.screenfigure:visible').count(),10);
 await page.locator('#haven .screen-1 [data-action="Инструменты"]').click();await page.locator('#detail').waitFor({state:'visible'});assert.equal(await page.locator('#dialogtitle').innerText(),'Инструменты');await page.keyboard.press('Escape');assert.equal(await page.locator('#detail:visible').count(),0);
 await page.selectOption('#screenfilter','all');assert.equal(await page.locator('.screenfigure:visible').count(),60);
 await page.selectOption('#surface','web');assert.equal(await page.locator('.desktop:visible').count(),10);assert.equal(await page.locator('.phone:visible').count(),0);
 const desktopOverflow=await page.locator('.desktopchat,.desktoplist').evaluateAll(es=>es.filter(e=>e.scrollWidth>e.clientWidth+2).map(e=>({variant:e.closest('.chapter').id,part:e.className,x:e.scrollWidth-e.clientWidth})));
 for(const id of ids)await page.locator('#'+id+' .desktop').screenshot({path:path.join(base,id+'-web.png')});
 await page.selectOption('#surface','mobile');await page.emulateMedia({reducedMotion:'reduce'});await page.selectOption('#direction','pearl');assert.equal(await page.evaluate(()=>location.hash),'#pearl');
 const links=await page.locator('a[href]').evaluateAll(es=>es.map(e=>e.getAttribute('href')).filter(x=>!x.startsWith('#')&&!x.startsWith('http')));
 const missingLinks=links.filter(x=>!fs.existsSync(path.resolve(base,x)));
 const imageErrors=await page.locator('img').evaluateAll(es=>es.filter(e=>!e.complete||!e.naturalWidth).map(e=>e.src));
 const tokens=JSON.parse(fs.readFileSync(path.join(base,'tokens.json')));
 function lum(hex){return hex.slice(1).match(/../g).map(x=>parseInt(x,16)/255).map(x=>x<=.04045?x/12.92:((x+.055)/1.055)**2.4).reduce((s,x,i)=>s+x*[.2126,.7152,.0722][i],0)}
 function contrast(a,b){const [lo,hi]=[lum(a),lum(b)].sort((a,b)=>a-b);return +( (hi+.05)/(lo+.05)).toFixed(2)}
 const contrastChecks=tokens.map(t=>({variant:t.id,mutedOnRaised:contrast(t.muted,t.raised),primaryOnRaised:contrast('#f1f5ff',t.raised),button:contrast('#12233c',t.accent)}));
 const result={mobileMockups:60,desktopLayouts:10,layout,desktopOverflow,missingActions,missingLinks,imageErrors,errors,contrastChecks,interactions:'filter, web/mobile, modal, Escape, direction passed',limits:'Static design studies; token contrast only, no native/hardware/media tests'};
 fs.writeFileSync(path.join(base,'verification.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));
 await browser.close();
 assert(!layout.some(x=>x.pageOverflow||x.screens.length||x.overlaps.length));assert.equal(desktopOverflow.length,0);assert.equal(missingActions.length,0);assert.equal(missingLinks.length,0);assert.equal(imageErrors.length,0);assert.equal(errors.length,0);assert(contrastChecks.every(c=>Math.min(c.mutedOnRaised,c.primaryOnRaised,c.button)>=4.5));
})();
