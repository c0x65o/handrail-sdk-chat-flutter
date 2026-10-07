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
 await page.goto(`http://127.0.0.1:${server.address().port}/?control=1`);
 await page.waitForTimeout(1500);
 results.initial=await snap('initial');
 const editor=page.locator('textarea');
 await editor.focus();await page.keyboard.type('Native control input',{delay:30});
 await page.waitForTimeout(350);results.beforeSend=await snap('before-send');
 assert.equal(results.beforeSend.state.text,'Native control input');
 await page.getByRole('button',{name:'Send message',exact:true}).click();
 await page.waitForTimeout(350);
 results.cleared=await snap('cleared');
 await editor.focus();await page.keyboard.type('Following native input',{delay:30});
 await page.waitForTimeout(350);results.afterSend=await snap('after-send');
 await page.keyboard.press('Tab');await editor.click();
 await page.keyboard.press('ControlOrMeta+A');await page.keyboard.type('Refocused native input',{delay:30});
 await page.waitForTimeout(350);results.refocused=await snap('refocused');
} finally {
 await writeFile(join(outDir,`${phase}-browser.json`),JSON.stringify(results,null,2)+'\n');
 await browser.close();server.close();
}
