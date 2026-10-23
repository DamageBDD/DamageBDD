"""Isolated Chromium coverage of the production Model Internals component.

python3 apps/ecai/test/test_model_internals_browser.py
Requires playwright and Chromium (CHROMIUM_PATH can override its location).
Transport/admin identity are simulated: this is not a Cowboy authentication test.
No external network requests or model calls are made.
"""
import asyncio
import base64
import json
import os
from pathlib import Path
from playwright.async_api import async_playwright

APP = Path(__file__).resolve().parents[1]
DEFAULT = {"enabled": False, "roles": ["patch"], "system_suffix": "", "patch_json_schema": False,
           "ollama": {k: None for k in ["temperature", "top_p", "top_k", "min_p", "seed", "repeat_penalty", "num_ctx", "max_output_tokens"]},
           "openai": {"temperature": None, "max_output_tokens": None}}
MOCK = r'''
window.__admin = true; window.__calls = []; window.__conflict = false;
window.__defer = false; window.__deferred = null; window.__deny = false;
window.confirm = () => true;
window.__snapshot = {config: DEFAULT, revision: 0, config_sha256: 'a'.repeat(64), updated_at: null,
  changes: [], observations: [], pool: {state:'available',nodes:[{id:'lan-ollama',provider:'ollama',
  default_model:'configured-code-model',health:'healthy',roles:['patch','learning'],inflight:0,max_inflight:2}]},
  capabilities: [
    {id:'system',title:'System guidance',state:'wired',note:'Append bounded operator guidance; existing system instructions are preserved.'},
    {id:'sampling',title:'Sampling & token budgets',state:'wired',note:'Validated provider-specific generation overrides.'},
    {id:'schema',title:'Constrained patch JSON',state:'wired',note:'Shape constraints do not validate code or bypass tests.'},
    {id:'provenance',title:'Policy provenance',state:'wired',note:'Policy revisions accompany inference and repair metadata.'},
    {id:'logits',title:'Custom token logits',state:'bridge_required',note:'Requires a separate compatible inference runtime.'},
    {id:'activations',title:'Activation & attention hooks',state:'bridge_required',note:'No hidden-state or executable hook is loaded by this page.'},
    {id:'adapters',title:'LoRA & weight adapters',state:'bridge_required',note:'No executable model artifacts are accepted.'},
    {id:'cache',title:'KV cache & soft prompts',state:'bridge_required',note:'No shared tenant state or embedding injection is exposed.'}
  ]};
window.__request = async (path, opts={}) => {
  window.__calls.push({path,opts});
  if (window.__deny) throw Object.assign(new Error('Forbidden'), {status:403});
  if (path.endsWith('/preview')) return {ok:true,model_internals:{active:opts.body.config.enabled,options:{seed:opts.body.config.ollama.seed},notice:'No inference'}};
  if (path.endsWith('/update')) {
    if (window.__conflict || opts.body.revision !== window.__snapshot.revision)
      throw Object.assign(new Error('Conflict'),{status:409,body:{error:'stale_revision'}});
    window.__snapshot={...window.__snapshot,config:opts.body.config,revision:window.__snapshot.revision+1,
      updated_at:'2026-10-19T10:00:00Z',changes:[{revision:window.__snapshot.revision+1,actor:'node-admin',at:'2026-10-19T10:00:00Z'}]};
    return {ok:true,model_internals:structuredClone(window.__snapshot)};
  }
  if (window.__defer) return new Promise(resolve=>{window.__deferred=()=>resolve({ok:true,model_internals:structuredClone(window.__snapshot)});});
  return {ok:true,model_internals:structuredClone(window.__snapshot)};
};
'''

def markup():
    template = (APP / 'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
    a = template.index('        <section class="view" data-panel="code"')
    b = template.index('        <section class="view" data-panel="network"', a)
    panel = template[a:b]
    css = (APP/'priv/static/css/ecai-console.css').read_text() + (APP/'priv/static/css/ecai-model-internals.css').read_text()
    src = (APP/'priv/static/js/ecai-model-internals.js').read_text()
    url = 'data:text/javascript;base64,' + base64.b64encode(src.encode()).decode()
    script = MOCK.replace('DEFAULT', json.dumps(DEFAULT)) + '''
      document.querySelector('[data-panel="code"]').hidden=false;
      document.querySelector('[data-panel="code"]').classList.add('is-visible');
      document.getElementById('codePipelinePanel').hidden=true;
      document.getElementById('modelInternalsPanel').hidden=false;
      document.getElementById('codePipelineTab').setAttribute('aria-selected','false');
      document.getElementById('codeModelInternalsTab').setAttribute('aria-selected','true');
      window.mi=initModelInternals({request:window.__request,canManage:()=>window.__admin});
      window.mi.setVisible(true); window.mi.refresh();
    '''
    return f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>{css}</style></head>
    <body><main class="console-main" style="max-width:1280px;margin:auto">{panel}</main>
    <script type="module">import {{initModelInternals}} from {json.dumps(url)}; {script}</script></body></html>'''

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH', '/usr/bin/chromium'),
                                         headless=True, args=['--no-sandbox', '--disable-dev-shm-usage'])
        page = await browser.new_page(viewport={'width':1440,'height':1100})
        errors=[]
        page.on('pageerror', lambda e: errors.append(str(e)))
        await page.set_content(markup())
        await page.wait_for_function("document.getElementById('miRevision').textContent==='r0'")
        assert await page.locator('.mi-capability[data-state="wired"]').count() == 4
        assert await page.locator('.mi-capability[data-state="bridge_required"]').count() == 4
        assert await page.locator('#miSave').is_disabled()
        assert await page.locator('#miEnabled').is_enabled()
        await page.locator('#miEnabled').check()
        await page.locator('#miSeed').fill('42')
        await page.locator('#miTemperature').fill('0')
        await page.locator('#miPatchSchema').check()
        assert await page.locator('#miSave').is_enabled()
        await page.locator('#miPreview').click()
        await page.wait_for_function("document.getElementById('miPreviewOutput').textContent.includes('42')")
        assert await page.evaluate("__snapshot.revision") == 0
        assert await page.evaluate("__calls.filter(c=>c.path.endsWith('/update')).length") == 0
        # Poll/refresh must not clobber an unsaved draft.
        await page.locator('#miRefresh').click()
        assert await page.locator('#miSeed').input_value() == '42'
        assert 'Unsaved' in await page.locator('#miDraftState').inner_text()
        await page.locator('#miSave').click()
        await page.wait_for_function("document.getElementById('miRevision').textContent==='r1'")
        assert await page.evaluate("__snapshot.config.ollama.seed") == 42
        assert await page.evaluate("__calls.find(c=>c.path.endsWith('/update')).opts.body.revision") == 0
        assert await page.locator('#miSave').is_disabled()
        # Stale updates preserve edits and their original expected revision.
        await page.locator('#miSeed').fill('43')
        await page.evaluate("__snapshot.revision=2; __conflict=true")
        await page.locator('#miSave').click()
        await page.wait_for_function("document.getElementById('miNotice').textContent.includes('Another administrator')")
        assert await page.locator('#miSeed').input_value() == '43'
        await page.locator('#miRefresh').click()
        assert 'based on r1' in await page.locator('#miDraftState').inner_text()
        await page.locator('#miDiscard').click()
        assert await page.locator('#miSeed').input_value() == '42'
        assert 'r2' in await page.locator('#miDraftState').inner_text()
        # Injected server strings are always text, never executable markup.
        await page.evaluate("__snapshot.pool.nodes[0].id='<img src=x onerror=window.__xss=true>'; __snapshot.capabilities[0].title='<script>bad</script>'")
        await page.locator('#miRefresh').click()
        assert await page.locator('#miNodes img').count() == 0
        assert await page.locator('#miCapabilities script').count() == 0
        assert not await page.evaluate("Boolean(window.__xss)")
        # Validation prevents a provider request for overlong Unicode guidance.
        await page.locator('#miSystemSuffix').fill('é'*1200)
        before = await page.evaluate("__calls.length")
        await page.locator('#miPreview').click()
        assert await page.evaluate("__calls.length") == before
        assert '2,048' in await page.locator('#miNotice').inner_text()
        await page.locator('#miDiscard').click()
        await page.evaluate("__snapshot.pool.nodes[0].id='lan-ollama'; __snapshot.capabilities[0].title='System guidance'; __conflict=false")
        await page.locator('#miRefresh').click()
        screenshots = Path(os.environ.get('ECAI_SCREENSHOT_DIR', '/tmp'))
        screenshots.mkdir(parents=True, exist_ok=True)
        await page.screenshot(path=str(screenshots/'ecai-model-internals-desktop.png'),full_page=True)
        await page.set_viewport_size({'width':390,'height':844})
        await page.screenshot(path=str(screenshots/'ecai-model-internals-mobile.png'),full_page=True)
        assert await page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        # A delayed response from the old identity must not restore admin data.
        await page.evaluate("__defer=true; void mi.refresh()")
        await page.wait_for_function("!!__deferred")
        await page.evaluate("__admin=false; mi.reset(); __deferred()")
        await page.wait_for_timeout(100)
        assert await page.locator('#miEnabled').is_disabled()
        assert await page.locator('#miRevision').inner_text() == '—'
        assert await page.locator('#miConfigHash').inner_text() == '—'
        assert await page.locator('#miNodes').inner_text() == ''
        # Losing server authorization also clears data, even with an admin UI hint.
        await page.evaluate("__admin=true; __defer=false; __deny=true; mi.refresh()")
        await page.wait_for_function("document.getElementById('miNotice').textContent.includes('server-authorized')")
        assert await page.locator('#miEnabled').is_disabled()
        # Exercise the actual shell navigation and tab keyboard handlers with
        # unrelated workspaces stubbed out; no external auth bundle is needed.
        console = (APP/'priv/static/js/ecai-console.js').read_text()
        navigation = 'function navigate(view) {' + console.split('  function navigate(view) {',1)[1].split('  function closeNav()',1)[0]
        start = console.index('    const codeTabs = [...document.querySelectorAll("[data-code-section]")];')
        bindings = console[start:console.index('    initAuthUI();',start)]
        await page.evaluate("""() => {
          const shell=document.createElement('div');shell.id='ecaiConsole';document.body.append(shell);
          const crumb=document.createElement('span');crumb.id='viewBreadcrumb';document.body.append(crumb);
        }""")
        harness = """() => {
          const state={view:'overview'}, VIEW_NAMES={code:'Code learning & repair',overview:'Overview'};
          const $=id=>document.getElementById(id), put=(id,value)=>{$(id).textContent=value;};
          const modelInternals=window.mi, mathPaths=null, evaluation=null, personalities=null,
                videoStudio=null, marketMaker=null, llmSettings=null, knowledgeSearch={setVisible(){}};
          const location={hash:''}, history={replaceState(a,b,hash){location.hash=hash;}};
          const closeNav=()=>{}, stopStream=()=>{}, refreshView=async()=>{}, toast=()=>{}, showError=()=>'';
          NAVIGATION
          BINDINGS
          window.__navigate=navigate;
          window.__navState=()=>({view:state.view,section:state.codeSection,hash:location.hash});
          navigate('code/model-internals');
        }""".replace('NAVIGATION',navigation).replace('BINDINGS',bindings)
        await page.evaluate(harness)
        assert await page.evaluate('__navState()') == {'view':'code','section':'model-internals','hash':'#code/model-internals'}
        assert await page.locator('#codePipelinePanel').is_hidden()
        assert await page.locator('#modelInternalsPanel').is_visible()
        await page.locator('#codeModelInternalsTab').focus()
        await page.keyboard.press('ArrowLeft')
        assert await page.locator('#codePipelinePanel').is_visible()
        assert await page.locator('#modelInternalsPanel').is_hidden()
        assert await page.locator('#codePipelineTab').get_attribute('aria-selected') == 'true'
        await page.keyboard.press('End')
        assert await page.locator('#modelInternalsPanel').is_visible()
        assert await page.locator('#codeModelInternalsTab').get_attribute('aria-selected') == 'true'
        assert not errors, errors
        await browser.close()
        print('PASS: capabilities, controls, preview, save, conflicts, draft preservation, XSS, UTF-8 bounds, mobile layout, identity races, authorization loss, deep linking and keyboard tabs')

if __name__ == '__main__':
    asyncio.run(main())
