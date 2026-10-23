"""Production provider-settings component under Chromium with a simulated API.
No external requests, actual provider calls, or server authorization tests.
Run: python3 apps/ecai/test/test_llm_settings_browser.py
"""
import asyncio
import base64
import json
import os
from pathlib import Path
from playwright.async_api import async_playwright

APP = Path(__file__).resolve().parents[1]
CONNECTION = dict(id='local-inference', provider='ollama', enabled=True,
    host='127.0.0.1', port=11434, transport='tcp', default_model='installed-code-model',
    models='all', roles=['learning','audit','patch','synthesis'], weight=2, max_inflight=1,
    timeout_ms=180000, connect_timeout_ms=5000, max_output_tokens=4096, temperature=None,
    auth_type='inherited', credential_ref='')
CONFIG = dict(connections=[CONNECTION], runtime=dict(health_interval_ms=30000,
    health_timeout_ms=5000, failure_threshold=2, queue_timeout_ms=300000, cluster_attempts=3),
    remote_roles=[], route_chat=False)
MOCK = r'''
window.__admin=true; window.__calls=[]; window.__conflict=false; window.__deny=false;
window.__defer=false; window.__deferred=null; window.confirm=()=>true;
window.__snapshot={revision:0,source:'deployment',config:CONFIG,
 pool:{available:true,revision:0,nodes:[{id:'local-inference',health:'healthy'}]},
 damage_profiles:[{name:'Existing OpenAI profile',shared_registry:false},{name:'ECAI text tasks',shared_registry:true}]};
window.__request=async(path,opts={})=>{
 window.__calls.push({path,opts:structuredClone(opts)});
 if(__deny) throw Object.assign(new Error('Forbidden'),{status:403});
 if(path.endsWith('/probe')) return {ok:true,probe:{models:['installed-code-model','provider-text-model'],elapsed_ms:22,generation_tested:false}};
 if(path.endsWith('/update')) {
  if(__conflict || opts.body.revision !== __snapshot.revision)
   throw Object.assign(new Error('Conflict'),{status:409,body:{error:'stale_revision'}});
  const config=structuredClone(opts.body.config);
  config.connections.forEach(c=>{if(c.api_key){delete c.api_key;c.auth_type='vault';c.credential_ref='ecai-llm/'+c.id+'/'+'a'.repeat(32);}});
  __snapshot={...__snapshot,config,revision:__snapshot.revision+1,source:'dashboard',pool:{...__snapshot.pool,revision:__snapshot.revision+1}};
  return {ok:true,llm_settings:structuredClone(__snapshot)};
 }
 if(__defer) return new Promise(resolve=>{__deferred=()=>resolve({ok:true,llm_settings:structuredClone(__snapshot)});});
 return {ok:true,llm_settings:structuredClone(__snapshot)};
};
'''

def markup():
    html=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
    start=html.index('        <section class="view llm-settings"')
    end=html.index('        <section class="view settings-workspace"', start)
    panel=html[start:end]
    css=(APP/'priv/static/css/ecai-console.css').read_text()+(APP/'priv/static/css/ecai-llm-settings.css').read_text()
    js=(APP/'priv/static/js/ecai-llm-settings.js').read_text()
    url='data:text/javascript;base64,'+base64.b64encode(js.encode()).decode()
    script=MOCK.replace('CONFIG', json.dumps(CONFIG)) + '''
      const panel=document.querySelector('[data-panel="ai-providers"]');panel.hidden=false;panel.classList.add('is-visible');
      window.settings=initLlmSettings({request:__request,canManage:()=>__admin});
      settings.setVisible(true); settings.refresh();
    '''
    return f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>{css}</style></head>
    <body><main class="console-main" style="max-width:1280px;margin:auto">{panel}</main>
    <script type="module">import {{initLlmSettings}} from {json.dumps(url)}; {script}</script></body></html>'''

async def main():
    async with async_playwright() as p:
        browser=await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH','/usr/bin/chromium'),headless=True,args=['--no-sandbox','--disable-dev-shm-usage'])
        page=await browser.new_page(viewport={'width':1440,'height':1050})
        errors=[]; page.on('pageerror',lambda e:errors.append(str(e)))
        await page.set_content(markup())
        await page.wait_for_function("document.getElementById('llmRevision').textContent==='r0'")
        assert await page.locator('#llmSave').is_disabled()
        assert await page.locator('#llmId').get_attribute('readonly') is not None
        assert await page.locator('#llmProbe').is_enabled()
        await page.locator('#llmProbe').click()
        await page.wait_for_function("document.getElementById('llmProbeResult').textContent.includes('2 model(s)')")
        assert await page.locator('#llmDiscoveredModels option').count()==2
        assert await page.evaluate('__calls.at(-1).opts.body')=={'revision':0,'id':'local-inference'}
        # New Claude destination: save disabled first, then discover a model.
        await page.locator('#llmAddProvider').select_option('anthropic')
        await page.locator('#llmAdd').click()
        assert await page.locator('#llmHost').input_value()=='api.anthropic.com'
        assert not await page.locator('#llmEnabled').is_checked()
        assert await page.locator('#llmModel').input_value()==''
        await page.locator('#llmSave').click()
        await page.wait_for_function("document.getElementById('llmRevision').textContent==='r1'")
        assert await page.evaluate('__snapshot.config.connections[1].enabled') is False
        await page.locator('#llmProbe').click()
        await page.wait_for_function("document.getElementById('llmDiscoveredModels').children.length===2")
        await page.locator('#llmModel').fill('provider-text-model')
        await page.locator('#llmEnabled').check()
        await page.get_by_role('checkbox',name='anthropic-1: Audit',exact=True).check()
        await page.locator('#llmRemoteRoles').get_by_role('checkbox',name='Audit',exact=True).check()
        await page.locator('#llmApiKey').fill('test-key-never-return-this-000001')
        await page.locator('#llmSave').click()
        await page.wait_for_function("document.getElementById('llmRevision').textContent==='r2'")
        assert await page.locator('#llmApiKey').input_value()==''
        assert await page.locator('#llmAuthType').input_value()=='vault'
        assert await page.evaluate('__snapshot.config.connections[1].roles')==['audit']
        assert await page.evaluate('__snapshot.config.remote_roles')==['audit']
        assert 'test-key-never' not in await page.locator('body').inner_text()
        assert 'api_key' not in await page.evaluate('JSON.stringify(__snapshot)')
        # Refresh does not overwrite a dirty draft. A conflict clears its secret.
        await page.locator('#llmModel').fill('edited-model')
        await page.locator('#llmApiKey').fill('test-key-conflict-000002')
        await page.locator('#llmRefresh').click()
        await page.wait_for_function("!document.getElementById('llmRefresh').disabled")
        assert await page.locator('#llmModel').input_value()=='edited-model'
        await page.evaluate('__conflict=true;__snapshot.revision=3;__snapshot.pool.revision=3')
        await page.locator('#llmSave').click()
        await page.wait_for_function("document.getElementById('llmNotice').textContent.includes('Another administrator')")
        assert await page.locator('#llmApiKey').input_value()==''
        assert await page.locator('#llmModel').input_value()=='edited-model'
        # Navigating away also clears keys in the detached draft.
        await page.locator('#llmApiKey').fill('test-key-navigation-000003')
        await page.evaluate('settings.setVisible(false);settings.setVisible(true);__conflict=false;__snapshot.revision=2;__snapshot.pool.revision=2')
        await page.locator('#llmSave').click()
        await page.wait_for_function("document.getElementById('llmRevision').textContent==='r3'")
        assert await page.evaluate("__calls.filter(c=>c.path.endsWith('/update')).at(-1).opts.body.config.connections.every(c=>!('api_key' in c))")
        # Hostile metadata remains inert text.
        await page.evaluate("__snapshot.damage_profiles[0].name='<img src=x onerror=window.__xss=true>';settings.refresh()")
        await page.wait_for_function("document.getElementById('llmDamageProfiles').textContent.includes('<img')")
        assert await page.locator('#llmDamageProfiles img').count()==0
        assert not await page.evaluate('Boolean(window.__xss)')
        await page.evaluate("__snapshot.damage_profiles[0].name='Existing OpenAI profile';settings.refresh()")
        await page.wait_for_function("!document.getElementById('llmRefresh').disabled")
        shots=Path(os.environ.get('ECAI_SCREENSHOT_DIR','/tmp'));shots.mkdir(parents=True,exist_ok=True)
        await page.screenshot(path=str(shots/'ecai-llm-settings-desktop.png'),full_page=True)
        await page.set_viewport_size({'width':390,'height':844})
        await page.screenshot(path=str(shots/'ecai-llm-settings-mobile.png'),full_page=True)
        assert await page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
        # Stale GET after an identity change cannot restore privileged contents.
        await page.evaluate('__defer=true;void settings.refresh()')
        await page.wait_for_function('Boolean(__deferred)')
        await page.evaluate('__admin=false;settings.reset();__deferred()')
        await page.wait_for_timeout(100)
        assert await page.locator('#llmSave').is_disabled()
        assert await page.locator('#llmConnectionList').inner_text()==''
        await page.evaluate('__admin=true;__defer=false;__deny=true;void settings.refresh()')
        await page.wait_for_function("document.getElementById('llmNotice').textContent.includes('administrator')")
        assert await page.locator('#llmSave').is_disabled()
        # Exercise the production shell's navigation function with unrelated
        # workspaces stubbed. The source function, not a reimplementation, runs.
        console=(APP/'priv/static/js/ecai-console.js').read_text()
        nav='function navigate(view) {'+console.split('  function navigate(view) {',1)[1].split('  function closeNav()',1)[0]
        await page.evaluate("""() => {
          for (const id of ['ecaiConsole','viewBreadcrumb','codePipelinePanel','modelInternalsPanel']) {
            const x=document.createElement('div');x.id=id;document.body.append(x);
          }
          __deny=false;__admin=true;
        }""")
        harness="""() => {
          const state={view:'overview'}, VIEW_NAMES={'ai-providers':'AI providers & roles',overview:'Overview'};
          const $=id=>document.getElementById(id),put=(id,v)=>{$(id).textContent=v;};
          const llmSettings=window.settings,modelInternals=null,mathPaths=null,evaluation=null,
            personalities=null,videoStudio=null,marketMaker=null,knowledgeSearch={setVisible(){}};
          const location={hash:''}, history={replaceState(a,b,hash){location.hash=hash;}};
          const closeNav=()=>{},stopStream=()=>{},toast=()=>{},showError=()=>'',refreshView=()=>settings.refresh();
          NAVIGATION
          window.__navigate=navigate;window.__navState=()=>({view:state.view,hash:location.hash});
          navigate('ai-providers');
        }""".replace('NAVIGATION',nav)
        await page.evaluate(harness)
        await page.wait_for_function("document.getElementById('llmRevision').textContent==='r3'")
        assert await page.evaluate('__navState()')=={'view':'ai-providers','hash':'#ai-providers'}
        await page.locator('#llmApiKey').fill('test-key-shell-navigation-000004')
        await page.evaluate("__navigate('overview')")
        assert await page.locator('#llmApiKey').input_value()==''
        assert await page.locator('[data-panel="ai-providers"]').is_hidden()
        assert not errors,errors
        await browser.close()
        print('PASS: inherited configuration, saved-only discovery, disabled onboarding, Claude roles, remote consent, write-only credentials, save/apply, draft preservation, stale conflicts, navigation clearing, XSS, desktop/mobile, identity race, denied access and production shell navigation (simulated API).')

if __name__=='__main__': asyncio.run(main())
