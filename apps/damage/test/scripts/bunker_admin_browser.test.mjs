import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
const {chromium} = createRequire(import.meta.url)('playwright');
const base = new URL('../../', import.meta.url);
const template = await readFile(new URL('priv/templates/ui/dashboard/node_bunker_tab.mustache', base), 'utf8');
const css = (await readFile(new URL('priv/static/css/dashboard-workspace.css',base),'utf8')) + (await readFile(new URL('priv/static/css/node-bunker.css', base), 'utf8'));
const js = await readFile(new URL('priv/static/js/node-bunker.js', base), 'utf8');
const {displayStatus, freshness, setupText, controlAction} = await import(new URL('priv/static/js/node-bunker.js',base));
const fixture = () => ({busy:false,closure:'outstanding',health_stale:false,evidence:{},health:{
  status:'passed',completed_at:Math.floor(Date.now()/1000),checks:[
    {id:'service_ready',status:'passed',next_action:'Observe the service.'},
    {id:'local_secret_absent',status:'failed',next_action:'Remove the local entry.'}],
  setup:{signing_public_key:'a'.repeat(64),clients:['b'.repeat(64)],aws:{region:'ap-southeast-2'},
    methods:['ping','sign_event'],kinds:[1,30023],relays:['wss://relay.example']}}});

test('operator guide links have focusable destinations and reference inputs have instructions',()=>{
  const ids = [...template.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);
  assert.equal(new Set(ids).size, ids.length, 'Guide destinations must be unique');
  for (const match of template.matchAll(/<a\b[^>]*href="#([^"]+)"[^>]*data-bunker-go[^>]*>/g)) {
    assert.ok(ids.includes(match[1]), `Missing guide target ${match[1]}`);
    assert.match(template, new RegExp(`<h[123] id="${match[1]}" tabindex="-1"`));
  }
  const inputs = [...template.matchAll(/<input\b[^>]*name="([^"]+)"[^>]*aria-describedby="([^"]+)"[^>]*>/g)];
  assert.deepEqual(inputs.map(m=>m[1]), [
    'iam_reviewed','temporary_admin_removed','external_client_accepted','recovery_custodian_confirmed'
  ]);
  for (const input of inputs) assert.ok(ids.includes(input[2]), `Missing input instructions ${input[2]}`);
  for (const match of template.matchAll(/<a\b[^>]*href="(https:[^"]+)"[^>]*>/g)) {
    assert.ok(['console.aws.amazon.com','docs.aws.amazon.com'].includes(new URL(match[1]).hostname));
    assert.match(match[0], /rel="noopener noreferrer"/);
  }
});

test('UI evidence becomes stale and future timestamps do not pass',()=>{
  assert.equal(freshness({completed_at:100},60,101),true);
  assert.equal(freshness({completed_at:200},60,101),false);
  assert.equal(displayStatus({status:'passed',completed_at:100},60,200),'stale');
  assert.equal(displayStatus({},60,200),'not_checked');
});

test('known text fields decode charlists without modifying report data',()=>{
  const codes = Array.from('ap-southeast-2', c => c.codePointAt(0));
  const before = JSON.stringify(codes);
  assert.equal(setupText(codes), 'ap-southeast-2');
  assert.equal(JSON.stringify(codes), before);
  assert.equal(setupText('damage-node-prod'), 'damage-node-prod');
  assert.equal(setupText([0x1f512]), '🔒');
  assert.equal(setupText([0xd800]), 'Invalid text value');
  assert.equal(setupText([null]), 'Invalid text value');
  assert.equal(setupText({}), 'Invalid text value');
  assert.equal(setupText([]), 'Not configured');
  assert.equal(controlAction({next_action:'Repair'}, 'failed'), 'Repair');
  assert.match(controlAction({next_action:'Repair'}, 'passed'), /No corrective action/);
  assert.match(controlAction({next_action:'Repair'}, 'stale'), /Check health/);
});

test('guided navigation, explicit actions, acceptance/export and mobile layout',async()=>{
  let state=fixture(), posts=[], failGet=false;
  const guides = [
    ['current_controls','bunker-health-guide','overview'],
    ['live_signing','bunker-signing-guide','evidence'],
    ['cold_restart','bunker-restart-guide','recovery'],
    ['backup_restore','bunker-restore-guide','recovery'],
    ['version_promotion','bunker-pending-guide','recovery'],
    ['operator_acceptance','bunker-acceptance-guide','recovery']
  ];
  state.closure_tasks = guides.map(([id])=>({id,status:'not_checked',next_action:'Complete the required check.'}));
  const server=createServer(async(req,res)=>{
    if(req.url==='/api/admin/bunker'){
      res.setHeader('content-type','application/json');
      if(req.method==='POST'){
        let bytes=''; for await(const part of req)bytes+=part;
        const body=JSON.parse(bytes);
        posts.push({body,header:req.headers['x-damage-bunker-action']});
        if(body.action==='accept') {
          state.acceptance={actor:'node-admin-test',report_sha256:body.report_sha256,references:body.references};
          state.handover_status='accepted'; state.closure='accepted';
          state.closure_tasks=state.closure_tasks.filter(task=>task.id!=='operator_acceptance');
          state.closure_tasks.push({id:'operator_acceptance',status:'operator_attested',next_action:'Record IAM and acceptance references.'});
        }
        res.end(JSON.stringify({status:'running'})); return;
      }
      if(failGet){res.statusCode=503;res.end(JSON.stringify({error:'offline'}));return;}
      res.end(JSON.stringify(state)); return;
    }
    if(req.url==='/node-bunker.js'){res.setHeader('content-type','text/javascript');res.end(js);return;}
    res.setHeader('content-type','text/html');
    res.end(`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:16px system-ui;margin:24px;background:#f6f8fa;color:#1f2937}button{padding:10px;border:1px solid #dce2ea;border-radius:7px} .workspace-card{background:white}${css}</style></head><body class="damage-dashboard">${template}<script type="module" src="/node-bunker.js"></script></body></html>`);
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  let browser;
  try{
    browser=await chromium.launch({headless:true,executablePath:process.env.BUNKER_TEST_CHROMIUM || undefined,args:['--no-sandbox','--disable-dev-shm-usage']});
    const page=await browser.newPage({viewport:{width:1366,height:1000}});
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/dashboard#node-bunker-tab`);
    await page.getByRole('cell',{name:'Signing service',exact:true}).waitFor();
    assert.equal(posts.length,0,'Opening the page must not sign or restart');
    assert.equal(await page.locator('#bunker-accept').isDisabled(),true);
    assert.equal(await page.locator('[data-bunker-export]:disabled').count(),2);
    // Each checklist link changes view and focus, without running its action or
    // replacing the outer dashboard route.
    for(const [id,target,pane] of guides) {
      await page.getByRole('button',{name:'Recovery & handover',exact:true}).click();
      await page.locator('#bunker-closing-checks tr').filter({has:page.getByRole('cell',{name:id.replaceAll('_',' '),exact:true})}).locator('[data-bunker-go]').click();
      assert.equal(await page.locator(`[data-bunker-pane="${pane}"]`).isVisible(),true);
      assert.equal(await page.evaluate(()=>document.activeElement.id),target);
      assert.equal(new URL(page.url()).hash,'#node-bunker-tab');
    }
    await page.getByRole('button',{name:'Overview',exact:true}).click();
    await page.locator('#bunker-checks').getByRole('link',{name:'Open setup instructions'}).click();
    assert.equal(await page.evaluate(()=>document.activeElement.id),'bunker-custody-guide');
    assert.equal(await page.locator('[data-bunker-pane="setup"]').isVisible(),true);
    assert.equal(posts.length,0,'Guide navigation must never execute maintenance or acceptance');
    assert.equal(await page.locator('#bunker-confirm').isVisible(),false);
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    await page.getByRole('button',{name:'Check health',exact:true}).click();
    await page.waitForFunction(()=>!document.querySelector('[data-bunker-action="health"]').disabled);
    assert.equal(posts[0].body.action,'health');assert.equal(posts[0].header,'1');
    await page.getByRole('button',{name:'Recovery & handover',exact:true}).click();
    await page.getByRole('button',{name:'Restart & verify',exact:true}).click();
    await page.locator('#bunker-confirm').waitFor({state:'visible'});
    await page.getByRole('button',{name:'Cancel',exact:true}).click();assert.equal(posts.length,1);
    await page.getByRole('button',{name:'Restart & verify',exact:true}).click();
    const maintenancePost = page.waitForResponse(r=>r.url().endsWith('/api/admin/bunker') && r.request().method()==='POST');
    await page.getByRole('button',{name:'Proceed',exact:true}).click();
    await maintenancePost;
    await page.waitForFunction(()=>!document.querySelector('[data-bunker-action="restart"]').disabled);
    assert.deepEqual(posts[1].body,{action:'restart',confirmed:true});
    // Inject data into the mock response; all dynamic values must be text.
    state.health.checks[1].next_action='<img src=x onerror="window.injected=true">';
    state.health.setup.aws = Object.fromEntries(Object.entries({
      region:'ap-southeast-2', expected_role_name:'damage-node-prod',
      expected_account_id:'123456789012', secret_id:'/example/vault-passphrase'
    }).map(([key,value])=>[key,Array.from(value,c=>c.codePointAt(0))]));
    state.closure_tasks = [
      {id:'live_signing',status:'not_checked',next_action:'Run Verify signing.'},
      {id:'cold_restart',status:'blocked',next_action:'Complete prerequisite checks.'},
      {id:'backup_restore',status:'stale',next_action:'Repeat recovery.'}
    ];
    const now=Math.floor(Date.now()/1000);
    const testedVersion='<img src=x onerror="window.versionInjected=true">';
    state.evidence={
      pending:{status:'passed',completed_at:now,recovery:{secret_provenance:{baseline_version_id:'baseline-current-001',version_id:testedVersion}}},
      recovery:{status:'passed',completed_at:now,recovery:{secret_provenance:{version_id:'promoted-current-002'}}},
      restart:{status:'passed',completed_at:now,active_secret_version:'restarted-version-002'},
      verify:{status:'passed',completed_at:now,sha256:'c'.repeat(64),exchanges:[]}
    };
    await page.getByRole('button',{name:'Check health',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('#bunker-checks').textContent.includes('<img'));
    assert.equal(await page.evaluate(()=>window.injected),undefined);
    assert.equal(await page.locator('#bunker-checks img').count(),0);
    assert.match(await page.locator('#bunker-checks tr').first().textContent(), /No corrective action/);
    assert.equal(await page.locator('#bunker-closing-checks [data-status="not_checked"]').count(),1);
    assert.equal(await page.locator('#bunker-closing-checks [data-status="blocked"]').count(),1);
    assert.equal(await page.locator('#bunker-closing-checks [data-status="stale"]').count(),1);
    const versions=await page.locator('#bunker-version-evidence').textContent();
    for(const value of ['baseline-current-001',testedVersion,'promoted-current-002','restarted-version-002','c'.repeat(64)]) assert.ok(versions.includes(value));
    assert.equal(await page.locator('#bunker-version-evidence img').count(),0);
    assert.equal(await page.evaluate(()=>window.versionInjected),undefined);
    if(process.env.BUNKER_QA_DIR){await page.getByRole('button',{name:'Overview',exact:true}).click();await page.screenshot({path:`${process.env.BUNKER_QA_DIR}/bunker-desktop.png`,fullPage:true});}
    await page.setViewportSize({width:390,height:844});
    await page.getByRole('button',{name:'Setup',exact:true}).click();
    const setup = await page.locator('#bunker-setup').textContent();
    for(const value of ['ap-southeast-2','damage-node-prod','123456789012','/example/vault-passphrase','1, 30023']) assert.ok(setup.includes(value));
    assert.ok(!setup.includes('97,112,45'));
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    await page.getByRole('button',{name:'Recovery & handover',exact:true}).click();
    await page.locator('.bunker-route a[href="#bunker-acceptance-guide"]').click();
    assert.equal(await page.evaluate(()=>document.activeElement.id),'bunker-acceptance-guide');
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    const references={
      iam_reviewed:'CHG-2041/iam-review', temporary_admin_removed:'CHG-2041/admin-removal',
      external_client_accepted:'UAT-2041/external-client', recovery_custodian_confirmed:'OPS-2041/recovery-custody'
    };
    assert.equal(await page.getByLabel('External client accepted',{exact:true}).count(),1);
    for(const [name,value] of Object.entries(references)) await page.locator(`input[name="${name}"]`).fill(value);
    assert.equal(posts.some(p=>p.body.action==='accept'),false,'Filling references must not submit acceptance');
    state.closure='awaiting_acceptance';
    await page.getByRole('button',{name:'Check health',exact:true}).click();
    await page.waitForFunction(()=>!document.querySelector('#bunker-accept').disabled);
    const acceptancePost=page.waitForResponse(r=>r.url().endsWith('/api/admin/bunker') && r.request().method()==='POST' && r.request().postDataJSON().action==='accept');
    await page.getByRole('button',{name:'Record handover acceptance',exact:true}).click();
    await acceptancePost;
    await page.waitForFunction(()=>document.querySelector('#bunker-acceptance-state').textContent.includes('node-admin-test'));
    assert.deepEqual(posts.find(p=>p.body.action==='accept'),{body:{action:'accept',report_sha256:'c'.repeat(64),references},header:'1'});
    assert.equal(await page.locator('#bunker-summary article').last().locator('strong').textContent(),'accepted');
    const acceptedRow=page.locator('#bunker-closing-checks tr').filter({has:page.getByRole('cell',{name:'operator acceptance',exact:true})});
    assert.match(await acceptedRow.textContent(),/Acceptance recorded/);
    assert.doesNotMatch(await acceptedRow.textContent(),/Record IAM/);
    assert.equal(await acceptedRow.getByRole('link',{name:'Export the completed handover',exact:true}).count(),1);
    const beforeExport=posts.length;
    const downloaded=page.waitForEvent('download');
    await page.getByRole('button',{name:'Export handover evidence',exact:true}).click();
    const download=await downloaded;
    assert.equal(download.suggestedFilename(),'bunker-handoff-evidence.json');
    const exported=JSON.parse(await readFile(await download.path(),'utf8'));
    assert.equal(exported.evidence.verify.sha256,'c'.repeat(64));
    assert.equal(exported.evidence.pending.recovery.secret_provenance.version_id,testedVersion);
    assert.deepEqual(exported.acceptance.references,references);
    assert.equal(posts.length,beforeExport,'Export must only download the observed evidence');
    // A fresh eligible state still becomes disabled if observations cannot be refreshed.
    state.closure='awaiting_acceptance';
    await page.getByRole('button',{name:'Check health',exact:true}).click();
    await page.waitForFunction(()=>!document.querySelector('#bunker-accept').disabled);
    failGet=true;
    await page.getByRole('button',{name:'Check health',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('#bunker-message').textContent.includes('Could not refresh'));
    assert.equal(await page.locator('#bunker-accept').isDisabled(),true);
    assert.deepEqual(errors,[]);
    if(process.env.BUNKER_QA_DIR){await page.screenshot({path:`${process.env.BUNKER_QA_DIR}/bunker-mobile.png`,fullPage:true});}
  } finally {if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
});
