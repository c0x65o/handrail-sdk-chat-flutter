import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import {readFile,writeFile} from 'node:fs/promises';
import {extname,join} from 'node:path';
import assert from 'node:assert/strict';
const require = createRequire(process.env.TASK_TMP+'/browser-tools/package.json');
const {chromium} = require('playwright');
const [buildDir,outDir,phase] = process.argv.slice(2);
const server=createServer(async(req,res)=>{
 try { const path=join(buildDir,decodeURIComponent(req.url.split('?')[0]==='/'?'/index.html':req.url.split('?')[0]));
 res.setHeader('Content-Type',({'.html':'text/html','.js':'application/javascript','.wasm':'application/wasm','.json':'application/json','.ttf':'font/ttf'})[extname(path)]||'application/octet-stream');
 res.end(await readFile(path)); } catch {res.writeHead(404);res.end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,executablePath:'/opt/handrail/.handrail/flutter-sdk/bin/cache/mock-authority-playwright/chromium-1234/chrome-linux64/chrome',args:['--no-sandbox','--disable-dev-shm-usage']});
const page=await browser.newPage({viewport:{width:1050,height:700}});
const errors=[];page.on('pageerror',e=>errors.push(e.stack||String(e)));
await page.route('**/*',async route=>{const u=new URL(route.request().url()); if(u.hostname==='127.0.0.1')return route.continue(); if(u.hostname==='fonts.gstatic.com')return route.fulfill({contentType:'font/ttf',body:await readFile('/opt/handrail/.handrail/flutter-sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf')}); return route.abort();});
const state=()=>page.locator('#accepted-state').textContent().then(JSON.parse);
const snap=async name=>{await page.screenshot({path:join(outDir,`${phase}-${name}.png`)});return {state:await state(),fields:await page.locator('input,textarea').evaluateAll(nodes=>nodes.map(n=>({label:n.getAttribute('aria-label'),role:n.getAttribute('role'),value:n.value,focused:document.activeElement===n,selection:[n.selectionStart,n.selectionEnd]})))};};
const command=async cmd=>{await page.evaluate(c=>window.postMessage(c,'*'),cmd);await page.waitForTimeout(150);};
const results={phase,errors};
try {
 await page.goto(`http://127.0.0.1:${server.address().port}`);
 await page.waitForFunction(()=>document.querySelector('#accepted-state')?.textContent.includes('requests'));
 await page.waitForTimeout(1200);
 results.initial=await snap('initial');
 const targets=page.locator('input,textarea');
 results.editableCount=await targets.count();
 // Exercise each real semantic textarea independently. Acceptance is measured in Dart.
 results.targets=[];
 for(let i=0;i<await targets.count();i++){
   const t=targets.nth(i);await t.focus();await page.waitForTimeout(150);await page.keyboard.press('ControlOrMeta+A');await page.keyboard.type('Draft editing');await page.waitForTimeout(400);
   results.targets.push(await snap(`target-${i}`));
 }
 // Re-focus the usable inner editor on the baseline; patched composer has one target.
 const usable=targets.last();await usable.focus();await page.waitForTimeout(150);await page.keyboard.press('ControlOrMeta+A');await page.keyboard.type('Draft editing');await page.waitForTimeout(450);
 // Native keyboard range selection, then delayed acknowledgement, without a focus change.
 await page.keyboard.press('Home');await page.waitForTimeout(100);for(let i=0;i<4;i++){await page.keyboard.press('ArrowRight');await page.waitForTimeout(80);}
 await page.keyboard.down('Shift');await page.keyboard.press('ArrowRight');await page.waitForTimeout(80);await page.keyboard.press('ArrowRight');await page.waitForTimeout(80);await page.keyboard.up('Shift');
 await page.waitForTimeout(200);results.beforeAck=await snap('before-ack');
 await command('release-draft');await page.waitForFunction(()=>JSON.parse(document.querySelector('#accepted-state').textContent).pending===false);
 results.afterAck=await snap('after-ack');
 if(phase.startsWith('after')){
   assert.equal(results.editableCount,1);assert.equal(results.targets[0].state.text,'Draft editing');
   assert.deepEqual(results.beforeAck.state.selection,[4,6]);assert.deepEqual(results.afterAck.state.selection,[4,6]);
   assert.equal(results.afterAck.state.focus,true);assert.equal(results.afterAck.state.draft,'Draft editing');
   // Send, hold post-send draft clear, type a new composition through the same semantic target.
   await command('hold-draft');await page.getByRole('button',{name:'Send message',exact:true}).click();
   await page.waitForFunction(()=>JSON.parse(document.querySelector('#accepted-state').textContent).text==='');
   await page.waitForTimeout(250);if(phase.includes('refocus'))await page.keyboard.press('Tab');await usable.click();await page.keyboard.type('Newer accepted edit',{delay:35});await page.waitForTimeout(400);
   results.beforeClearAck=await snap('before-clear-ack');await command('release-draft');
   await page.waitForFunction(()=>{const s=JSON.parse(document.querySelector('#accepted-state').textContent);return s.pending===false&&s.draft==='Newer accepted edit'});
   results.afterClearAck=await snap('after-clear-ack');
   assert.equal(results.afterClearAck.state.text,'Newer accepted edit');
   assert.equal(results.afterClearAck.state.requests.filter(x=>x.operation==='send').length,1);
   // Check rich-text serialization and native selection through the public toolbar.
   await page.reload();await page.waitForTimeout(1200);
   const editor=page.locator('textarea');await editor.focus();await page.waitForTimeout(200);
   await page.keyboard.type('Draft editing',{delay:50});await page.waitForTimeout(400);
   assert.equal((await state()).text,'Draft editing');
   await page.keyboard.press('Home');await page.waitForTimeout(100);
   await page.keyboard.down('Shift');
   for(let i=0;i<5;i++){await page.keyboard.press('ArrowRight');await page.waitForTimeout(70);}
   await page.keyboard.up('Shift');
   await page.getByRole('button',{name:'Bold',exact:true}).last().click();await page.waitForTimeout(300);
   await page.keyboard.press('Tab');await editor.click();await page.waitForTimeout(150);
   await page.keyboard.press('Home');await page.waitForTimeout(100);
   for(let i=0;i<4;i++){await page.keyboard.press('ArrowRight');await page.waitForTimeout(70);}
   await page.keyboard.down('Shift');
   for(let i=0;i<2;i++){await page.keyboard.press('ArrowRight');await page.waitForTimeout(70);}
   await page.keyboard.up('Shift');await page.waitForTimeout(200);
   results.richNativeRange=await snap('rich-native-range');
   await command('set-public-composing');
   results.richBefore=await snap('rich-before');
   assert.deepEqual(results.richBefore.state.composing,[3,8]);
   await command('release-draft');
   await page.waitForFunction(()=>JSON.parse(document.querySelector('#accepted-state').textContent).pending===false);
   results.richAfter=await snap('rich-after');
   assert.equal(results.richAfter.state.draft,'**Draft** editing');
   assert.deepEqual(results.richBefore.state.selection,[4,6]);
   assert.deepEqual(results.richAfter.state.selection,[4,6]);
   assert.deepEqual(results.richAfter.state.composing,[3,8]);
   assert.equal(errors.length,0);
 }
} catch(error) {results.failure=error.stack;throw error;} finally {
 results.final=await snap('final');
 await writeFile(join(outDir,`${phase}-browser.json`),JSON.stringify(results,null,2)+'\n');
 await browser.close();server.close();
}
