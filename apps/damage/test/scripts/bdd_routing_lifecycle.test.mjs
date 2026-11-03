import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const {chromium} = createRequire(import.meta.url)('playwright');
const base = new URL('../../', import.meta.url);
const template = await readFile(new URL('priv/templates/ui/dashboard/execution_tab.mustache',base),'utf8');
const sources = Object.fromEntries(await Promise.all(['bdd-composer.js','bdd-composer-model.js','bdd-routing.js'].map(async name =>
  [name,await readFile(new URL(`priv/static/js/${name}`,base),'utf8')])));
const {routingError} = await import(new URL('priv/static/js/bdd-routing.js',base));
const routing = `<section data-bdd-routing><p data-route="summary">Not loaded</p>
  <form data-route="form"><fieldset data-route="fields">
    <select name="provider"><option value="any">Automatic</option><option value="local">Local</option></select>
    <input name="model"><button type="submit">Save route</button></fieldset></form>
  <p data-route="candidates"></p><p data-route="status" role="status"></p>
  <button type="button" data-route="refresh">Refresh route</button></section>`;
const content = template.replace(/(<section id="bdd-composer"[^>]*>)/,'$1'+routing);

test('routing errors keep authorization, service availability and timeout distinct',()=>{
  assert.match(routingError({status:401}), /session has expired/);
  assert.match(routingError({status:403}), /not authorised/);
  assert.match(routingError({status:503}), /routing service, configuration and storage/);
  assert.match(routingError({name:'AbortError'}), /Select Refresh/);
});

test('composer defers hidden reads, rejects stale auth results and retries routing explicitly',async()=>{
  const gets={catalog:0,routing:0}, posts=[], calls=[];
  let status=200, hold=false, releases=[];
  const server=createServer(async(req,res)=>{
    const name=req.url.slice(1);
    if(Object.hasOwn(sources,name)) {res.setHeader('content-type','text/javascript');res.end(sources[name]);return;}
    if(req.url.startsWith('/ai/bdd/')) {
      const action=req.url.split('/').at(-1);
      calls.push({action,method:req.method,auth:req.headers.authorization});
      res.setHeader('content-type','application/json');
      if(req.method!=='GET') {posts.push(action);res.end('{}');return;}
      gets[action]++;
      const number=gets[action], responseStatus=action==='routing'?status:200;
      const body=action==='catalog'
        ? {steps:[{template:`signature-${number}`,keywords:['Given'],module:'steps_test',source_line:1}],module_count:1,engine:{generator_available:true}}
        : responseStatus===200
          ? {revision:number,route:{provider:'any',model:`model-${number}`},connections:[],can_manage:true}
          : {error:'service_not_ready'};
      if(hold) await new Promise(resolve=>releases.push(resolve));
      res.statusCode=responseStatus;res.end(JSON.stringify(body));return;
    }
    const standalone=req.url==='/standalone';
    res.setHeader('content-type','text/html');
    res.end(`<!doctype html><html><body><button id="open">Open execution</button>
      ${standalone?content:`<div id="execution-tab" data-dashboard-view hidden>${content}</div>`}
      <script>window.currentToken='first-session';window.TokenManager={getToken:()=>window.currentToken};
        document.getElementById('open').onclick=()=>{
          const p=document.getElementById('execution-tab');if(p)p.hidden=false;
          document.dispatchEvent(new CustomEvent('damage:panelchange',{detail:{id:'execution-tab'}}));
        };
      </script><script type="module" src="/bdd-composer.js"></script></body></html>`);
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  let browser;
  try {
    browser=await chromium.launch({headless:true,executablePath:process.env.BUNKER_TEST_CHROMIUM || undefined,args:['--no-sandbox','--disable-dev-shm-usage']});
    const page=await browser.newPage(), errors=[];
    page.on('pageerror',e=>errors.push(e.message));
    const origin=`http://127.0.0.1:${server.address().port}`;
    await page.goto(origin);
    await page.waitForFunction(()=>document.getElementById('bdd-catalog-status').textContent.includes('Open this workspace'));
    assert.deepEqual(gets,{catalog:0,routing:0});
    assert.equal(await page.locator('[data-route="fields"] select').isDisabled(),true);
    hold=true;
    const started=page.waitForRequest(r=>r.url().endsWith('/ai/bdd/routing'));
    await page.locator('#open').click();await started;
    await page.evaluate(()=>{for(let i=0;i<4;i++)document.dispatchEvent(new CustomEvent('damage:panelchange',{detail:{id:'execution-tab'}}));});
    assert.deepEqual(gets,{catalog:1,routing:1},'Only one catalog/routing read per initial activation');
    hold=false;releases.splice(0).forEach(resolve=>resolve());
    await page.waitForFunction(()=>document.querySelector('[data-route="summary"]').textContent.includes('model-1'));
    await page.waitForFunction(()=>document.getElementById('bdd-step-results').textContent.includes('signature-1'));

    await page.evaluate(()=>{
      document.getElementById('execution-tab').hidden=true;window.currentToken='second-session';
      document.dispatchEvent(new Event('auth:changed'));
      document.dispatchEvent(new CustomEvent('damage:bdd-routing-changed'));
    });
    assert.deepEqual(gets,{catalog:1,routing:1},'Auth/routing changes in a hidden pane defer reads');
    assert.equal(await page.locator('#bdd-step-results').textContent(),'');
    assert.equal(await page.locator('[data-route="summary"]').textContent(),'Not loaded');
    status=503;await page.locator('#open').click();
    await page.waitForFunction(()=>document.querySelector('[data-route="status"]').textContent.includes('BDD routing is unavailable'));
    assert.equal(await page.locator('[data-route="fields"] select').isDisabled(),true);
    assert.equal(await page.locator('[data-route="refresh"]').isEnabled(),true);
    await page.evaluate(()=>{
      document.querySelector('[data-route="form"]').dispatchEvent(new Event('submit',{cancelable:true,bubbles:true}));
      document.getElementById('execution-tab').hidden=true;
      document.getElementById('execution-tab').hidden=false;
      document.dispatchEvent(new CustomEvent('damage:panelchange',{detail:{id:'execution-tab'}}));
    });
    assert.equal(posts.length,0,'Unavailable routing cannot submit a default or stale preference');
    assert.deepEqual(gets,{catalog:2,routing:2},'Revisiting a failed panel must not create an automatic retry loop');
    status=200;await page.locator('[data-route="refresh"]').click();
    await page.waitForFunction(()=>document.querySelector('[data-route="summary"]').textContent.includes('model-3'));
    assert.equal(await page.locator('[data-route="fields"] select').isEnabled(),true);

    // A response started under the old identity must not repopulate hidden UI
    // after auth changes, even when the server later completes that response.
    hold=true;
    const oldRead=page.waitForRequest(r=>r.url().endsWith('/ai/bdd/catalog'));
    await page.locator('#bdd-refresh-catalog').click();await oldRead;
    await page.evaluate(()=>{
      document.getElementById('execution-tab').hidden=true;window.currentToken='third-session';
      document.dispatchEvent(new Event('auth:changed'));
    });
    hold=false;releases.splice(0).forEach(resolve=>resolve());
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
    assert.equal(await page.locator('#bdd-step-results').textContent(),'');
    assert.deepEqual(gets,{catalog:3,routing:3});
    await page.locator('#open').click();
    await page.waitForFunction(()=>document.getElementById('bdd-step-results').textContent.includes('signature-4'));
    await page.waitForFunction(()=>document.querySelector('[data-route="summary"]').textContent.includes('model-4'));
    assert.equal(calls.filter(c=>c.action==='catalog').at(-1).auth,'Bearer third-session');
    for(const code of [401,403]) {
      status=code;await page.locator('[data-route="refresh"]').click();
      await page.waitForFunction(code=>document.querySelector('[data-route="status"]').textContent.includes(code===401?'session has expired':'not authorised'),code);
      assert.equal(await page.locator('[data-route="fields"] select').isDisabled(),true);
    }
    status=200;
    const before={...gets};
    await page.goto(origin+'/standalone');
    await page.waitForFunction(()=>document.querySelector('[data-route="summary"]').textContent.includes('Automatic BDD pool'));
    await page.waitForFunction(()=>document.getElementById('bdd-catalog-status').textContent.includes('1 signatures'));
    assert.deepEqual(gets,{catalog:before.catalog+1,routing:before.routing+1},'Visible standalone composer still loads normally');
    assert.deepEqual(errors,[]);assert.equal(posts.length,0);
  } finally {
    releases.splice(0).forEach(resolve=>resolve());
    if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));
  }
});
