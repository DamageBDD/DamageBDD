import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
const {chromium} = createRequire(import.meta.url)('playwright');
const base = new URL('../../', import.meta.url);
const template = await readFile(new URL('priv/templates/ui/dashboard/billing_tab.mustache', base), 'utf8');
const script = await readFile(new URL('priv/static/js/billing.js', base), 'utf8');
const session = {role:'invoice_admin',can_manage_admins:false,can_manage_settings:false,clock:'utc',send_hour:9,auto_send_enabled:false};

async function fixture(run) {
  const calls=[], pending=[];
  let responseStatus=503, holdToken=null;
  const server=createServer(async (req,res)=>{
    if(req.url.startsWith('/api/billing/')) {
      calls.push({path:req.url,method:req.method,authorization:req.headers.authorization,cookie:req.headers.cookie});
      const reply=()=>{
        res.setHeader('content-type','application/json');
        if(req.url==='/api/billing/session') {
          res.statusCode=responseStatus;
          res.end(JSON.stringify(responseStatus===200 ? {status:'ok',data:session} : {status:'error',message:'Billing disabled, locked, or storage unavailable'}));
          return;
        }
        const data=req.url==='/api/billing/summary' ? {paid_count:7} : req.url==='/api/billing/settings' ? {} : {items:[],total:0};
        res.end(JSON.stringify({status:'ok',data}));
      };
      if(req.url==='/api/billing/session' && req.headers.authorization===`Bearer ${holdToken}`) pending.push(reply);
      else reply();
      return;
    }
    if(req.url==='/billing.js') {res.setHeader('content-type','text/javascript');res.end(script);return;}
    const query=new URL(req.url,'http://localhost').searchParams;
    let html=template.replace(/\{\{#enterprise_billing_enabled\}\}true\{\{\/enterprise_billing_enabled\}\}\{\{\^enterprise_billing_enabled\}\}false\{\{\/enterprise_billing_enabled\}\}/g,query.get('enabled')||'true');
    if(query.has('legacy')) html=html.replace(/ data-billing-enabled="[^"]*"/,'');
    res.setHeader('content-type','text/html');
    res.end(`<!doctype html><html><body><section id="billing-nav-group" hidden><div id="billing-nav" hidden>Billing</div></section><div id="billing-tab">${html}</div><script>window.testToken=${JSON.stringify(query.get('token')??'account-A')}; window.testMode=${JSON.stringify(query.get('mode')||'custodial')}; window.TokenManager={getToken:()=>window.testToken,getMode:()=>window.testMode};</script><script type="module" src="/billing.js"></script></body></html>`);
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  let browser;
  try {
    browser=await chromium.launch({headless:true,executablePath:process.env.BUNKER_TEST_CHROMIUM||undefined,args:['--no-sandbox','--disable-dev-shm-usage']});
    const page=await browser.newPage();
    const errors=[];page.on('pageerror',error=>errors.push(error.message));
    await run({page,calls,pending,errors,url:`http://127.0.0.1:${server.address().port}/`,setStatus:v=>responseStatus=v,hold:v=>holdToken=v});
    assert.deepEqual(errors,[]);
  } finally {
    pending.splice(0).forEach(reply=>reply());
    if(browser)await browser.close();
    await new Promise(resolve=>server.close(resolve));
  }
}

test('explicitly disabled billing skips session probes; guest and wallet mode stay private',async()=>{
  await fixture(async({page,calls,url})=>{
    await page.goto(url+'?enabled=false');
    await page.getByText(/Enterprise billing is disabled/).waitFor();
    assert.equal(calls.length,0);
    assert.equal(await page.locator('#enterprise-billing').isHidden(),true);
    assert.equal(await page.locator('#billing-access-retry').isHidden(),true);
    await page.evaluate(()=>document.dispatchEvent(new Event('auth:changed')));
    assert.equal(calls.length,0);
    for(const query of ['?token=','?mode=extension']) {
      await page.goto(url+query);
      assert.equal(await page.locator('#enterprise-billing').isHidden(),true);
      assert.equal(await page.locator('#billing-nav-group').isHidden(),true);
      assert.equal(calls.length,0);
    }
  });
});

test('503 remains unavailable with explicit retry; missing capability hint still authorizes through API',async()=>{
  await fixture(async({page,calls,url,setStatus})=>{
    await page.goto(url+'?legacy=1');
    await page.getByText(/Billing service unavailable \(503\)/).waitFor();
    assert.equal(calls.length,1);
    assert.equal(await page.locator('#enterprise-billing').isHidden(),true);
    assert.equal(await page.locator('#billing-nav-group').isVisible(),true);
    assert.equal(await page.locator('#billing-access-retry').isEnabled(),true);
    assert.doesNotMatch(await page.locator('#billing-access-message').textContent(),/authentication failed/i);
    setStatus(200);
    await page.getByRole('button',{name:'Retry billing connection'}).click();
    await page.waitForFunction(()=>document.querySelector('#billing-stat-paid').textContent==='7');
    assert.equal(await page.locator('#enterprise-billing').isVisible(),true);
    assert.equal(await page.locator('#billing-access').isHidden(),true);
    assert.equal(await page.locator('#billing-admins-nav').isHidden(),true);
    assert.equal(await page.locator('#billing-settings-nav').isHidden(),true);
    assert.equal(calls.filter(c=>c.path==='/api/billing/session').length,2);
    for(const call of calls) {
      assert.equal(call.method,'GET');assert.equal(call.authorization,'Bearer account-A');assert.equal(call.cookie,undefined);
    }
  });
});

test('401 and 403 retain private controls and show access-specific guidance',async()=>{
  await fixture(async({page,url,setStatus})=>{
    for(const [status,text] of [[401,'Your billing session is no longer valid'],[403,'does not have invoice administrator permission']]) {
      setStatus(status);
      await page.goto(url);
      await page.getByText(new RegExp(text)).waitFor();
      assert.equal(await page.locator('#enterprise-billing').isHidden(),true);
      assert.equal(await page.locator('#billing-access-retry').isEnabled(),true);
    }
  });
});

test('account changes clear private state and stale session responses cannot replace the new state',async()=>{
  await fixture(async({page,calls,pending,url,setStatus,hold})=>{
    hold('account-A');
    await page.goto(url);
    await page.getByText('Checking billing access…').waitFor();
    setStatus(200);
    await page.evaluate(()=>{window.testToken='account-B';document.dispatchEvent(new Event('auth:changed'));});
    await page.waitForFunction(()=>document.querySelector('#billing-stat-paid').textContent==='7');
    assert.equal(await page.locator('#enterprise-billing').isVisible(),true);
    // Deliver an old account's denied response after the new session succeeds.
    setStatus(401);
    const oldResponse=page.waitForResponse(r=>r.url().endsWith('/api/billing/session')&&r.status()===401);
    assert.equal(pending.length,1);pending.shift()();
    await oldResponse;
    await page.waitForFunction(()=>document.querySelector('#billing-stat-paid').textContent==='7');
    assert.equal(await page.locator('#enterprise-billing').isVisible(),true);
    assert.equal(await page.locator('#billing-access').isHidden(),true);
    setStatus(503);
    await page.evaluate(()=>{window.testToken='account-C';document.dispatchEvent(new Event('auth:changed'));});
    await page.getByText(/Billing service unavailable \(503\)/).waitFor();
    assert.equal(await page.locator('#enterprise-billing').isHidden(),true);
    assert.equal(await page.locator('#billing-stat-paid').textContent(),'—');
    assert.equal(await page.locator('#billing-invoice-rows').textContent(),'');
    assert.equal(calls.some(c=>c.authorization==='Bearer account-C'&&c.path!=='/api/billing/session'),false);
  });
});
