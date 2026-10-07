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

try {
 const context=await browser.newContext({viewport:{width:1050,height:780}});
 const page=await context.newPage();
 await page.route('**/*',async route=>{const u=new URL(route.request().url());if(u.hostname==='127.0.0.1')return route.continue();if(u.hostname==='fonts.gstatic.com')return route.fulfill({contentType:'font/ttf',body:await readFile('/opt/handrail/.handrail/flutter-sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf')});return route.abort();});
 await page.goto(`http://127.0.0.1:${server.address().port}/`);
 await page.locator('textarea').last().click();
 await page.keyboard.type('Original');await page.keyboard.press('ControlOrMeta+A');
 await page.waitForTimeout(200);
 const cdp=await context.newCDPSession(page);
 const snapshot=async()=>({dom:await page.getByRole('button',{name:'Bold',exact:true}).evaluateAll(ns=>ns.map(n=>n.outerHTML)),ax:(await cdp.send('Accessibility.getFullAXTree')).nodes.filter(n=>n.role?.value==='button' && n.name?.value==='Bold')});
 const before=await snapshot();
 await page.getByRole('button',{name:'Bold',exact:true}).last().click();await page.waitForTimeout(200);
 const after=await snapshot();
 await writeFile(join(outDir,phase+'-ax.json'),JSON.stringify({before,after},null,2)+'\n');
 console.log(JSON.stringify({before,after}));
 assert.equal(before.dom.length,1,'one accessible Bold button');
 assert.equal(after.ax.length,1,'one native accessible Bold button');
 assert.ok(before.dom[0].includes('aria-current="false"'));
 assert.ok(after.dom[0].includes('aria-current="true"'));
 await context.close();
} finally {await browser.close();server.close();}
