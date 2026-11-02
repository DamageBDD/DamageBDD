#!/usr/bin/env python3
"""Actual shared component + production dashboard markup/navigation in Chromium.

All account/model/accounting APIs are simulated. No live node, wallet, LLM or
chain requests occur. Requires playwright and Chromium, not a JS bundler.
"""
import argparse
import base64
import json
import re
from pathlib import Path
from urllib.parse import urlparse
from bdd_composer_browser_test import render_template

APP = Path(__file__).resolve().parents[2]
ECAI = APP.parent / 'ecai'
ROOT = APP.parents[1]
TPL = APP/'priv/templates/ui/dashboard'

MOCK = r'''
if(!crypto.randomUUID)crypto.randomUUID=()=>`fixture-${Date.now()}-${Math.random().toString(16).slice(2)}`;
window.__fixture={calls:[],admin:true,mode:'ok',delay:30,ignoreAbort:false,revision:4,
 route:{provider:'ollama',model:'review-fixture'},authenticated:true};
const f=window.__fixture;
const policy={id:'code-review',description:'Read the approved snapshot and produce an evidence-backed review.',
 skills:[{id:'read_source',effect:'read',approval:false},{id:'write_review',effect:'artifact',approval:false}],
 planner:'damage_agent_llm_ollama',verification:{scope:'Artifact integrity; semantic correctness is not established.'},
 limits:{max_iterations:20,max_llm_calls:20,max_wall_seconds:3600},
 accounting:{mode:'aeternity',agent_id:'maintenance-agent',max_cost_units:1000000000}};
f.tasks=[{id:'fixture-review-001',template:'code-review',status:'awaiting_approval',goal:'Review the approved source snapshot.',
 created_at:100,iteration:2,accounting_complete:false,receipt_state:'draft',execution_status:'running',
 budget:{mode:'aeternity',status:'reserved',spent_units:25000000,max_cost_units:1000000000,remaining_units:975000000},
 pending:{hash:'fixture-exact-proposal-hash',skill:'publish_review',args:{artifact:'review.md'},effect:'external_write'}}];
f.events=[{kind:'budget_reserved',data:{}},{kind:'action_succeeded',data:{result:{artifact:{name:'review.md',content:'# Review\n\nInspect the timeout handling before retrying external writes.\n<img src=x onerror="window.__agentInjected=true">'}}}}];
window.fetch=async (url,opts={})=>{
 const path=String(url);if(!path.startsWith('/api/agents/')&&!path.startsWith('/ai/bdd/'))throw Error('Live network disabled in fixture: '+path);
 const body=opts.body ? JSON.parse(opts.body):null,mode=f.mode,ignoreAbort=f.ignoreAbort;
 f.calls.push({path,method:opts.method||'GET',body,headers:opts.headers});
 await new Promise((resolve,reject)=>{const timer=setTimeout(resolve,path.endsWith('/draft')?f.delay:5);
   if(!ignoreAbort){if(opts.signal?.aborted){clearTimeout(timer);reject(new DOMException('Aborted','AbortError'));}
   opts.signal?.addEventListener('abort',()=>{clearTimeout(timer);reject(new DOMException('Aborted','AbortError'));},{once:true});}});
 const respond=(value,status=200)=>new Response(JSON.stringify(value),{status,headers:{'content-type':'application/json'}});
 if(path==='/ai/bdd/routing'){
  if(body){if(mode==='route-stale')return respond({error:'stale_revision'},409);f.route=body.route;f.revision++;return respond({revision:f.revision});}
  return respond({revision:f.revision,route:f.route,can_manage:f.admin,pool_available:true,remote_allowed:false,
   connections:[{id:'local-review',provider:'ollama',default_model:'review-fixture',models:'all'}]});
 }
 if(path==='/ai/bdd/cancel')return respond({cancelled:true});
 if(path==='/api/agents/templates')return respond({templates:[policy]});
 if(path==='/api/agents/draft'||path==='/api/agents/preview'){
  const goal=body.goal || body.user_prompt;
  return respond({template:'code-review',goal,policy,policy_hash:'fixture-policy-v1',
   complete:mode!=='missing',missing_steps:mode==='missing'?['No deployment capability is approved.']:[],assumptions:[],
   validation:{valid:mode!=='invalid',diagnostics:[]},draft_only:true,
   feature:'Feature: Supervised agent task\n  Scenario: Start a reviewed task\n    Given I use agent template "code-review"\n    When I start an agent task named "task" with objective\n      """\n      '+goal+'\n      """\n    Then the agent task "task" should be accepted\n',
   ...(path.endsWith('/draft')?{inference:{provider:'ollama',model:'review-fixture',routing_revision:f.revision}}:{})});
 }
 if(path==='/api/agents/tasks'){
  if(body){if(mode==='start-uncertain')return respond({error:'acceptance_unknown'},503);
   if(mode==='policy-changed')return respond({error:'policy_changed'},409);
   const task={...f.tasks[0],id:'fixture-created-002',goal:body.goal,status:'planning',pending:null};
   f.tasks=f.tasks.filter(t=>t.id!==task.id).concat([task]);return respond(task,202);}
  return respond({tasks:f.tasks});
 }
 if(path.endsWith('/events'))return respond({events:f.events});
 if(path.endsWith('/command'))return respond({accepted:true});
 if(path.endsWith('/learning'))return respond({schema:'damage.agent.experience.v1',training_eligible:false});
 return respond(f.tasks.find(t=>path.endsWith('/'+t.id)) || f.tasks[0]);
};
'''


def page(host):
    route=(TPL/'bdd_routing.mustache').read_text()
    agent=(TPL/'agents_tab.mustache').read_text().replace('{{{bdd_routing}}}',route)
    ctx={'authenticated':True,'node_admin':True,'tax_admin':True,'node_version':'fixture',
         'brand_name':'DamageBDD' if host=='damage' else 'ECAI','brand_tagline':'Verified knowledge & automation','bdd_routing':route,
         'agents_panel':agent,'agents_tab':agent,'logo_image':'/static/img/logo.png'}
    if host=='damage':
        shell=(TPL/'page_shell.mustache').read_text()
        ctx['footer']=render_template((TPL/'footer.mustache').read_text(),ctx)
        ctx['sidebar']=render_template((TPL/'sidebar.mustache').read_text(),ctx)
        names={'swaps_tab':'swap_options_tab','node_cln_admin_tab':'node_cln_admin','node_public_key_modal':'node_details_modal'}
        for key in re.findall(r'{{{(\w+)}}}',shell):
            if key not in ctx:
                p=TPL/(names.get(key,key)+'.mustache')
                ctx[key]=render_template(p.read_text(),ctx) if p.exists() else ''
    else:
        shell=(ECAI/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
        for key,name in {'market_maker_panel':'ecai_market_maker','math_paths_panel':'ecai_math_paths',
                         'evaluation_panel':'ecai_eval','personalities_panel':'ecai_personalities',
                         'compute_settings_panel':'compute_settings','ollama_keys_panel':'ollama_keys'}.items():
            ctx[key]=(ECAI/f'priv/templates/ui/dashboard/{name}.mustache').read_text()
    doc=render_template(shell,ctx)
    doc=re.sub(r'<script\b[^>]*>.*?</script>','',doc,flags=re.S|re.I)
    doc=re.sub(r'<link\b[^>]*href=["\']/api/themes/css[^>]*>','',doc)
    doc=doc.replace('/static/',f'/fixture/{host}/static/')
    doc=doc.replace('/ecai/auth-assets/','/fixture/damage/static/').replace('/ecai/agent-assets/','/fixture/damage/static/')
    # The host's stylesheet, with the same semantic tokens, supplies appearance.
    def asset(match):
        path=urlparse(match[1]).path
        if not path.startswith('/fixture/'):return ''
        _,_,app,_,relative=path.split('/',4)
        base=(APP if app=='damage' else ECAI)/'priv/static'
        css=(base/relative).read_text()
        return '<style>'+css+'</style>'
    doc=re.sub(r'<link\b[^>]*href=["\']([^"\']+)["\'][^>]*>',asset,doc)
    logo='data:image/png;base64,'+base64.b64encode((APP/'priv/static/img/logo.png').read_bytes()).decode()
    doc=doc.replace('/fixture/damage/static/img/logo.png',logo)
    doc=re.sub(r'<body([^>]*)>', r'<body\1><div style="padding:8px;text-align:center;font:11px system-ui;background:#182335;color:#d9e4f4">BROWSER FIXTURE · Simulated tasks and API responses · No model, wallet or chain calls</div>',doc,count=1)
    script=inline_bridge(host).replace('</script','<\\/script')
    return doc.replace('</body>',f'<script type="module">{script}</script></body>')


def bridge(host):
    common="""
import {mountAgentWorkspace,workspaceRequest} from '/fixture/damage/static/js/agent-workspace.js';
import {initDashboardNavigation} from '/fixture/damage/static/js/dashboard-navigation.js';
"""+MOCK+"""
const workspace=mountAgentWorkspace(document.querySelector('[data-agent-workspace]'),{
 request:workspaceRequest(()=>({Authorization:'Bearer fixture-private-session'})),canUse:()=>f.authenticated,intervalMs:140});
window.workspace=workspace;
window.__reset=()=>{f.authenticated=false;workspace.reset();};
"""
    if host=='damage':
        return common+"""
document.addEventListener('damage:panelchange',e=>void workspace.setVisible(e.detail.id==='agents-tab'));
window.__navigate=id=>window.nav.navigate(id==='agents'?'agents-tab':'execution-tab');
window.nav=initDashboardNavigation();window.__navigate('agents');window.__ready=true;
"""
    console=(ECAI/'priv/static/js/ecai-console.js').read_text()
    navigation='function navigate(view) {'+console.split('  function navigate(view) {',1)[1].split('  function closeNav()',1)[0]
    return common+"""
const state={view:'overview'},VIEW_NAMES={agents:'Agents',overview:'Overview'};
const $=id=>document.getElementById(id),put=(id,value)=>{$(id).textContent=value;};
const agentWorkspace=workspace,bddRouting=null,modelInternals=null,llmSettings=null,mathPaths=null,
 mathKernel=null,math3D=null,evaluation=null,personalities=null,videoStudio=null,marketMaker=null,knowledgeSearch={setVisible(){}};
const location={hash:''},history={replaceState(a,b,hash){location.hash=hash;}};
const closeNav=()=>{},stopStream=()=>{},toast=()=>{},showError=()=>'',refreshView=async()=>{};
"""+navigation+"""
window.__navigate=navigate;document.querySelector('#consoleNav').addEventListener('click',e=>{const el=e.target.closest('[data-view]');if(el)navigate(el.dataset.view);});
navigate('agents');window.__ready=true;
"""


def module_url(source):
    return 'data:text/javascript;base64,'+base64.b64encode(source.encode()).decode()

def inline_bridge(host):
    js=APP/'priv/static/js'
    tasks=module_url((js/'agent-tasks.js').read_text())
    routing=module_url((js/'bdd-routing.js').read_text())
    workspace=(js/'agent-workspace.js').read_text().replace("'./agent-tasks.js'",json.dumps(tasks)).replace("'./bdd-routing.js'",json.dumps(routing))
    return bridge(host).replace("'/fixture/damage/static/js/agent-workspace.js'", json.dumps(module_url(workspace))).replace("'/fixture/damage/static/js/dashboard-navigation.js'",json.dumps(module_url((js/'dashboard-navigation.js').read_text())))


def run(out,chromium):
    from playwright.sync_api import sync_playwright
    out.mkdir(parents=True,exist_ok=True)
    checks=[]
    with sync_playwright() as p:
        browser=p.chromium.launch(executable_path=chromium,headless=True,args=['--no-sandbox'])
        for host in ('damage','ecai'):
            pg=browser.new_page(viewport={'width':1440,'height':1150},reduced_motion='reduce')
            pg.set_default_timeout(6000);errors=[];pg.on('pageerror',lambda e:errors.append(str(e)));pg.on('dialog',lambda d:d.accept())
            def ok(label):checks.append(host+': '+label);print('PASS',checks[-1],flush=True)
            a=lambda n:pg.locator(f'[data-agent="{n}"]')
            root=pg.locator('[data-agent-workspace]')
            def calls(path,method=None):return pg.evaluate('([p,m])=>__fixture.calls.filter(c=>c.path===p&&(!m||c.method===m))',[path,method])
            def draft(mode='ok'):
                pg.evaluate('(m)=>__fixture.mode=m',mode)
                root.locator('[data-agent-example="review"]').click();a('generate').click();a('cancel-draft').wait_for(state='hidden')
            pg.set_content(page(host),wait_until='load')
            pg.wait_for_function('window.__ready===true');pg.wait_for_function("document.querySelector('[data-agent=compose]').elements.template.options.length===2")
            assert root.is_visible();assert a('generate').is_disabled();ok('real host markup/navigation mounts shared panel')
            draft();assert len(calls('/api/agents/tasks','POST'))==0
            assert a('start').is_disabled();assert a('feature').inner_text().startswith('Feature:')
            a('reviewed').check();assert a('start').is_enabled();ok('draft never starts a task; explicit review is required')
            a('goal').fill('Review the selected snapshot and explain every confirmed issue.')
            assert a('start').is_disabled();assert a('download').is_disabled()
            a('recheck').click();pg.wait_for_function("!document.querySelector('[data-agent=reviewed]').disabled")
            a('reviewed').check();assert a('start').is_enabled();ok('editing invalidates consent and requires fresh policy preview')
            pg.evaluate("__fixture.mode='policy-changed'");a('start').click()
            pg.wait_for_function("document.querySelector('[data-agent=message]').textContent.includes('policy changed')")
            assert a('start').is_disabled();pg.evaluate("__fixture.mode='ok'")
            a('recheck').click();pg.wait_for_function("!document.querySelector('[data-agent=reviewed]').disabled")
            a('reviewed').check();ok('stale policy cannot launch; a new review is required')
            pg.evaluate("__fixture.mode='start-uncertain'");a('start').click()
            pg.wait_for_function("document.querySelector('[data-agent=message]').textContent.includes('No acceptance confirmed')")
            before=calls('/api/agents/tasks','POST')[-1]
            pg.evaluate("__fixture.mode='ok'");a('start').click()
            pg.wait_for_function("document.querySelector('[data-agent=detail-title]').textContent.includes('planning')")
            after=calls('/api/agents/tasks','POST')[-1]
            assert before['headers']['idempotency-key']==after['headers']['idempotency-key']
            assert set(after['body'])=={'template','goal','policy_hash'};ok('uncertain creation retry keeps key and sends no monetary permissions')
            a('tasks').get_by_role('button',name=re.compile('awaiting approval')).click()
            a('controls').get_by_role('button',name='Approve exact proposal').wait_for()
            a('controls').get_by_role('button',name='Approve exact proposal').click()
            pg.wait_for_function("__fixture.calls.some(c=>c.path.endsWith('/command'))")
            command=calls('/api/agents/tasks/fixture-review-001/command')[-1]['body']
            assert command['proposal_hash']=='fixture-exact-proposal-hash';assert command['command']=='approve'
            assert not pg.evaluate('window.__agentInjected===true');ok('approval is bound to displayed proposal; output remains literal text')
            pg.evaluate("__fixture.tasks[0].status='accounting_pending';__fixture.tasks[0].budget.status='settlement_pending'")
            a('refresh').click();a('controls').get_by_role('button',name='Reconcile accounting').wait_for()
            assert a('controls').get_by_role('button',name='Cancel task').count()==0
            assert a('controls').get_by_role('button',name='Approve exact proposal').count()==0
            ok('uncertain accounting exposes reconciliation, not execution or cancellation')
            routing=root.locator('[data-bdd-routing]');routing.locator('summary').click()
            routing.locator('select[name=provider]').select_option('anthropic');routing.locator('input[name=model]').fill('review-model')
            routing.locator('[data-route=save]').click()
            pg.wait_for_function('__fixture.revision===5')
            pg.wait_for_function("document.querySelector('[data-agent-workspace] [data-route=summary]').textContent.includes('r5')")
            update=calls('/ai/bdd/routing','POST')[-1]['body'];assert set(update)=={'route','revision'}
            assert set(update['route'])=={'model','provider'};ok('authoring preference updates revision without keys, URL or role grants')
            pg.evaluate("__fixture.mode='route-stale'");routing.locator('input[name=model]').fill('new-model');routing.locator('[data-route=save]').click()
            routing.locator('[data-route=status]').get_by_text(re.compile('Settings changed elsewhere')).wait_for()
            assert pg.evaluate('__fixture.route.model')=='review-model';ok('stale provider editor cannot silently overwrite a newer route')
            pg.evaluate("__fixture.mode='ok';__fixture.admin=false");routing.locator('[data-route=refresh]').click()
            pg.wait_for_function("document.querySelector('[data-agent-workspace] [data-route=fields]').disabled")
            ok('non-admin sees routing but cannot edit it')
            routing.locator('summary').click();pg.evaluate("window.scrollTo(0,0)")
            pg.screenshot(path=str(out/f'{host}-agents-desktop.png'),full_page=True)
            for width in (320,390,768,1440):
                pg.set_viewport_size({'width':width,'height':1100})
                assert pg.evaluate('document.documentElement.scrollWidth <= innerWidth+1'),(host,width)
            pg.set_viewport_size({'width':390,'height':1000});pg.screenshot(path=str(out/f'{host}-agents-mobile.png'),full_page=True)
            ok('no horizontal document overflow at 320, 390, 768 and 1440px')
            pg.set_viewport_size({'width':1440,'height':1150})
            pg.evaluate("__navigate('overview')");pg.wait_for_timeout(200)
            n=len(calls('/api/agents/tasks'));pg.wait_for_timeout(350);assert len(calls('/api/agents/tasks'))==n
            pg.evaluate("__navigate('agents')");pg.wait_for_function("document.querySelector('[data-agent=compose]').elements.template.options.length===2")
            ok('hidden panel stops polling; returning retains the mounted workflow')
            draft('missing');a('reviewed').check();assert a('start').is_disabled()
            a('recheck').click();pg.wait_for_function("!document.querySelector('[data-agent=recheck]').disabled")
            a('reviewed').check();assert a('start').is_disabled();ok('unsupported requirements survive unchanged recheck and block start')
            draft('invalid');assert a('start').is_disabled();assert a('reviewed').is_disabled();ok('invalid signature result cannot be accepted')
            pg.evaluate("Object.assign(__fixture,{mode:'ok',delay:700,ignoreAbort:true})")
            a('generate').click();pg.wait_for_function("!document.querySelector('[data-agent=cancel-draft]').hidden")
            a('cancel-draft').click();a('cancel-draft').wait_for(state='hidden');pg.wait_for_timeout(850)
            assert 'cancelled' in a('message').inner_text().lower();assert a('start').is_disabled()
            ok('cancellation owns cleanup and rejects a late generation response')
            a('generate').click();pg.wait_for_function("!document.querySelector('[data-agent=cancel-draft]').hidden")
            pg.evaluate('__reset()');pg.wait_for_timeout(850)
            assert a('goal').input_value()=='';assert a('review').is_hidden();assert a('detail-section').is_hidden()
            assert a('detail').inner_text()=='';ok('identity reset erases private state and rejects delayed replies')
            pg.evaluate("Object.assign(__fixture,{authenticated:true,admin:true,delay:30,ignoreAbort:false});workspace.accessChanged()")
            pg.wait_for_function("!document.querySelector('[data-agent-workspace] [data-route=fields]').disabled")
            if not routing.evaluate('(el)=>el.open'):routing.locator('summary').click()
            previous=pg.evaluate('__fixture.revision')
            routing.locator('input[name=model]').fill('after-account-change')
            routing.locator('[data-route=save]').click()
            pg.wait_for_function('(r)=>__fixture.revision===r+1',arg=previous)
            assert pg.evaluate('__fixture.route.model')=='after-account-change'
            ok('provider controls remain usable after account reset; request cancellation does not remove listeners')
            assert not errors,errors;ok('no browser JavaScript exceptions')
            pg.close()
        browser.close()
    (out/'results.json').write_text(json.dumps({'scope':'simulated APIs; actual component + dashboard markup/navigation','checks':checks},indent=2))
    print(f'{len(checks)} browser checks passed.')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('/tmp/agent-workspace-ui'));p.add_argument('--chromium',default='/usr/bin/chromium');a=p.parse_args();run(a.out,a.chromium)
