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
    ['operator_acceptance','bunker-acceptance-guide',null]
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
    res.end(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:16px system-ui;margin:24px;background:#f6f8fa;color:#1f2937}button{padding:10px;border:1px solid #dce2ea;border-radius:7px} .workspace-card{background:white}${css}</style></head><body class="damage-dashboard">${template}<script type="module" src="/node-bunker.js"></script></body></html>`);
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  let browser;
  try{
    browser=await chromium.launch({headless:true,executablePath:process.env.BUNKER_TEST_CHROMIUM || undefined,args:['--no-sandbox','--disable-dev-shm-usage']});
    const page=await browser.newPage({viewport:{width:1366,height:1000}});
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/dashboard#node-bunker-tab`);
    await page.locator('#bunker-details > summary').click();
    await page.getByRole('cell',{name:'Signing service',exact:true}).waitFor();
    assert.equal(posts.length,0,'Opening the page must not sign or restart');
    assert.equal(await page.locator('#bunker-accept').isDisabled(),true);
    assert.equal(await page.locator('[data-bunker-export]:disabled').count(),2);
    // Each checklist link changes view and focus, without running its action or
    // replacing the outer dashboard route.
    for(const [id,target,pane] of guides) {
      await page.getByRole('button',{name:'Recovery & handover',exact:true}).click();
      await page.locator('#bunker-closing-checks tr').filter({has:page.getByRole('cell',{name:id.replaceAll('_',' '),exact:true})}).locator('[data-bunker-go]').click();
      if (pane) assert.equal(await page.locator(`[data-bunker-pane="${pane}"]`).isVisible(),true);
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
    await page.locator('#bunker-details').getByRole('button',{name:'Check health',exact:true}).click();
    await page.waitForFunction(()=>!document.querySelector('[data-bunker-action="health"]').disabled);
    assert.equal(posts[0].body.action,'health');assert.equal(posts[0].header,'1');
    await page.getByRole('button',{name:'Recovery & handover',exact:true}).click();
    await page.locator('#bunker-details').getByRole('button',{name:'Restart & verify',exact:true}).click();
    await page.locator('#bunker-confirm').waitFor({state:'visible'});
    await page.getByRole('button',{name:'Cancel',exact:true}).click();assert.equal(posts.length,1);
    await page.locator('#bunker-details').getByRole('button',{name:'Restart & verify',exact:true}).click();
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
    await page.locator('#bunker-details').getByRole('button',{name:'Check health',exact:true}).click();
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
    await page.locator('.bunker-next-footer a[href="#bunker-acceptance-guide"]').click();
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
    await page.locator('#bunker-details').getByRole('button',{name:'Check health',exact:true}).click();
    await page.waitForFunction(()=>!document.querySelector('#bunker-accept').disabled);
    const acceptancePost=page.waitForResponse(r=>r.url().endsWith('/api/admin/bunker') && r.request().method()==='POST' && r.request().postDataJSON().action==='accept');
    await page.locator('#bunker-accept').click();
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
    await page.locator('#bunker-signoff-panel').getByRole('button',{name:'Export handover evidence',exact:true}).click();
    const download=await downloaded;
    assert.equal(download.suggestedFilename(),'bunker-handoff-evidence.json');
    const exported=JSON.parse(await readFile(await download.path(),'utf8'));
    assert.equal(exported.evidence.verify.sha256,'c'.repeat(64));
    assert.equal(exported.evidence.pending.recovery.secret_provenance.version_id,testedVersion);
    assert.deepEqual(exported.acceptance.references,references);
    assert.equal(posts.length,beforeExport,'Export must only download the observed evidence');
    // A fresh eligible state still becomes disabled if observations cannot be refreshed.
    state.closure='awaiting_acceptance';
    await page.locator('#bunker-details').getByRole('button',{name:'Check health',exact:true}).click();
    await page.waitForFunction(()=>!document.querySelector('#bunker-accept').disabled);
    failGet=true;
    await page.locator('#bunker-details').getByRole('button',{name:'Check health',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('#bunker-message').textContent.includes('Could not refresh'));
    assert.equal(await page.locator('#bunker-accept').isDisabled(),true);
    assert.deepEqual(errors,[]);
    if(process.env.BUNKER_QA_DIR){await page.screenshot({path:`${process.env.BUNKER_QA_DIR}/bunker-mobile.png`,fullPage:true});}
  } finally {if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
});

test('AWS command copy requires current evidence and never performs an AWS operation',async()=>{
  const now=1700000000;
  const baseline='11111111-1111-4111-8111-111111111111', pending='22222222-2222-4222-8222-222222222222';
  const state=fixture(), posts=[], requests=[];
  let failGet=false, revision=0;
  state.health.completed_at=now;
  state.health.target='deployment-target'; state.health.fingerprint='deployment-fingerprint';
  state.health.setup.aws={region:'ap-southeast-2',expected_account_id:'123456789012',
    expected_role_name:'damage-node-prod',secret_id:'/example/vault-passphrase'};
  const passingPending=()=>({status:'passed',completed_at:now,target:state.health.target,
    fingerprint:state.health.fingerprint,recovery:{secret_provenance:{baseline_version_id:baseline,version_id:pending}}});
  const server=createServer(async(req,res)=>{
    if(req.url==='/api/admin/bunker') {
      res.setHeader('content-type','application/json');
      if(req.method==='POST') {posts.push(req.url);res.end('{}');return;}
      if(failGet) {res.statusCode=503;res.end(JSON.stringify({error:'offline'}));return;}
      res.end(JSON.stringify(state));return;
    }
    if(req.url==='/node-bunker.js') {res.setHeader('content-type','text/javascript');res.end(js);return;}
    if(req.url==='/dashboard') {
      res.setHeader('content-type','text/html');
      res.end(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:16px system-ui;margin:24px}button{padding:10px}${css}</style></head><body class="damage-dashboard">${template}<script type="module" src="/node-bunker.js"></script></body></html>`);return;
    }
    res.statusCode=404;res.end();
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  let browser;
  try {
    browser=await chromium.launch({headless:true,executablePath:process.env.BUNKER_TEST_CHROMIUM || undefined,args:['--no-sandbox','--disable-dev-shm-usage']});
    const page=await browser.newPage({viewport:{width:1366,height:1000}});
    const errors=[];page.on('pageerror',error=>errors.push(error.message));
    page.on('request',request=>requests.push(request.url()));
    await page.addInitScript(at=>{
      window.commandTestNow=at; Date.now=()=>window.commandTestNow*1000;
      window.commandCopies=[];
      Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async text=>window.commandCopies.push(text)}});
    },now);
    await page.goto(`http://127.0.0.1:${server.address().port}/dashboard#node-bunker-tab`);
    await page.locator('#bunker-details > summary').click();
    await page.waitForFunction(()=>!document.querySelector('[data-bunker-copy="inspect"]').disabled);
    const refresh=async()=>{
      const marker=`command-fixture-${++revision}`;
      state.health.setup.clients=[marker];
      await page.evaluate(()=>document.dispatchEvent(new Event('visibilitychange')));
      await page.waitForFunction(value=>document.querySelector('#bunker-setup').textContent.includes(value),marker);
    };
    const copy=action=>page.locator(`[data-bunker-copy="${action}"]`);
    const block=action=>page.locator(`#bunker-cli-${action}`);
    await page.getByRole('button',{name:'Setup',exact:true}).click();
    await page.locator('details:not(#bunker-details)').filter({has:copy('inspect')}).locator('summary').click();
    assert.match(await block('inspect').textContent(),/123456789012/);
    assert.match(await block('inspect').textContent(),/\/example\/vault-passphrase/);
    assert.equal(await copy('promote').isDisabled(),true,'Promotion needs a passing pending rehearsal');
    await copy('inspect').click();
    assert.equal(await page.evaluate(()=>window.commandCopies.at(-1)),await block('inspect').textContent());
    assert.match(await page.locator('#bunker-message').textContent(),/commands copied/i);

    await page.getByRole('button',{name:'Recovery & handover',exact:true}).click();
    await page.locator('details:not(#bunker-details)').filter({has:copy('pending')}).locator('summary').click();
    await page.locator('details:not(#bunker-details)').filter({has:copy('promote')}).locator('summary').click();
    assert.equal(await copy('pending').isDisabled(),false);
    assert.match(await block('pending').textContent(),/get-secret-value/);
    // The fallback selects text for manual copy; it must not invoke any action.
    await page.evaluate(()=>Object.defineProperty(navigator,'clipboard',{configurable:true,value:undefined}));
    await copy('pending').click();
    assert.equal(await page.evaluate(()=>getSelection().toString()),await block('pending').textContent());
    assert.match(await page.locator('#bunker-message').textContent(),/Clipboard unavailable/);
    assert.equal(posts.length,0);

    state.evidence.pending=passingPending(); await refresh();
    assert.equal(await copy('promote').isDisabled(),false);
    const promote=await block('promote').textContent();
    assert.ok(promote.includes(baseline) && promote.includes(pending));
    assert.match(promote,/--remove-from-version-id "\$BUNKER_BASELINE"/);
    for(const action of ['inspect','pending','promote']) assert.equal(await block(action).locator('*').count(),0,'Command blocks must be plain text');
    await page.setViewportSize({width:390,height:844});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'Expanded recovery commands must stay within the mobile viewport');
    await page.getByRole('button',{name:'Setup',exact:true}).click();
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'Expanded inspection commands must stay within the mobile viewport');
    await page.getByRole('button',{name:'Recovery & handover',exact:true}).click();

    const invalidReports=[
      ['failed',{status:'failed'}],['stale',{completed_at:now-86401}],
      ['fingerprint mismatch',{fingerprint:'another-fingerprint'}],['target mismatch',{target:'another-deployment'}],
      ['short version ID',{recovery:{secret_provenance:{baseline_version_id:baseline,version_id:'short'}}}],
      ['same version IDs',{recovery:{secret_provenance:{baseline_version_id:baseline,version_id:baseline}}}]
    ];
    for(const [reason,patch] of invalidReports) {
      state.evidence.pending={...passingPending(),...patch}; await refresh();
      assert.equal(await copy('promote').isDisabled(),true,`Promotion must be disabled: ${reason}`);
    }
    state.evidence.pending=passingPending();state.health.completed_at=now-61;await refresh();
    assert.equal(await copy('promote').isDisabled(),true,'Promotion requires fresh health');
    state.health.completed_at=now;state.health.status='failed';await refresh();
    assert.equal(await copy('promote').isDisabled(),true,'Promotion requires passing health');
    state.health.status='passed';
    // A button can become stale between render and click. Advance just beyond
    // the pending TTL while health remains fresh, without triggering a render.
    state.evidence.pending={...passingPending(),completed_at:now-86400+30};await refresh();
    assert.equal(await copy('promote').isDisabled(),false);
    await page.evaluate(at=>{window.commandTestNow=at;getSelection().removeAllRanges();},now+31);
    await copy('promote').click();
    assert.equal(await copy('promote').isDisabled(),true,'Expiry must be rechecked when copying');
    assert.equal(await page.evaluate(()=>getSelection().toString()),'','Expired commands must not be selected for copy');

    await page.evaluate(at=>{window.commandTestNow=at;},now);
    state.evidence.pending=passingPending();await refresh();
    assert.equal(await copy('promote').isDisabled(),false);
    failGet=true;
    await page.evaluate(()=>document.dispatchEvent(new Event('visibilitychange')));
    await page.waitForFunction(()=>document.querySelector('#bunker-message').textContent.includes('Could not refresh'));
    for(const action of ['inspect','pending','promote']) assert.equal(await copy(action).isDisabled(),true,'Unavailable observations must disable copying');
    assert.equal(posts.length,0,'Inspecting/copying commands must never POST');
    assert.ok(requests.every(url=>new URL(url).hostname==='127.0.0.1'),'No AWS requests may originate from the browser');
    assert.deepEqual(errors,[]);
  } finally {if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
});

test('single guided handover resumes from evidence and refreshes health before accepting the reviewed report',async()=>{
  const now=()=>Math.floor(Date.now()/1000);
  const baseline='10000000-0000-4000-8000-000000000001',tested='20000000-0000-4000-8000-000000000002';
  const target='a'.repeat(64),fingerprint='b'.repeat(64),restartFingerprint='c'.repeat(64);
  const ids=['current_controls','live_signing','cold_restart','backup_restore','version_promotion'];
  const state={busy:false,last_error:null,closure:'outstanding',health_stale:true,handover_status:'not_accepted',evidence:{},
    health:{status:'not_checked',target,fingerprint,checks:[],setup:{signing_public_key:'f'.repeat(64),
      aws:{region:'ap-southeast-2',expected_account_id:'123456789012',expected_role_name:'bunker-runtime',secret_id:'/test/bunker'},
      clients:['d'.repeat(64)],methods:['ping','sign_event'],kinds:[30023],relays:['wss://relay.example']}},
    closure_tasks:ids.map(id=>({id,status:'not_checked',next_action:'Complete the required verification.'}))};
  const posts=[];
  let failVerify=true,changeReportOnHealth=false,failHealth=false;
  const task=(id,status)=>{state.closure_tasks.find(item=>item.id===id).status=status;};
  const report=extra=>({status:'passed',started_at:now(),completed_at:now(),target,
    fingerprint:state.health.fingerprint,runtime_instance:state.evidence.restart?'runtime-after':'runtime-before',
    active_secret_version:state.evidence.restart?tested:baseline,...extra});
  const signing=extra=>report({sha256:'e'.repeat(64),exchanges:[{status:'passed',relay:'wss://relay.example',test:'sign_event',reason:'verified'}],
    policy_checks:[{status:'passed'},{status:'passed'}],...extra});
  function perform(body) {
    if(body.action==='health') {
      state.health={...state.health,...report({status:failHealth?'failed':'passed'}),
        checks:[{id:'service_ready',status:failHealth?'failed':'passed',next_action:'Restore service and check again.'}]};
      state.health_stale=false;state.evidence.health={...state.health};task('current_controls',state.health.status);
      if(changeReportOnHealth) {state.evidence.verify={...state.evidence.verify,sha256:'9'.repeat(64)};changeReportOnHealth=false;}
    }
    if(body.action==='verify') {
      state.evidence.verify=signing({status:failVerify?'failed':'passed',reason:failVerify?'relay_unavailable':undefined});
      task('live_signing',state.evidence.verify.status);
    }
    if(body.action==='pending') {
      state.evidence.pending=report({sha256:'7'.repeat(64),recovery:{secret_provenance:{baseline_version_id:baseline,version_id:tested}}});
      task('version_promotion','blocked');
    }
    if(body.action==='recovery') {
      state.evidence.recovery=report({recovery:{backup_restored:true,wrong_unlock_rejected:true,
        metadata_restore:{restored:true},secret_provenance:{version_id:tested}}});
      task('backup_restore','passed');
    }
    if(body.action==='restart') {
      state.health.fingerprint=restartFingerprint;
      state.evidence.restart=signing({restarted:true,runtime_instance:'runtime-after',active_secret_version:tested});
      state.evidence.verify={...state.evidence.restart};
      task('cold_restart','passed');task('live_signing','passed');task('version_promotion','passed');
    }
    state.closure=state.closure_tasks.every(item=>item.status==='passed')?'awaiting_acceptance':'outstanding';
    if(body.action==='accept') {
      state.acceptance={actor:'node-admin-test',report_sha256:body.report_sha256,references:body.references};
      state.handover_status='accepted';state.closure='accepted';
    }
  }
  const server=createServer(async(req,res)=>{
    if(req.url==='/api/admin/bunker') {
      res.setHeader('content-type','application/json');
      if(req.method==='POST') {
        let text='';for await(const part of req)text+=part;
        const body=JSON.parse(text);posts.push(body);perform(body);
        res.end(JSON.stringify({status:'running'}));return;
      }
      res.end(JSON.stringify(state));return;
    }
    if(req.url==='/node-bunker.js') {res.setHeader('content-type','text/javascript');res.end(js);return;}
    res.setHeader('content-type','text/html');
    res.end(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:16px system-ui;margin:24px}button{padding:10px}${css}</style></head><body class="damage-dashboard">${template}<script type="module" src="/node-bunker.js"></script></body></html>`);
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  let browser;
  try {
    browser=await chromium.launch({headless:true,executablePath:process.env.BUNKER_TEST_CHROMIUM || undefined,args:['--no-sandbox','--disable-dev-shm-usage']});
    const page=await browser.newPage({viewport:{width:1366,height:1000}}),errors=[];
    page.on('pageerror',error=>errors.push(error.message));
    await page.addInitScript(()=>{
      window.copiedCommands=[];
      Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async value=>window.copiedCommands.push(value)}});
    });
    const main=page.locator('#bunker-next-action');
    const expectNext=async label=>page.waitForFunction(value=>{
      const button=document.querySelector('#bunker-next-action');return !button.disabled && button.textContent===value;
    },({'Refresh status':'Retry','Check pending version':'Test prepared version','Verify current version & restore':'Test recovery','Restart & verify':'Restart and test','Review acceptance':'Complete handover','Export handover evidence':'Download report'})[label]||label);
    const run=async(action,confirm=false)=>{
      const nextPost=page.waitForResponse(response=>response.url().endsWith('/api/admin/bunker') && response.request().method()==='POST');
      await (action === 'health' ? page.locator('.bunker-live button') : main).click();
      if(confirm) {await page.locator('#bunker-confirm').waitFor({state:'visible'});await page.getByRole('button',{name:'Proceed',exact:true}).click();}
      await nextPost;
      await page.waitForFunction(()=>!document.querySelector('#bunker-next-action').disabled);
      assert.equal(posts.at(-1).action,action);
      if(confirm) assert.equal(posts.at(-1).confirmed,true);
    };
    await page.goto(`http://127.0.0.1:${server.address().port}/dashboard#node-bunker-tab`);
    await expectNext('Check health');
    assert.equal(await page.locator('#bunker-details').getAttribute('open'),null);
    assert.equal(posts.length,0,'Opening the guided page is observation only');
    assert.equal(await main.isVisible(),false,'Initial health has one visible action');
    assert.equal(await page.locator('.bunker-live button').isVisible(),true);
    if(process.env.BUNKER_QA_DIR) await page.screenshot({path:`${process.env.BUNKER_QA_DIR}/guided-desktop.png`,fullPage:true});
    await run('health');await expectNext('Verify signing');
    await run('verify');await expectNext('Verify signing');
    assert.equal(await page.locator('#bunker-next-status').textContent(),'Needs attention');
    assert.equal(posts.some(post=>post.action==='pending'),false,'Failed signing must not advance to AWS maintenance');
    failVerify=false;await run('verify');await expectNext('Copy prepare commands');
    await page.setViewportSize({width:390,height:844});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    if(process.env.BUNKER_QA_DIR) await page.screenshot({path:`${process.env.BUNKER_QA_DIR}/guided-mobile.png`,fullPage:true});
    const beforePrepare=posts.length;await main.click();await expectNext('Check pending version');
    assert.equal(posts.length,beforePrepare,'Copying prepare commands must not execute a check');
    assert.equal(state.evidence.pending,undefined,'Copying cannot create rehearsal evidence');
    assert.match(await page.locator('#bunker-next-description').textContent(),/after the prepare commands succeed/);
    await main.click();await page.locator('#bunker-confirm').waitFor({state:'visible'});
    await page.getByRole('button',{name:'Cancel',exact:true}).click();
    assert.equal(posts.length,beforePrepare,'Cancelled maintenance must not POST');
    await run('pending',true);await expectNext('Copy promotion commands');
    const beforeReload=posts.length;await page.reload();await expectNext('Copy promotion commands');
    assert.equal(posts.length,beforeReload,'Reload resumes recorded evidence without rerunning pending');
    assert.equal(await page.locator('#bunker-details').getAttribute('open'),null);
    await main.click();await expectNext('Verify current version & restore');
    assert.equal(posts.length,beforeReload,'Copying promotion commands is not promotion evidence');
    assert.equal(state.evidence.recovery,undefined);
    assert.match(await page.evaluate(()=>window.copiedCommands.at(-1)),new RegExp(tested));
    await run('recovery',true);await expectNext('Restart & verify');
    await page.reload();await expectNext('Restart & verify');
    assert.equal(posts.filter(post=>post.action==='pending').length,1);
    await run('restart',true);await expectNext('Review acceptance');
    // The final health refresh is part of explicit acceptance, so a stale health
    // observation should not force another manual navigation loop.
    state.health.completed_at=now()-61;state.health_stale=true;task('current_controls','stale');state.closure='outstanding';
    await page.evaluate(()=>document.dispatchEvent(new Event('visibilitychange')));
    await page.waitForFunction(()=>document.querySelector('#bunker-summary').textContent.includes('stale'));
    await expectNext('Review acceptance');await main.click();
    assert.equal(await page.locator('#bunker-details').getAttribute('open'),null,'Sign-off opens inline without exposing diagnostics');
    assert.equal(await page.locator('#bunker-signoff-panel').isVisible(),true);
    assert.equal(await page.evaluate(()=>document.activeElement.id),'bunker-acceptance-guide');
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    const references={iam_reviewed:'CHG-2041/iam-review',temporary_admin_removed:'CHG-2041/admin-removal',
      external_client_accepted:'UAT-2041/external-client',recovery_custodian_confirmed:'OPS-2041/recovery-custody'};
    for(const [name,value] of Object.entries(references)) await page.locator(`input[name="${name}"]`).fill(value);
    assert.equal(posts.some(post=>post.action==='accept'),false);
    assert.equal(await page.locator('#bunker-accept').textContent(),'Sign off');
    const reviewedHash=state.evidence.verify.sha256;
    changeReportOnHealth=true;const beforeChanged=posts.length;
    await page.locator('#bunker-accept').click();
    await page.waitForFunction(()=>document.querySelector('#bunker-message').textContent.includes('signing report changed'));
    assert.deepEqual(posts.slice(beforeChanged).map(post=>post.action),['health'],'A changed report must not be accepted');
    assert.notEqual(state.evidence.verify.sha256,reviewedHash);
    await expectNext('Refresh status');await main.click();await expectNext('Review acceptance');
    failHealth=true;const beforeFailed=posts.length;await page.locator('#bunker-accept').click();
    await page.waitForFunction(()=>document.querySelector('#bunker-message').textContent.includes('do not permit acceptance'));
    assert.deepEqual(posts.slice(beforeFailed).map(post=>post.action),['health'],'Failed final health must not submit acceptance');
    failHealth=false;await expectNext('Refresh status');await main.click();await expectNext('Check health');
    await run('health');await expectNext('Review acceptance');
    const beforeAccepted=posts.length;await page.locator('#bunker-accept').click();
    await expectNext('Export handover evidence');
    assert.deepEqual(posts.slice(beforeAccepted).map(post=>post.action),['health','accept']);
    assert.deepEqual(posts.at(-1),{action:'accept',report_sha256:state.evidence.verify.sha256,references});
    const beforeExport=posts.length,downloaded=page.waitForEvent('download');await main.click();
    const exported=JSON.parse(await readFile(await (await downloaded).path(),'utf8'));
    assert.deepEqual(exported.acceptance.references,references);
    assert.equal(posts.length,beforeExport);
    await page.reload();await expectNext('Export handover evidence');
    assert.equal(posts.length,beforeExport,'Accepted evidence survives reload without any new verification');
    assert.deepEqual(errors,[]);
  } finally {if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
});
