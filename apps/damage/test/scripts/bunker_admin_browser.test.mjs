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
const {displayStatus, freshness} = await import(new URL('priv/static/js/node-bunker.js',base));
const fixture = () => ({busy:false,closure:'outstanding',health_stale:false,evidence:{},health:{
  status:'passed',completed_at:Math.floor(Date.now()/1000),checks:[
    {id:'service_ready',status:'passed',next_action:'Observe the service.'},
    {id:'local_secret_absent',status:'failed',next_action:'Remove the local entry.'}],
  setup:{signing_public_key:'a'.repeat(64),clients:['b'.repeat(64)],aws:{region:'ap-southeast-2'},
    methods:['ping','sign_event'],kinds:[1,30023],relays:['wss://relay.example']}}});

test('UI evidence becomes stale and future timestamps do not pass',()=>{
  assert.equal(freshness({completed_at:100},60,101),true);
  assert.equal(freshness({completed_at:200},60,101),false);
  assert.equal(displayStatus({status:'passed',completed_at:100},60,200),'stale');
  assert.equal(displayStatus({},60,200),'not_checked');
});

test('operator workflow, maintenance confirmation, escaping and mobile layout',async()=>{
  let state=fixture(), posts=[], failGet=false;
  const server=createServer(async(req,res)=>{
    if(req.url==='/api/admin/bunker'){
      res.setHeader('content-type','application/json');
      if(req.method==='POST'){
        let bytes=''; for await(const part of req)bytes+=part;
        posts.push({body:JSON.parse(bytes),header:req.headers['x-damage-bunker-action']});
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
    await page.goto(`http://127.0.0.1:${server.address().port}`);
    await page.getByRole('cell',{name:'Signing service',exact:true}).waitFor();
    assert.equal(posts.length,0,'Opening the page must not sign or restart');
    assert.equal(await page.locator('#bunker-accept').isDisabled(),true);
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
    state.health.checks[0].next_action='<img src=x onerror="window.injected=true">';
    await page.getByRole('button',{name:'Check health',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('#bunker-checks').textContent.includes('<img'));
    assert.equal(await page.evaluate(()=>window.injected),undefined);
    assert.equal(await page.locator('#bunker-checks img').count(),0);
    if(process.env.BUNKER_QA_DIR){await page.getByRole('button',{name:'Overview',exact:true}).click();await page.screenshot({path:`${process.env.BUNKER_QA_DIR}/bunker-desktop.png`,fullPage:true});}
    await page.setViewportSize({width:390,height:844});
    await page.getByRole('button',{name:'Setup',exact:true}).click();
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    await page.getByRole('button',{name:'Recovery & handover',exact:true}).click();
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
