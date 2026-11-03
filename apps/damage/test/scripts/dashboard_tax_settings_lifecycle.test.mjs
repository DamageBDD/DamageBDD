import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const {chromium} = createRequire(import.meta.url)('playwright');
const base = new URL('../../', import.meta.url);
const source = await readFile(new URL('priv/static/js/dashboard-tax-settings.js', base), 'utf8');
const template = await readFile(new URL('priv/templates/ui/dashboard/node_tax_reports_tab.mustache', base), 'utf8');
const settings = template.split('{{#tax_enabled}}')[0]
  .replaceAll('{{^tax_enabled}}', '').replaceAll('{{/tax_enabled}}', '') + '</section>';
const initial = () => ({version: 'configuration-v1', running: false, pending_restart: [], fields: [
  {name:'tax_enabled',label:'Enable tax reporting',type:'boolean',value:false},
  {name:'tax_cln_owner',label:'CLN tax owner',type:'ae_account',value:'ak_'+'2'.repeat(52)},
  {name:'tax_data_dir',label:'Evidence directory',type:'absolute_path',value:'/var/lib/damage/tax'},
  {name:'tax_backfill_on_start',label:'Backfill on start',type:'boolean',value:false},
  {name:'tax_jurisdiction',label:'Country',type:'tax_jurisdiction',value:'AU',options:[{value:'AU',label:'Australia'}]},
  {name:'tax_standard_utc_offset_minutes',label:'UTC offset',type:'integer',value:600,min:0,max:840},
  {name:'tax_max_prices_per_backfill',label:'Price budget',type:'integer',value:200,min:1,max:500},
  {name:'tax_price_pause_ms',label:'Price pause',type:'integer',value:1000,min:0,max:60000}
]});

test('tax settings load on activation, deduplicate reads, and lock stale edits until reload', async () => {
  let view=initial(), unavailable=false, hold=false, release=null, gets=0;
  const posts=[];
  const server=createServer(async (req,res) => {
    if(req.url==='/dashboard-tax-settings.js') {
      res.setHeader('content-type','text/javascript'); res.end(source); return;
    }
    if(req.url==='/api/node/tax/settings') {
      res.setHeader('content-type','application/json');
      if(req.method==='GET') {
        gets++;
        const responseView=JSON.stringify(view), responseUnavailable=unavailable;
        if(hold) await new Promise(resolve => { release=resolve; });
        if(responseUnavailable) { res.statusCode=503; res.end(JSON.stringify({error:'tax_settings_unavailable'})); }
        else res.end(responseView);
        return;
      }
      let body=''; for await(const part of req) body+=part;
      posts.push({body:JSON.parse(body),header:req.headers['x-damage-tax-request']});
      if(unavailable) { res.statusCode=503; res.end(JSON.stringify({error:'tax_settings_unavailable'})); return; }
      view={...view, version:'configuration-v2', fields:view.fields.map(f =>
        Object.hasOwn(posts.at(-1).body.changes,f.name) ? {...f,value:posts.at(-1).body.changes[f.name]} : f)};
      res.end(JSON.stringify(view)); return;
    }
    const standalone=req.url==='/standalone';
    res.setHeader('content-type','text/html');
    res.end(`<!doctype html><html><body>
      <button id="open-tax">Open tax settings</button>
      ${standalone ? settings : `<div id="node-tax-reports-tab" data-dashboard-view hidden>${settings}</div>`}
      <script type="module">
        import {initDashboardTaxSettings} from '/dashboard-tax-settings.js';
        window.taxEditor=initDashboardTaxSettings();
        window.editorReady=true;
        document.getElementById('open-tax').addEventListener('click',()=>{
          document.getElementById('node-tax-reports-tab').hidden=false;
          document.dispatchEvent(new CustomEvent('damage:panelchange',{detail:{id:'node-tax-reports-tab'}}));
        });
      </script></body></html>`);
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  let browser;
  try {
    browser=await chromium.launch({headless:true,executablePath:process.env.BUNKER_TEST_CHROMIUM || undefined,
      args:['--no-sandbox','--disable-dev-shm-usage']});
    const page=await browser.newPage();
    const errors=[]; page.on('pageerror',e=>errors.push(e.message));
    const origin=`http://127.0.0.1:${server.address().port}`;
    await page.goto(origin);
    await page.waitForFunction(()=>window.editorReady);
    assert.equal(gets,0,'Hidden tax pane must not issue a background request');
    assert.equal(posts.length,0);
    assert.equal(await page.locator('#tax-settings-save').isDisabled(),true);
    assert.equal(await page.locator('#tax-settings-discard').isDisabled(),true);
    hold=true;
    const started=page.waitForRequest(r=>r.url().endsWith('/api/node/tax/settings'));
    await page.locator('#open-tax').click(); await started;
    await page.evaluate(()=>{
      for(let i=0;i<4;i++) document.dispatchEvent(new CustomEvent('damage:panelchange',{detail:{id:'node-tax-reports-tab'}}));
      void window.taxEditor.refresh(); void window.taxEditor.refresh();
    });
    assert.equal(gets,1,'Activation, observer and explicit reads must share one in-flight request');
    hold=false; release();
    await page.waitForFunction(()=>document.getElementById('tax-settings-status').textContent.includes('Tax settings loaded'));
    assert.equal(await page.locator('#tax-setting-tax_enabled').isDisabled(),false,
      'Disabled tax reporting must remain configurable');
    assert.equal(await page.locator('#tax-setting-tax_enabled').isChecked(),false);
    await page.locator('#tax-setting-tax_enabled').check();
    assert.equal(await page.locator('#tax-settings-save').isEnabled(),true);
    unavailable=true;
    await page.locator('#tax-settings-refresh').click();
    await page.waitForFunction(()=>document.getElementById('tax-settings-status').textContent.includes('node settings service is unavailable'));
    assert.equal(gets,2);
    assert.equal(await page.locator('#tax-setting-tax_enabled').isChecked(),true,'Keep displayed values after refresh failure');
    assert.equal(await page.locator('#tax-setting-tax_enabled').isDisabled(),true);
    assert.equal(await page.locator('#tax-settings-save').isDisabled(),true);
    assert.equal(await page.locator('#tax-settings-discard').isDisabled(),true);
    assert.equal(await page.locator('#tax-settings-refresh').isEnabled(),true);
    await page.evaluate(()=>{
      document.getElementById('tax-setting-tax_enabled').dispatchEvent(new Event('input',{bubbles:true}));
      document.getElementById('tax-settings-form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));
      document.dispatchEvent(new CustomEvent('damage:panelchange',{detail:{id:'node-tax-reports-tab'}}));
    });
    assert.equal(posts.length,0,'Stale values cannot submit even through a synthetic form event');
    assert.equal(gets,2,'Repeated activation must not retry a failed service automatically');
    unavailable=false;
    await page.locator('#tax-settings-refresh').click();
    await page.waitForFunction(()=>document.getElementById('tax-settings-status').textContent.includes('Tax settings loaded'));
    assert.equal(gets,3);
    assert.equal(await page.locator('#tax-setting-tax_enabled').isDisabled(),false);
    assert.equal(await page.locator('#tax-setting-tax_enabled').isChecked(),false,'Reload replaces stale edits with recorded values');
    await page.locator('#tax-setting-tax_enabled').check();
    await page.locator('#tax-settings-save').click();
    await page.waitForFunction(()=>document.getElementById('tax-settings-status').textContent.includes('Tax settings saved'));
    assert.deepEqual(posts,[{body:{action:'save',version:'configuration-v1',changes:{tax_enabled:true}},header:'1'}]);

    // An uncertain POST must also block a blind second save until values are re-read.
    await page.locator('#tax-setting-tax_enabled').uncheck(); unavailable=true;
    await page.locator('#tax-settings-save').click();
    await page.waitForFunction(()=>document.getElementById('tax-settings-status').textContent.includes('Save was not confirmed'));
    assert.equal(await page.locator('#tax-setting-tax_enabled').isDisabled(),true);
    assert.equal(await page.locator('#tax-settings-save').isDisabled(),true);
    unavailable=false;

    // An old session response must neither restore privileged fields nor
    // clear the busy flag of a new session's concurrent request.
    view={...view,fields:view.fields.map(f=>f.name==='tax_data_dir' ? {...f,value:'/previous-account/tax'} : f)};
    hold=true;
    const oldStarted=page.waitForRequest(r=>r.url().endsWith('/api/node/tax/settings'));
    await page.evaluate(()=>{void window.taxEditor.refresh();}); await oldStarted;
    const releaseOld=release;
    await page.evaluate(()=>{
      document.getElementById('node-tax-reports-tab').hidden=true;
      document.dispatchEvent(new Event('auth:changed'));
    });
    assert.equal(gets,4,'Changing account while tax is hidden does not fetch');
    assert.equal(await page.locator('#tax-settings-fields').textContent(),'');
    assert.equal(await page.locator('#tax-settings-save').isDisabled(),true);
    view={...view,fields:view.fields.map(f=>f.name==='tax_data_dir' ? {...f,value:'/current-account/tax'} : f)};
    const newStarted=page.waitForRequest(r=>r.url().endsWith('/api/node/tax/settings'));
    await page.locator('#open-tax').click(); await newStarted;
    assert.equal(gets,5);
    const releaseNew=release;
    const oldFinished=page.waitForResponse(r=>r.url().endsWith('/api/node/tax/settings'));
    releaseOld(); await oldFinished;
    // Let the old response and its finally handler complete in the browser.
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
    assert.equal(await page.locator('#tax-settings-fields').textContent(),'','Old account values cannot reappear');
    assert.equal(await page.locator('#tax-settings-refresh').isDisabled(),true,'Old completion must not unlock the new request');
    hold=false; releaseNew();
    await page.waitForFunction(()=>document.getElementById('tax-setting-tax_data_dir')?.value==='/current-account/tax');
    assert.equal(await page.locator('#tax-settings-refresh').isEnabled(),true);
    assert.equal(await page.locator('#tax-settings-fields').textContent().then(s=>s.includes('previous-account')),false);
    const standalone=await browser.newPage();
    await standalone.goto(origin+'/standalone');
    await standalone.waitForFunction(()=>document.getElementById('tax-settings-status').textContent.includes('Tax settings loaded'));
    assert.equal(gets,6,'Visible standalone settings load immediately');
    assert.deepEqual(errors,[]);
  } finally {
    if(release) release();
    if(browser) await browser.close();
    await new Promise(resolve=>server.close(resolve));
  }
});
