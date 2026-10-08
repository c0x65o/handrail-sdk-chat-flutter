// No editing/focus injection. Geometry and protocol/controller data are read only.
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import {readFile, writeFile} from 'node:fs/promises';
import {extname, join} from 'node:path';
import assert from 'node:assert/strict';
const {chromium} = createRequire(process.env.BROWSER_TOOLS_DIR+'/package.json')('playwright');
const [build, out, phase] = process.argv.slice(2);
const server = createServer(async (req, res) => {
  try {
    const path = join(build, req.url.split('?')[0] === '/' ? 'index.html' : req.url.split('?')[0]);
    res.setHeader('Content-Type', ({'.html':'text/html','.js':'application/javascript','.wasm':'application/wasm','.json':'application/json','.ttf':'font/ttf'})[extname(path)] || 'application/octet-stream');
    res.end(await readFile(path));
  } catch { res.writeHead(404); res.end(); }
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const browser = await chromium.launch({headless:true,
  env:{...process.env, TMPDIR:process.env.BROWSER_TMPDIR},
  executablePath:'/opt/handrail/.handrail/flutter-sdk/bin/cache/mock-authority-playwright/chromium-1234/chrome-linux64/chrome',
  args:['--no-sandbox','--disable-dev-shm-usage']});
const result = {phase,browser:browser.version(),control:'plain Flutter TextField; no SDK composer/dialog',cases:[]};
try {
 for (const width of [320,1280]) {
  const context = await browser.newContext({viewport:{width,height:780}});
  const page = await context.newPage(); page.setDefaultTimeout(5000);
  await page.route('**/*',async route=>{
   const u=new URL(route.request().url());
   if(u.hostname==='127.0.0.1') return route.continue();
   if(u.hostname==='fonts.gstatic.com') return route.fulfill({contentType:'font/ttf',body:await readFile('/opt/handrail/.handrail/flutter-sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf')});
   return route.abort();
  });
  await page.goto(`http://127.0.0.1:${server.address().port}/?semantics=on&control=sync`);
  await page.waitForFunction(()=>{try{return !!JSON.parse(document.querySelector('#accepted-state').textContent).geometry.editor;}catch{return false;}});
  const state=()=>page.locator('#accepted-state').textContent().then(JSON.parse);
  const click=async()=>{const [x,y,w,h]=(await state()).geometry.editor;await page.mouse.click(x+w/2,y+h/2);};
  const ready=()=>page.waitForFunction(()=>{
   const s=JSON.parse(document.querySelector('#accepted-state').textContent),a=document.activeElement;
   return s.focus && a.value===s.text && a.selectionStart===s.selection[0] && a.selectionEnd===s.selection[1];
  });
  for (const connected of [false,true]) for(let attempt=0;attempt<6;attempt++) {
   await click();await ready();await page.keyboard.press('Control+a');await page.waitForTimeout(100);
   await page.keyboard.type('javascript:bad',{delay:30});await page.waitForTimeout(100);
   await page.getByRole('textbox',{name:'Outside editor'}).click();await page.waitForTimeout(100);
   const row={width,connected,attempt};
   await click();if(connected) await ready();
   await page.keyboard.press('ControlOrMeta+A');await page.waitForTimeout(100);
   let s=await state();row.selected={text:s.text,selection:s.selection,focus:s.focus,input:s.inputMessages.slice(-18)};
   await page.keyboard.type('https://example.test/safe',{delay:10});await page.waitForTimeout(150);
   s=await state();row.after={text:s.text,selection:s.selection,focus:s.focus,input:s.inputMessages.slice(-6)};
   row.replaced=s.text==='https://example.test/safe';result.cases.push(row);
   if(!row.replaced) await page.screenshot({path:join(out,`${phase}-${width}-${connected}-${attempt}.png`)});
   console.log(width,connected,attempt,row.replaced,s.text);
  }
  await context.close();
 }
} finally {await browser.close();server.close();}
await writeFile(join(out,phase+'-browser.json'),JSON.stringify(result,null,2)+'\n');
if(result.cases.some(c=>!c.replaced))process.exitCode=1;
