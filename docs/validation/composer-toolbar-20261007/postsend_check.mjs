import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import {readFile,writeFile} from 'node:fs/promises';
import {extname,join} from 'node:path';
import assert from 'node:assert/strict';
const require=createRequire((process.env.BROWSER_TOOLS_DIR||process.env.TMPDIR+'/browser-tools')+'/package.json');
const {chromium}=require('playwright');
const [buildDir,outDir,phase]=process.argv.slice(2);
const server=createServer(async(req,res)=>{try {
 const path=join(buildDir,req.url.split('?')[0]==='/'?'index.html':req.url.split('?')[0]);
 res.setHeader('Content-Type',({'.html':'text/html','.js':'application/javascript','.wasm':'application/wasm','.json':'application/json','.ttf':'font/ttf'})[extname(path)]||'application/octet-stream');
 res.end(await readFile(path));
} catch {res.writeHead(404);res.end();}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await chromium.launch({headless:true,env:{...process.env,TMPDIR:process.env.BROWSER_TMPDIR||'/tmp/handrail-codex-heavy-command-locks/focus-browser-ba07'},executablePath:process.env.FLUTTER_BROWSER||'/opt/handrail/.handrail/flutter-sdk/bin/cache/mock-authority-playwright/chromium-1234/chrome-linux64/chrome',args:['--no-sandbox','--disable-dev-shm-usage']});
const results={phase,browser:browser.version(),cases:[]};
try {
 for(const [failure,width] of [[false,1050],[true,1050],[false,390]]) {
  const context=await browser.newContext({viewport:{width,height:780}});
  const page=await context.newPage();page.setDefaultTimeout(8000); const errors=[];page.on('console',m=>{if(m.text().includes('FOCUS_'))console.log(m.text());});page.on('pageerror',e=>errors.push(String(e)));
  await page.route('**/*',async route=>{const u=new URL(route.request().url());if(u.hostname==='127.0.0.1')return route.continue();if(u.hostname==='fonts.gstatic.com')return route.fulfill({contentType:'font/ttf',body:await readFile('/opt/handrail/.handrail/flutter-sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf')});return route.abort();});
  const state=()=>page.locator('#accepted-state').textContent().then(JSON.parse);
  const wait=fn=>page.waitForFunction(fn,null,{timeout:10000});
  const command=cmd=>page.evaluate(c=>window.postMessage(c,'*'),cmd);
  const snap=async name=>{await page.screenshot({path:join(outDir,`${phase}-${failure?'failure':'success'}-${width}-${name}.png`)});return {accepted:await state(),dom:await page.locator('input,textarea').evaluateAll(ns=>ns.map(n=>({value:n.value,focused:n===document.activeElement,disabled:n.disabled})))}};
  const row={failure,width,errors}; results.cases.push(row);
  try {
   await page.goto(`http://127.0.0.1:${server.address().port}`);
   await wait(()=>document.querySelector('#accepted-state')?.textContent.includes('requests'));
   row.canvasKitResources=await page.evaluate(()=>performance.getEntriesByType('resource').map(e=>e.name).filter(n=>n.includes('canvaskit')));
   assert.ok(row.canvasKitResources.length>0);
   await page.locator('textarea').last().click();
   await page.keyboard.type('Original',{delay:30});
   await wait(()=>JSON.parse(document.querySelector('#accepted-state').textContent).text==='Original');
   await command('hold-send');if(failure)await command('fail-send');
   await page.getByRole('button',{name:/Send message/}).last().click();
   await wait(()=>{const s=JSON.parse(document.querySelector('#accepted-state').textContent);return s.disabledObserved&&s.requests.some(x=>x.operation==='send')});
   row.disabled=await snap('disabled');
   assert.equal(row.disabled.accepted.canRequestFocus,false);
   await command('release-send');
   await wait(()=>{const s=JSON.parse(document.querySelector('#accepted-state').textContent);return s.canRequestFocus&&!s.sending});
   // No blur, click, focus, Tab, or controller mutation between send and input.
   row.enabled=await snap('enabled');
   await command('hold-draft');
   await page.keyboard.type('X');
   await page.waitForTimeout(300);
   row.firstCharacter=await snap('first-character');
   await page.keyboard.type(' next',{delay:30});await page.waitForTimeout(300);
   row.nextDraft=await snap('next-draft');
   const expected=failure?'OriginalX next':'X next';
   row.accepted=row.nextDraft.accepted.text===expected;
   if(phase==='baseline') {
    assert.equal(row.accepted,false);
    assert.equal(row.firstCharacter.accepted.text,failure?'Original':'');
   }
   if(phase==='published') {
    assert.equal(row.firstCharacter.accepted.text,failure?'OriginalX':'X');
    assert.equal(row.nextDraft.accepted.text,expected);
    assert.equal(row.nextDraft.accepted.draft,expected);
    assert.ok(row.nextDraft.accepted.durable.includes(expected));
    assert.equal(row.nextDraft.accepted.canonical.length,failure?0:1);
    assert.equal(row.nextDraft.accepted.acceptedCanonicalMessages.length,failure?0:1);
    await command('release-draft');
    await wait(()=>JSON.parse(document.querySelector('#accepted-state').textContent).pending===false);
    await command('hold-send');
    await page.getByRole('button',{name:/Send message/}).last().click();
    await wait(()=>JSON.parse(document.querySelector('#accepted-state').textContent).disabledObserved);
    await command('release-send');
    await wait(()=>{const s=JSON.parse(document.querySelector('#accepted-state').textContent);return s.canRequestFocus&&!s.sending});
    row.repeatCompletion=await state();
    await command('hold-draft');
    await page.keyboard.type('R');await page.waitForTimeout(300);
    row.repeated=await snap('repeated');
    assert.equal(row.repeated.accepted.text,row.repeatCompletion.text+'R');
    assert.equal(row.repeated.accepted.draft,row.repeatCompletion.text+'R');
    assert.ok(row.repeated.accepted.durable.includes(row.repeatCompletion.text+'R'));
    await command('release-draft');
    assert.equal(row.repeated.accepted.canonical.length,failure?1:2);
    assert.equal(row.repeated.accepted.acceptedCanonicalMessages.length,failure?1:2);
    row.realBrowserSystemIme = 'unverified: no supported system IME in this headless run';
    await page.keyboard.press('ControlOrMeta+A');
    await page.getByRole('button',{name:'Bold',exact:true}).last().click();
    await page.waitForTimeout(300);row.toolbar=await snap('toolbar');
    await page.keyboard.type('T');await page.waitForTimeout(300);row.afterToolbarInput=await snap('toolbar-input');
    row.toolbarInputAccepted=row.afterToolbarInput.accepted.text==='T';
   }
  } catch(e) {row.error=String(e);row.final=await state().catch(()=>null);}
  console.log(JSON.stringify({failure,width,accepted:row.accepted,error:row.error,ime:row.browserCompositionAccepted}));
  await context.close();
 }
 if(phase==='published') {
  for(const boundary of ['outside','hide-return','channel','thread','account','logout']) {
   const context=await browser.newContext({viewport:{width:390,height:780}});
   const page=await context.newPage();page.setDefaultTimeout(8000); const row={boundary,errors:[]};results.cases.push(row);
   page.on('pageerror',e=>row.errors.push(String(e)));
   await page.route('**/*',async route=>{const u=new URL(route.request().url());if(u.hostname==='127.0.0.1')return route.continue();if(u.hostname==='fonts.gstatic.com')return route.fulfill({contentType:'font/ttf',body:await readFile('/opt/handrail/.handrail/flutter-sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf')});return route.abort();});
   const state=()=>page.locator('#accepted-state').textContent().then(JSON.parse);
   const wait=fn=>page.waitForFunction(fn,null,{timeout:10000});
   const command=cmd=>page.evaluate(c=>window.postMessage(c,'*'),cmd);
   try {
    await page.goto(`http://127.0.0.1:${server.address().port}`);
    await page.locator('textarea').last().click();await page.keyboard.type('Narrow draft',{delay:25});
    await wait(()=>JSON.parse(document.querySelector('#accepted-state').textContent).text==='Narrow draft');
    await command('hold-send');await page.getByRole('button',{name:/Send message/}).last().click();
    await wait(()=>JSON.parse(document.querySelector('#accepted-state').textContent).disabledObserved);
    row.disabled=await state();
    if(boundary==='outside')await page.getByRole('textbox',{name:'Outside editor',exact:true}).click();
    else await command(boundary==='hide-return'?'hide':boundary);
    await page.waitForTimeout(200);
    if(boundary==='hide-return')await command('show');
    await page.waitForTimeout(200);
    await command('release-send');await page.waitForTimeout(400);
    row.beforeInput=await state();await page.keyboard.type('Z');await page.waitForTimeout(300);row.afterInput=await state();
    assert.equal(row.afterInput.focus,false);
    assert.equal(row.afterInput.text,row.beforeInput.text);
    if(boundary==='outside')assert.equal(row.afterInput.outsideFocus,true);
    assert.equal(row.errors.length,0);
    await page.screenshot({path:join(outDir,`${phase}-narrow-${boundary}.png`)});
    row.passed=true;
   } catch(e) {row.error=String(e);row.final=await state().catch(()=>null);}
   await context.close();
  }
 }
} finally {
 await writeFile(join(outDir,`${phase}-browser.json`),JSON.stringify(results,null,2)+'\n');
 await browser.close();server.close();
}
console.log(JSON.stringify(results.cases.map(x=>({failure:x.failure,accepted:x.accepted,error:x.error,first:x.firstCharacter?.accepted.text,focus:x.enabled?.accepted.focus})),null,2));
if(results.cases.some(x=>x.error))process.exitCode=1;
