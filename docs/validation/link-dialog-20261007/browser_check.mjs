// Ordinary browser input only. Geometry/state are read-only fixture telemetry.
// Never assign text, call requestFocus, or refocus after a toolbar/dialog action.
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import {readFile,writeFile} from 'node:fs/promises';
import {extname,join} from 'node:path';
import assert from 'node:assert/strict';
const require=createRequire(process.env.BROWSER_TOOLS_DIR+'/package.json');
const {chromium}=require('playwright');
const [build,out,phase]=process.argv.slice(2);
const server=createServer(async(req,res)=>{try{
 const path=join(build,req.url.split('?')[0]==='/'?'index.html':req.url.split('?')[0]);
 res.setHeader('Content-Type',({'.html':'text/html','.js':'application/javascript','.wasm':'application/wasm','.json':'application/json','.ttf':'font/ttf'})[extname(path)]||'application/octet-stream');res.end(await readFile(path));
}catch{res.writeHead(404);res.end();}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await chromium.launch({headless:true,env:{...process.env,TMPDIR:process.env.BROWSER_TMPDIR},executablePath:'/opt/handrail/.handrail/flutter-sdk/bin/cache/mock-authority-playwright/chromium-1234/chrome-linux64/chrome',args:['--no-sandbox','--disable-dev-shm-usage']});
const results={phase,browser:browser.version(),semantics:false,cases:[]};
try {
 for(const width of (process.env.WIDTHS||'1050,320,390').split(',').map(Number)) {
  for(const action of (process.env.ACTIONS||'cancel,barrier,escape,apply,done,invalid,remove').split(',')) {
   const context=await browser.newContext({viewport:{width,height:780}});const page=await context.newPage();page.setDefaultTimeout(10000);
   const row={width,action,errors:[],consoleErrors:[]};results.cases.push(row);
   page.on('pageerror',e=>row.errors.push(String(e)));page.on('console',m=>{if(m.type()==='error')row.consoleErrors.push(m.text());});
   await page.route('**/*',async route=>{const u=new URL(route.request().url());if(u.hostname==='127.0.0.1')return route.continue();if(u.hostname==='fonts.gstatic.com')return route.fulfill({contentType:'font/ttf',body:await readFile('/opt/handrail/.handrail/flutter-sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf')});return route.abort();});
   const state=()=>page.locator('#accepted-state').textContent().then(JSON.parse);
   const snap=async label=>{await page.screenshot({path:join(out,`${phase}-${width}-${action}-${label}.png`)});return await state();};
   const click=async key=>{const box=(await state()).geometry[key];assert.ok(box,key+' is rendered');const [x,y,w,h]=box;assert.ok(x>=0&&x+w<=width+1,key+' fits width');await page.mouse.click(x+w/2,y+h/2);};
   try {
    await page.goto(`http://127.0.0.1:${server.address().port}/?semantics=off`);
    await page.waitForFunction(()=>{try{return !!JSON.parse(document.querySelector('#accepted-state').textContent).geometry.editor}catch{return false}});
    await click('editor');await page.keyboard.type('Original',{delay:25});
    await page.waitForFunction(()=>JSON.parse(document.querySelector('#accepted-state').textContent).text==='Original');
    await page.keyboard.press('ControlOrMeta+A');await page.waitForTimeout(80);
    await click('link');
    await page.waitForFunction(()=>!!JSON.parse(document.querySelector('#accepted-state').textContent).geometry.destination);
    await page.waitForTimeout(250); // Let the route's opening animation finish.
    row.open=await snap('open');
    assert.deepEqual(row.open.selection,[0,8]);
    if(action==='invalid') {
      await page.keyboard.type('javascript:alert(1)',{delay:10});await page.keyboard.press('Enter');
      await page.waitForFunction(()=>JSON.parse(document.querySelector('#accepted-state').textContent).geometry.invalid===true);
      row.invalid=await snap('invalid');assert.equal(row.invalid.text,'Original');
      await click('cancel');
    } else if(['apply','done','remove'].includes(action)) {
      await page.keyboard.type('https://example.com',{delay:10});
      if(action==='done') await page.keyboard.press('Enter');else await click('apply');
    } else if(action==='cancel') await click('cancel');
    else if(action==='barrier') await page.mouse.click(5,5);
    else if(action==='escape') await page.keyboard.press('Escape');
    await page.waitForFunction(()=>!JSON.parse(document.querySelector('#accepted-state').textContent).geometry.destination);
    await page.waitForTimeout(80);
    row.dismissed=await snap('dismissed');
    if(action==='remove') {
      await click('link');await page.waitForFunction(()=>!!JSON.parse(document.querySelector('#accepted-state').textContent).geometry.remove);
      await page.waitForTimeout(250);row.edit=await snap('edit');await click('remove');
      await page.waitForFunction(()=>!JSON.parse(document.querySelector('#accepted-state').textContent).geometry.destination);
    }
    // Hold only the fixture HTTP acknowledgement to inspect actual queued storage.
    await page.evaluate(()=>window.postMessage('hold-draft','*'));
    // No click/focus/text assignment between dismissal and actual typing.
    await page.keyboard.type('X');await page.waitForTimeout(80);row.first=await snap('first');
    await page.keyboard.type(' next',{delay:25});await page.waitForTimeout(350);row.continued=await snap('continued');
    row.typingPassed=row.first.text.includes('X')&&row.continued.text.includes('X next');
    assert.equal(row.errors.length,0,'page exceptions');assert.equal(row.consoleErrors.length,0,'browser console errors');
    assert.equal(row.typingPassed,true,'continued ordinary typing without harness refocus');
    const expectedDraft=['apply','done'].includes(action)?'[X](https://example.com) next':'X next';
    assert.equal(row.continued.draft,expectedDraft,'projected markdown preserves accepted continued input');
    assert.ok(row.continued.durable.includes('X'),'queued durable draft contains accepted input');
    await page.evaluate(()=>window.postMessage('release-draft','*'));
    await page.waitForFunction(()=>JSON.parse(document.querySelector('#accepted-state').textContent).pending===false);
    row.acknowledged=await state();assert.equal(row.acknowledged.draft,expectedDraft);

    row.passed=true;
   } catch(e) {row.passed=false;row.failure=String(e);row.final=await state().catch(()=>null);await page.screenshot({path:join(out,`${phase}-${width}-${action}-failure.png`)}).catch(()=>{});}
   await context.close();await writeFile(join(out,phase+'-browser.json'),JSON.stringify(results,null,2)+'\n');
   console.log(width,action,row.passed?'PASS':'FAIL',row.failure||'');
  }
 }
} finally {await browser.close();server.close();}
if(results.cases.some(c=>!c.passed)) process.exitCode=1;
