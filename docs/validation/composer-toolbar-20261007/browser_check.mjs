import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {extname,join} from 'node:path';
import assert from 'node:assert/strict';
const require=createRequire(process.env.BROWSER_TOOLS_DIR+'/package.json');
const {chromium}=require('playwright');
const [buildDir,outDir,phase]=process.argv.slice(2);
const server=createServer(async(req,res)=>{try {
 const path=join(buildDir,req.url.split('?')[0]==='/'?'index.html':req.url.split('?')[0]);
 res.setHeader('Content-Type',({'.html':'text/html','.js':'application/javascript','.wasm':'application/wasm','.json':'application/json','.ttf':'font/ttf'})[extname(path)]||'application/octet-stream');res.end(await readFile(path));
} catch {res.writeHead(404);res.end();}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await chromium.launch({headless:true,env:{...process.env,TMPDIR:process.env.BROWSER_TMPDIR},executablePath:'/opt/handrail/.handrail/flutter-sdk/bin/cache/mock-authority-playwright/chromium-1234/chrome-linux64/chrome',args:['--no-sandbox','--disable-dev-shm-usage']});
const results={phase,browser:browser.version(),cases:[]};
try {
 for(const format of (process.env.FORMATS||'Bold').split(',')) for(const mode of (process.env.MODES||'sdk,sync,frame').split(',')) for(const activation of (process.env.ACTIVATIONS||'pointer,keyboard').split(',')) for(const width of (process.env.WIDTHS||'1050').split(',').map(Number)) {
  const context=await browser.newContext({viewport:{width,height:780}});const page=await context.newPage();page.setDefaultTimeout(8000);
  const row={mode,format,activation,width,errors:[]};results.cases.push(row);
  page.on('pageerror',e=>row.errors.push(String(e)));
  await page.route('**/*',async route=>{const u=new URL(route.request().url());if(u.hostname==='127.0.0.1')return route.continue();if(u.hostname==='fonts.gstatic.com')return route.fulfill({contentType:'font/ttf',body:await readFile('/opt/handrail/.handrail/flutter-sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf')});return route.abort();});
  await page.addInitScript(()=>{
   window.browserTrace=[];
   for (const type of ['focusin','focusout','pointerdown','pointerup','keydown','keyup','beforeinput','input','compositionstart','compositionupdate','compositionend']) document.addEventListener(type,e=>{
    window.browserTrace.push({type,time:performance.now(),tag:e.target.tagName,role:e.target.getAttribute?.('role'),label:e.target.getAttribute?.('aria-label'),key:e.key,data:e.data,value:e.target.value,active:document.activeElement?.tagName,stack:type.startsWith('focus')?new Error().stack:undefined});
   },true);
  });
  const state=()=>page.locator('#accepted-state').textContent().then(JSON.parse);
  const command=cmd=>page.evaluate(c=>window.postMessage(c,'*'),cmd);
  const snap=async name=>{await command('record');await page.waitForTimeout(60);await page.screenshot({path:join(outDir,`${phase}-${mode}-${format.toLowerCase().replaceAll(' ','-')}-${activation}-${width}-${name}.png`)});return {accepted:await state(),dom:await page.locator('input,textarea').evaluateAll(ns=>ns.map(n=>({value:n.value,focused:n===document.activeElement,disabled:n.disabled,selection:[n.selectionStart,n.selectionEnd]})))}};
  try {
   await page.goto(`http://127.0.0.1:${server.address().port}/${mode==='sdk'?'':'?control='+mode}`);
   if(process.env.CANVAS_POINTER==='1') {
    const editor=page.locator('textarea').last();await editor.waitFor();const box=await editor.boundingBox();
    await page.mouse.click(box.x+box.width/2,box.y+box.height/2);
    await page.waitForTimeout(150); // Initial editing precondition only, never after toolbar activation.
   } else await page.locator('textarea').last().click();
   await page.keyboard.type('Original',{delay:25});
   await page.waitForFunction(()=>JSON.parse(document.querySelector('#accepted-state').textContent).text==='Original');
   await command('hold-draft');await page.keyboard.press('ControlOrMeta+A');
   row.before=await snap('before');
   row.canvasKit=await page.evaluate(()=>performance.getEntriesByType('resource').map(e=>e.name).filter(n=>n.includes('canvaskit')));
   if(activation==='pointer') {
    const button=page.getByRole('button',{name:format,exact:true}).last();
    if(mode==='sdk') for(let i=0;i<6;i++) {
     const box=await button.boundingBox();
     if(box.x>=72 && box.x+box.width<=width-74) break;
     await page.mouse.move(width/2,box.y+box.height/2);
     await page.mouse.wheel(160,0);await page.waitForTimeout(160);
    }
    if(process.env.CANVAS_POINTER==='1') {
     const box=await button.boundingBox();await page.mouse.click(box.x+box.width/2,box.y+box.height/2);
    } else await button.click();
   }
   else {
    row.navigation=[];
    for(let i=0;i<12;i++) {
     await page.keyboard.press('Tab');await page.waitForTimeout(40);
     const focused=await page.getByRole('button',{name:format,exact:true}).last().evaluate(n=>({tag:document.activeElement?.tagName,label:n===document.activeElement?'TARGET':document.activeElement?.textContent}));row.navigation.push(focused);
     if(focused.label==='TARGET') break;
    }
    assert.ok(row.navigation.at(-1).label==='TARGET',format+' must be keyboard reachable');
    await page.keyboard.press('Enter');
   }
   // First character is sent immediately after activation, without refocusing.
   await page.keyboard.type('X');
   row.first=await snap('first');
   await page.keyboard.type(' next',{delay:25});
   await page.waitForTimeout(350);row.continued=await snap('continued');
   row.inputAccepted=row.first.accepted.text==='X' && row.continued.accepted.text==='X next';
   row.formatted=mode==='sdk'?row.first.accepted.draft:row.first.accepted.bold;
   if(mode==='sdk' && row.inputAccepted) {
    const expected={Bold:'**X** next',Italic:'*X* next','Inline code':'`X` next','Bulleted list':'- X next','Numbered list':'1. X next','Code block':'```\nX next\n```'}[format];
    assert.equal(row.continued.accepted.draft,expected);
    assert.ok(JSON.stringify(JSON.parse(row.continued.accepted.durable)).includes(JSON.stringify(expected)));
    // Same-content delayed acknowledgement must leave the real accepted caret intact.
    await command('release-draft');
    await page.waitForFunction(()=>JSON.parse(document.querySelector('#accepted-state').textContent).pending===false);
    row.afterAck=await state();
    assert.deepEqual(row.afterAck.selection,[6,6]);assert.equal(row.afterAck.text,'X next');
    await command('hold-draft');await page.keyboard.type(' again',{delay:20});await page.waitForTimeout(350);
    row.repeated=await state();assert.equal(row.repeated.text,'X next again');
    assert.ok(JSON.stringify(JSON.parse(row.repeated.durable)).includes(JSON.stringify(row.repeated.draft)));
    assert.equal(row.repeated.requests.filter(x=>x.operation==='send').length,0);
   }
   row.browserTrace=await page.evaluate(()=>window.browserTrace);
   assert.equal(row.errors.length,0);
   if(phase==='candidate' || process.env.REQUIRE_INPUT==='1') assert.equal(row.inputAccepted,true);
  } catch(e) {row.error=String(e);row.final=await state().catch(()=>null);row.browserTrace=await page.evaluate(()=>window.browserTrace);}
  console.log(JSON.stringify({mode,format,activation,width,accepted:row.inputAccepted,error:row.error,first:row.first?.accepted.text,focus:row.first?.accepted.focus,dom:row.first?.dom}));
  await context.close();
 }
} finally {await writeFile(join(outDir,`${phase}-browser.json`),JSON.stringify(results,null,2)+'\n');await browser.close();server.close();}
if(results.cases.some(x=>x.error))process.exitCode=1;
