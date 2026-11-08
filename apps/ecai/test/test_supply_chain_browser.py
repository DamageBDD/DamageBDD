#!/usr/bin/env python3
"""Real Recovery Lab markup/module with explicitly MOCKED API responses.
Tests DOM, session isolation, requests and layout, not Cowboy or Erlang execution.
Run: python apps/ecai/test/test_supply_chain_browser.py
"""
import asyncio
import base64
import json
import os
from pathlib import Path
from playwright.async_api import async_playwright

APP = Path(__file__).resolve().parents[1]
MOCK = r"""
window.__signed = false; window.__token = ''; window.__calls = [];
window.confirm = () => true;
window.__blank = () => ({exists:false,revision:0,scenario:null,approved:null,proposal:null,
  cases:[],case_count:0,history:[],benchmark:null,impact:null,terms_version:'ecai-terms/v1'});
window.__spaces={}; window.__data=window.__blank();
window.__request = async (path,options={}) => {
  window.__calls.push({path,method:options.method||'GET',body:options.body,headers:options.headers});
  const key=path.startsWith('/ecai/supply-chain/public')?'public':window.__token;
  if(window.__nextError){const status=window.__nextError;window.__nextError=null;
    if(status===410)window.__spaces[key]=window.__blank();
    const e=Error('test_error');e.status=status;e.body={error:status===410?'guest_session_expired':'guest_rate_limited'};throw e;}
  window.__data=window.__spaces[key]||(window.__spaces[key]=window.__blank());
  if(window.__delay && !options.method) await new Promise(resolve => window.__release=resolve);
  const body=options.body||{},d=window.__data,f=window.__fixture;
  if(options.method && body.expected_revision!==d.revision) {const e=Error('revision_conflict');e.status=409;e.body={error:'revision_conflict'};throw e;}
  if(path.endsWith('/reset')) {
    window.__data={...d,exists:true,revision:d.revision+1,scenario:structuredClone(f.scenario),approved:structuredClone(f.approved),proposal:null,benchmark:null,
      impact:{valid:true,violations:[],affected_orders:[]}};
    window.__data.approved.input_revision=window.__data.revision;
    if(!body.keep_cases){window.__data.cases=[];window.__data.case_count=0;}
  } else if(path.endsWith('/event')) {
    d.revision++; d.benchmark=null;
    const ev=body.event;
    if(ev.kind==='road')d.scenario.edges.find(e=>e.id===ev.id).closed=ev.closed;
    if(ev.kind==='vehicle')d.scenario.vehicles.find(v=>v.id===ev.id).available=ev.available;
    if(ev.kind==='demand')d.scenario.orders.find(o=>o.id===ev.id).quantity=ev.quantity;
    if(ev.kind==='policy')d.scenario.stability_weight=ev.stability_weight;
    d.impact={valid:false,affected_orders:['O7','O8'],violations:[{code:'closed_road'}]};
  } else if(path.endsWith('/plan')) {
    d.proposal=structuredClone(f.recovery);d.proposal.input_revision=d.revision;d.proposal.mode=body.mode;
    d.cases=[{id:'c'.repeat(64),state_hash:'b'.repeat(64),digest:'d'.repeat(64),sequence:1,
      metrics:d.proposal.metrics,curve_address:{status:'disabled'},terms_version:'ecai-terms/v1'}];d.case_count=1;
  } else if(path.endsWith('/approve')) {
    if(d.proposal.input_revision!==d.revision)throw Error('stale_plan');
    d.approved=d.proposal;d.proposal=null;d.revision++;d.impact={valid:true,violations:[],affected_orders:[]};
  } else if(path.endsWith('/benchmark')) {
    d.benchmark={input_revision:d.revision,case_count:d.case_count,comparison:'MOCK single-trial response for browser tests.',
      rows:['cold','warm','lookup','ecai'].map(mode=>({mode,total_us:13000,metrics:f.recovery.metrics,valid:true,source:'retrieved_repaired'}))};
  } else if(path.endsWith('/evidence')) {
    return {ok:true,data:{schema:'ecai-supply-chain/evidence-v1',manifest_json:'{}',authenticated_signature:false}};
  }
  window.__spaces[key]=window.__data;
  return {ok:true,data:structuredClone(window.__data)};
};
"""

async def main():
    fragment=(APP/'priv/templates/ui/dashboard/ecai_supply_chain.mustache').read_text()
    css=(APP/'priv/static/css/ecai-console.css').read_text()+'\n'+(APP/'priv/static/css/ecai-supply-chain.css').read_text()
    source=(APP/'priv/static/js/ecai-supply-chain.js').read_bytes()
    code_url='data:text/javascript;base64,'+base64.b64encode(source).decode()
    fixture=json.loads((APP/'test/fixtures/supply_chain_browser.json').read_text())
    print('browser: start',flush=True)
    async with async_playwright() as api:
        browser=await api.chromium.launch(executable_path=os.environ.get('CHROMIUM','/usr/bin/chromium'),headless=True,args=['--no-sandbox','--disable-dev-shm-usage'])
        context=await browser.new_context(viewport={'width':1440,'height':1100},accept_downloads=True)
        page=await context.new_page();page.set_default_timeout(5000);print('browser: page',flush=True);errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
        await page.goto('about:blank')
        await page.set_content('<style>'+css+'</style><main style="padding:28px;max-width:1540px;margin:auto">'+fragment+'</main>')
        await page.evaluate("document.querySelector('[data-panel=\"supply-chain\"]').hidden=false;document.querySelector('[data-panel=\"supply-chain\"]').classList.add('is-visible')")
        await page.evaluate('(f)=>{window.__fixture=f}',fixture)
        await page.evaluate('()=>{'+MOCK+'}')
        await page.evaluate('''async url=>{const {initSupplyChain}=await import(url);
          window.__sc=initSupplyChain({request:window.__request,currentToken:()=>window.__token,
            managedSession:()=>window.__signed,openLogin:()=>window.__login=true});window.__sc.setVisible(true);}''',code_url)
        print('browser: public workspace',flush=True)
        assert await page.locator('#scAccess').is_visible()
        assert await page.evaluate('window.__calls.length')==0
        assert await page.locator('#scWorkspace').is_visible()
        assert await page.locator('#scReset').is_enabled()
        await page.evaluate('window.__sc.refresh()')
        assert await page.evaluate('window.__calls[0].path')=='/ecai/supply-chain/public'
        assert await page.evaluate('window.__calls[0].headers["X-ECAI-Lab-Request"]')=='1'
        assert not await page.evaluate('Boolean(window.__login)')
        assert await page.locator('#scLoaded').is_hidden()
        assert await page.locator('#scReset').is_enabled()
        print('browser: reset',flush=True)
        await page.locator('#scReset').click()
        await page.wait_for_function('window.__data.revision===1 && !document.querySelector("#scReset").disabled')
        assert await page.locator('#scMap .sc-node').count()==24
        assert await page.locator('#scMap .sc-warehouse').count()==2
        assert await page.locator('#scMap .sc-route-path').count()>20
        assert await page.locator('#scOrders tbody tr').count()==48
        assert await page.locator('#scApprove').is_disabled()
        # Playback changes only the forecast clock, never authoritative state.
        before_calls=await page.evaluate('window.__calls.length')
        await page.locator('#scPlay').click()
        await page.wait_for_function('Number(document.querySelector("#scClock").value)>0')
        await page.evaluate('window.__sc.setVisible(false)')
        paused=await page.locator('#scClock').input_value()
        await page.wait_for_timeout(160)
        assert await page.locator('#scClock').input_value()==paused
        assert await page.evaluate('window.__calls.length')==before_calls
        await page.evaluate('window.__sc.setVisible(true)')
        print('browser: bridge',flush=True)
        await page.locator('#scBridge').click()
        await page.wait_for_function('window.__data.revision===2 && !document.querySelector("#scRecover").disabled')
        assert 'failed checks' in await page.locator('#scImpact').inner_text()
        assert await page.locator('#scClock').is_disabled()
        print('browser: recover',flush=True)
        await page.locator('#scRecover').click()
        await page.wait_for_function('!document.querySelector("#scApprove").disabled')
        assert 'Retrieved + repaired' in await page.locator('#scSource').inner_text()
        assert await page.locator('#scMemoryCount').inner_text()=='1'
        await page.locator('#scMap [aria-label="Inspect shop S10"]').click()
        assert 'O19' in await page.locator('#scSelection').inner_text()
        await page.locator('#scClock').fill('60');await page.locator('#scClock').dispatch_event('input')
        assert await page.locator('#scClockLabel').inner_text()=='t + 60 min'
        assert await page.locator('#scTimeline svg').count()==1
        await page.locator('#scRoute').select_option('T1')
        assert await page.locator('#scMap .sc-truck').count()==1
        await page.locator('#scRoute').select_option('all')
        # Capture only on request; image is explicitly a mocked-data UI preview.
        if os.environ.get('SC_SCREENSHOT'):
            await page.evaluate('''()=>{const n=document.createElement('p');n.id='testPreviewLabel';n.textContent='UI TEST PREVIEW · Mock API data · Not a backend benchmark';n.style='padding:12px 28px;border:1px solid currentColor;font:600 13px sans-serif';document.body.prepend(n)}''')
            await page.screenshot(path=os.environ['SC_SCREENSHOT'],full_page=True)
            await page.evaluate("document.getElementById('testPreviewLabel').remove()")
        await page.locator('#scApprove').click()
        await page.wait_for_function('window.__data.revision===3 && !document.querySelector("#scRecover").disabled')
        assert await page.locator('#scApprove').is_disabled()
        # Keep the old proposal after a mutation; never approve it against a new revision.
        await page.locator('#scRecover').click();await page.wait_for_function('!document.querySelector("#scApprove").disabled')
        await page.locator('#scBridge').click();await page.wait_for_function('window.__data.revision===4 && !document.querySelector("#scReset").disabled')
        assert await page.locator('#scApprove').is_disabled()
        assert 'Stale' in await page.locator('#scSource').inner_text()
        await page.locator('[data-sc-tab="memory"]').click()
        await page.locator('#scCases button').click();assert 'digest' in await page.locator('#scCaseDetail').inner_text()
        await page.locator('[data-sc-tab="benchmark"]').click()
        await page.locator('#scBenchmark').click()
        await page.wait_for_function('document.querySelectorAll("#scBenchmarkTable tbody tr").length===4')
        assert 'MOCK' in await page.locator('#scBenchmarkNote').inner_text()
        await page.locator('[data-sc-tab="evidence"]').click()
        async with page.expect_download() as export:
            await page.locator('#scExport').click()
        download=await export.value;payload=json.loads(Path(await download.path()).read_text())
        assert payload['authenticated_signature'] is False
        calls=await page.evaluate('window.__calls')
        mutation=[c for c in calls if c['method']=='POST']
        assert all('expected_revision' in c['body'] for c in mutation)
        assert all('owner' not in c['body'] for c in mutation)
        assert next(c for c in mutation if c['path'].endswith('/plan'))['body']=={'expected_revision':2,'mode':'ecai'}
        assert all(c['path'].startswith('/ecai/supply-chain/public') for c in calls)
        assert all(c.get('headers',{}).get('X-ECAI-Lab-Request')=='1' for c in calls)
        # Sign-in switches to a separate account, never adopting guest cases.
        await page.evaluate("window.__signed=true;window.__token='alice-token-123';window.__sc.accessChanged();window.__sc.refresh()")
        assert await page.locator('#scAccess').is_hidden()
        assert await page.locator('#scLoaded').is_hidden()
        assert await page.evaluate('window.__calls.at(-1).path')=='/ecai/supply-chain'
        assert await page.locator('#scMemoryCount').inner_text()=='0'
        await page.locator('#scReset').click()
        await page.wait_for_function('window.__data.revision===1 && !document.querySelector("#scReset").disabled')
        # Delayed old-account response cannot refill the next account's DOM.
        await page.evaluate('()=>{window.__delay=true;window.__late=window.__sc.refresh().catch(e=>e.name)}')
        await page.wait_for_function('typeof window.__release==="function"')
        await page.evaluate("window.__token='bob-token-123';window.__sc.reset();window.__release()")
        await page.evaluate('window.__late')
        assert await page.locator('#scMetrics').inner_text()==''
        assert await page.locator('#scCaseDetail').inner_text()=='Select a case to inspect its integrity and outcome.'
        await page.evaluate('window.__delay=false;window.__sc.accessChanged();window.__sc.refresh()')
        assert await page.locator('#scLoaded').is_hidden()
        # Logout (and wallet-only mode) returns to the same browser demo, not Alice.
        await page.evaluate("window.__signed=false;window.__token='';window.__sc.accessChanged();window.__sc.refresh()")
        assert await page.locator('#scAccess').is_visible()
        assert await page.locator('#scLoaded').is_visible()
        assert await page.locator('#scRevision').inner_text()=='INPUT REVISION 4'
        assert await page.locator('#scMemoryCount').inner_text()=='1'
        await page.evaluate("window.__token='wallet-token';window.__sc.reset();window.__sc.accessChanged();window.__sc.refresh()")
        assert await page.evaluate('window.__calls.at(-1).path')=='/ecai/supply-chain/public'
        await page.locator('[data-sc-tab="network"]').click()
        await page.set_viewport_size({'width':390,'height':844})
        assert await page.evaluate('document.documentElement.scrollWidth <= window.innerWidth'), 'mobile page overflow'
        await page.evaluate("document.documentElement.style.setProperty('--theme-bg','#101820');document.documentElement.style.setProperty('--theme-surface','#182332');document.documentElement.style.setProperty('--theme-text','#edf3fa')")
        # Busy/rate-limited calls do not trigger sign-in or disable the whole lab.
        await page.evaluate('window.__nextError=429')
        await page.locator('#scRecover').click()
        await page.wait_for_function('document.querySelector("#scStatus").textContent.includes("retry")')
        assert await page.locator('#scRecover').is_enabled()
        # Expiry creates a blank session, but never replays the expired mutation.
        before=await page.evaluate('window.__calls.length')
        await page.evaluate('window.__nextError=410')
        await page.locator('#scRecover').click()
        await page.wait_for_function('document.querySelector("#scStatus").textContent.includes("expired")')
        assert await page.locator('#scLoaded').is_hidden()
        assert await page.locator('#scReset').is_enabled()
        after=await page.evaluate('window.__calls.slice('+str(before)+')')
        assert [c['method'] for c in after]==['POST','GET']
        assert not await page.evaluate('Boolean(window.__login)')
        assert not errors,errors
        await page.evaluate('window.__sc.dispose()')
        await browser.close()
    print('PASS: Recovery Lab public guest flow, signed-in/wallet isolation, map, recovery, stale approval, memory, benchmark, export, late-response protection, expiry, rate limits and mobile layout')

if __name__=='__main__':asyncio.run(main())
