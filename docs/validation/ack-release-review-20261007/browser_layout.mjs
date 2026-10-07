// Read-only FocusManager/render telemetry; input uses real browser keyboard/pointer.
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
const results={phase,browser:browser.version(),semantics:false,focus:[],layout:[]};
try {
 for(const width of [320,390,900]) for(const scale of [1,2,3]) {
   const context=await browser.newContext({viewport:{width,height:1800}});const page=await context.newPage();page.setDefaultTimeout(10000);const row={width,scale,errors:[]};results.layout.push(row);
   page.on('pageerror',e=>row.errors.push(String(e)));
   await page.route('**/*',async route=>{const u=new URL(route.request().url());if(u.hostname==='127.0.0.1')return route.continue();if(u.hostname==='fonts.gstatic.com')return route.fulfill({contentType:'font/ttf',body:await readFile('/opt/handrail/.handrail/flutter-sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf')});return route.abort();});
   const state=()=>page.locator('#accepted-state').textContent().then(JSON.parse);
   const click=async key=>{const [x,y,w,h]=(await state()).geometry[key];await page.mouse.click(x+w/2,y+h/2);};
   try {
    await page.goto(`http://127.0.0.1:${server.address().port}/?semantics=off&scale=${scale}`);
    await page.waitForFunction(()=>{try{return !!JSON.parse(document.querySelector('#accepted-state').textContent).geometry.editor}catch{return false}});
    await click('editor');await page.keyboard.type('Original');await page.keyboard.press('ControlOrMeta+A');await page.waitForTimeout(80);await click('link');
    await page.waitForFunction(()=>!!JSON.parse(document.querySelector('#accepted-state').textContent).geometry.destination);await page.waitForTimeout(250);
    await page.keyboard.type('javascript:bad');await page.keyboard.press('Enter');await page.waitForTimeout(250);
    row.state=await state();row.passed=row.state.geometry.errorClipped===false&&row.errors.length===0;
    await page.screenshot({path:join(out,`${phase}-validation-${width}-${scale}.png`)});
   }catch(e){row.passed=false;row.failure=String(e);row.final=await state().catch(()=>null);await page.screenshot({path:join(out,`${phase}-validation-${width}-${scale}-failed.png`)}).catch(()=>{});}
   await context.close();console.log('layout',width,scale,row.passed?'PASS':'FAIL');
   await writeFile(join(out,phase+'-browser.json'),JSON.stringify(results,null,2)+'\n');
 }
}finally{await browser.close();server.close();}
if([...results.focus,...results.layout].some(c=>!c.passed))process.exitCode=1;
