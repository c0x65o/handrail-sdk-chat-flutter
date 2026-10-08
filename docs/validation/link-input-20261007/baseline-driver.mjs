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
const result = {phase, browser:browser.version(), cases:[]};
try {
  for (const semantics of ['on', 'off']) for (const width of [320, 1280]) {
    const context = await browser.newContext({viewport:{width,height:780}});
    const page = await context.newPage(); page.setDefaultTimeout(5000);
    const row = {semantics,width,errors:[],steps:{},checks:{}}; result.cases.push(row);
    page.on('pageerror', e => row.errors.push(String(e)));
    await page.route('**/*', async route => {
      const u = new URL(route.request().url());
      if (u.hostname === '127.0.0.1') return route.continue();
      if (u.hostname === 'fonts.gstatic.com') return route.fulfill({contentType:'font/ttf',body:await readFile('/opt/handrail/.handrail/flutter-sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf')});
      return route.abort();
    });
    await page.addInitScript(() => {
      window.events = []; const identities = new WeakMap(); let serial = 0;
      window.describe = n => {
        if (!n) return null;
        if (!identities.has(n)) identities.set(n, ++serial);
        return {id:identities.get(n),tag:n.tagName,role:n.getAttribute?.('role'),label:n.getAttribute?.('aria-label'),
          value:n.value,selection:[n.selectionStart,n.selectionEnd],active:n===document.activeElement};
      };
      for (const type of ['focusin','focusout','keydown','keyup','beforeinput','input','compositionstart','compositionupdate','compositionend']) {
        document.addEventListener(type, e => window.events.push({type,key:e.key,code:e.code,data:e.data,inputType:e.inputType,
          composing:e.isComposing,ctrl:e.ctrlKey,target:window.describe(e.target),time:performance.now()}),true);
      }
    });
    const state = () => page.locator('#accepted-state').textContent().then(JSON.parse);
    const snap = async name => {
      await page.waitForTimeout(100);
      const s = {...await state(),dom:await page.evaluate(() => ({active:window.describe(document.activeElement),
        editables:[...document.querySelectorAll('input,textarea')].map(window.describe)}))};
      row.steps[name] = s; return s;
    };
    const click = async key => {
      const [x,y,w,h] = (await state()).geometry[key];
      await page.mouse.click(x+w/2,y+h/2);
    };
    const settle = () => page.waitForTimeout(350);
    const screenshot = name => page.screenshot({path:join(out,`${phase}-${semantics}-${width}-${name}.png`)});
    const destination = s => s.geometry.editables.at(-1);
    const linkFocused = s => s.geometry.focusedAncestors.includes('button:Link');
    try {
      await page.goto(`http://127.0.0.1:${server.address().port}/?semantics=${semantics}`);
      await page.waitForFunction(() => {try {return !!JSON.parse(document.querySelector('#accepted-state').textContent).geometry.editor;}catch{return false;}});
      await click('editor'); await page.keyboard.type('Original',{delay:30}); await settle();
      assert.equal((await snap('typed')).text,'Original');
      await page.keyboard.press('Control+a'); await snap('selected');
      await click('link'); await settle(); await snap('opened');
      // Ordinary pointer focus before real sequential keyboard entry.
      await click('destination'); await page.keyboard.type('javascript:bad',{delay:30});
      await snap('invalidTyped'); await click('apply'); await settle();
      row.checks.invalidRejected = !!(await snap('invalid')).geometry.invalid;
      row.checks.errorWraps = (await state()).geometry.errorClipped === false;
      await screenshot('invalid');
      await click('destination'); await page.keyboard.press('Control+a'); await snap('destinationSelected');
      await page.keyboard.type('https://example.test/safe',{delay:30}); await snap('corrected');
      await click('apply'); await settle(); const applied = await snap('applied');
      row.checks.validApply = applied.draft === '[Original](https://example.test/safe)' && !applied.geometry.destination;
      await screenshot('applied');
      if (!applied.geometry.destination) {
        await page.keyboard.press('ArrowRight'); await page.keyboard.type(' next',{delay:30}); await settle();
        const continued = await snap('continued');
        row.checks.continuedTyping = continued.text === 'Original next';
        await screenshot('continued');
      } else {
        // Preserve failed Apply, dismiss via the user's Cancel button only.
        await click('cancel'); await settle(); await snap('failedApplyCancelled');
      }
      // Fresh dialogs isolate Escape and traversal from any invalid value.
      await click('editor'); await page.keyboard.press('Control+a'); await click('link'); await settle();
      await snap('escapeOpened'); await page.keyboard.press('Escape'); await settle();
      row.checks.escapeDismissed = !(await snap('escape')).geometry.destination;
      if (!row.checks.escapeDismissed) {await click('cancel'); await settle();}
      row.traversal = [];
      for (let i=0;i<16;i++) {
        await page.keyboard.press('Tab'); await page.waitForTimeout(100);
        const s = await state();
        row.traversal.push({focus:s.focus,primary:s.primary,ancestors:s.geometry.focusedAncestors,dom:await page.evaluate(() => window.describe(document.activeElement))});
        if (linkFocused(s)) break;
      }
      row.checks.tabReachesLink = linkFocused(await state());
      await snap('traversed');
      if (row.checks.tabReachesLink) {
        await page.keyboard.press('Enter'); await settle();
        row.checks.keyboardReopens = !!(await snap('keyboardOpened')).geometry.destination;
        await page.keyboard.press('Escape'); await settle();
        row.checks.keyboardEscape = !(await snap('keyboardEscape')).geometry.destination;
        if ((await state()).geometry.destination) {await click('cancel'); await settle();}
      }
      const beforeDismissals = await state();
      for (const action of ['cancel','barrier','cancel','barrier']) {
        await click('link'); await settle();
        if (action === 'barrier') await page.mouse.click(5,5); else await click('cancel');
        await settle(); const s = await snap('repeat'+Object.keys(row.steps).length);
        assert.equal(s.text,beforeDismissals.text); assert.equal(s.draft,beforeDismissals.draft);
        assert.ok(!s.geometry.destination);
      }
      row.checks.repeatedDismissalPreservesDraft = true;
      await screenshot('dismissed');
    } catch (e) { row.failure = String(e); await snap('failure').catch(()=>{}); await screenshot('failure').catch(()=>{}); }
    row.events = await page.evaluate(() => window.events).catch(()=>[]);
    row.passed = !row.failure && !row.errors.length && Object.values(row.checks).every(Boolean);
    console.log(semantics,width,JSON.stringify(row.checks),row.failure||'');
    await context.close();
    await writeFile(join(out,phase+'-browser.json'),JSON.stringify(result,null,2)+'\n');
  }
} finally {await browser.close(); server.close();}
if (result.cases.some(c => !c.passed)) process.exitCode = 1;
