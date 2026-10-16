#!/usr/bin/env python3
"""Public sample UI and exact browser experiments, with synthetic auth/API only."""
import asyncio, ast, json, os, re, shutil, sys, tempfile
from pathlib import Path
from playwright.async_api import async_playwright
APP=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(APP/'test/math_dashboard'))
from browser_test import module_url, fixture, MOCK
OUT=Path(os.environ.get('ECAI_MATH_PREVIEW_DIR',tempfile.mkdtemp(prefix='ecai-samples-preview-')))
OUT.mkdir(parents=True,exist_ok=True)
CAT=json.loads((APP/'priv/static/math-samples/catalog.json').read_text())

def shell():
    text=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
    for key,name in [('math_paths_panel','ecai_math_paths'),('market_maker_panel','ecai_market_maker'),('compute_settings_panel','compute_settings'),('ollama_keys_panel','ollama_keys')]:
        text=text.replace('{{{'+key+'}}}',(APP/f'priv/templates/ui/dashboard/{name}.mustache').read_text())
    text=re.sub(r'<script\b[^>]*>.*?</script>','',text,flags=re.S)
    text=re.sub(r'<link\b[^>]*>','',text)
    text=re.sub(r'\{\{\{?.*?\}\}\}?','',text)
    css=''.join((APP/f'priv/static/css/{name}').read_text() for name in ['ecai-console.css','ecai-math-paths.css'])
    return text.replace('</head>','<style>'+css+'</style></head>')

async def boot(page,query=''):
    await page.set_content(shell())
    await page.evaluate('(q)=>window.__sampleSearch=q',query)
    await page.evaluate("""()=>{for(const e of document.querySelectorAll('[data-panel]')){e.hidden=e.dataset.panel!=='math';e.classList.toggle('is-visible',e.dataset.panel==='math');}
      for(const e of document.querySelectorAll('[data-view]'))e.classList.toggle('is-active',e.dataset.view==='math');
      document.querySelector('#ecaiConsole').dataset.activeView='math';document.querySelector('#viewBreadcrumb').textContent='Mathematical paths';document.querySelector('#topbarRuntime').textContent='Public sample preview';}""")
    await page.evaluate('(f)=>{window.__fixture=f;'+MOCK+'}',fixture())
    await page.evaluate("""async url=>{const m=await import(url);window.__math=m.initMathPaths({sampleSearch:window.__sampleSearch,request:(...args)=>window.__request(...args),
      currentToken:()=>window.__managed?'fixture-token':'',managedSession:()=>window.__managed,
      openLogin:()=>{window.__loginOpened=true},toast:()=>{}});window.__math.setVisible(true);}""",module_url((APP/'priv/static/js/ecai-math-paths.js').read_text()))

async def main():
    checks=[]
    async with async_playwright() as pw:
        opts=dict(headless=True,args=['--no-sandbox','--disable-dev-shm-usage'])
        chrome=os.environ.get('CHROMIUM') or shutil.which('chromium')
        if chrome:opts['executable_path']=chrome
        b=await pw.chromium.launch(**opts);p=await b.new_page(viewport={'width':1600,'height':1120})
        errors=[];p.on('pageerror',lambda e:errors.append(str(e)))
        await boot(p)
        assert await p.locator('#mathSampleSelect').input_value()=='doubling-6'
        assert await p.locator('#mathSampleSelect option').count()==13
        assert await p.locator('#mathGraph .math-node').count()==4
        assert 'preview' in await p.locator('#mathStatus').inner_text()
        assert await p.evaluate('window.__calls.length')==0
        checks.append('Default guest view contains 13 samples and a four-node degree-4 candidate; zero math API calls')
        assert '25/4, -35/8' in await p.locator('#mathPointResult').inner_text()
        await p.locator('#mathPointMultiply').click()
        assert '25/4, -35/8' in await p.locator('#mathScalarResult').inner_text()
        checks.append('Default exact point trace agrees with a separate group-law doubling calculation')
        assert await p.locator('.math-real-plot svg').count()==1
        assert 'illustration only' in await p.locator('.math-real-plot').inner_text()
        checks.append('Real-locus SVG is explicitly approximate and separate from exact invariants')
        for sample in CAT['samples']:
            await p.locator('#mathSampleSelect').select_option(sample['id'])
            assert await p.locator('#mathGraph .math-node').count()==sample['path']['hops']+1
            if sample['expected']=='reject':assert 'not on the target' in await p.locator('#mathPointResult').inner_text()
            else:assert await p.locator('#mathPointResult .math-point-image').count()==sample['path']['hops']+1
            assert not await p.locator('#mathStatus').evaluate("e=>e.classList.contains('math-status-good')")
        assert await p.evaluate('window.__calls.length')==0
        checks.append('All 12 positive fixtures render/evaluate locally; the corrupted map rejects without a server request')
        await p.locator('#mathSampleSelect').select_option('legendre-3-k0')
        assert '21952/9' in await p.locator('#mathInspectorBody').inner_text()
        await p.locator('#mathGraph .math-edge').first.click()
        assert 'Not run here' in await p.locator('#mathInspectorBody').inner_text()
        checks.append('Source j-invariant is exact; preview map inspector does not invent a native verification')
        await p.locator('#mathGalleryDisclosure').evaluate('(e)=>e.open=true')
        await p.locator('#mathSampleFilter').fill('degree 5')
        assert await p.locator('#mathCatalog button').count()==1
        await p.locator('#mathCatalog button').click()
        assert await p.locator('#mathSampleSelect').input_value()=='five-11a'
        await p.locator('#mathSampleFilter').fill('')
        checks.append('Searchable sample cards select the conductor-11 degree-5 problem')
        async with p.expect_download() as dl:await p.locator('#mathExport').click()
        artifact=await dl.value;text=Path(await artifact.path()).read_text()
        expected=next(s for s in CAT['samples'] if s['id']=='five-11a')
        assert text==expected['path_json']
        checks.append('Guest path export preserves the exact candidate bytes without a fake receipt')
        async with p.expect_download() as dl:await p.locator('#mathSageExport').click()
        artifact=await dl.value;script=Path(await artifact.path()).read_text();ast.parse(script)
        assert 'sage -python' in script and 'native ETF' in script
        checks.append('SageMath export is valid Python syntax with explicit full-identity checks')
        await p.locator('#mathSampleVerify').click()
        assert await p.evaluate('window.__loginOpened')
        assert await p.evaluate('window.__calls.length')==0
        checks.append('Guest verification opens sign-in; it does not start a job or bypass auth')
        await p.locator('#mathSampleEdit').click()
        assert await p.locator('#mathBuilderDisclosure').get_attribute('open') is not None
        assert await p.locator('[name=source_a6]').input_value()=='-79/4'
        assert await p.locator('[name=target_a6]').input_value()=='-1054319/4'
        checks.append('Endpoint editor receives the exact completed-square coefficients, not rounded values')
        await p.evaluate('window.__managed=true;window.__math.accessChanged()')
        await p.locator('#mathSampleVerify').click()
        await p.wait_for_function("document.querySelector('#mathStatus').textContent==='Algebraically verified'")
        post=await p.evaluate("window.__calls.find(x=>x.method==='POST')")
        assert post['body']=={'operation':'import','path_json':expected['path_json']}
        checks.append('Live replay uses the existing authenticated import API with the unmodified candidate')
        await p.evaluate('window.__managed=false;window.__math.reset()')
        assert 'preview' in await p.locator('#mathStatus').inner_text()
        assert 'fixture-job' not in await p.locator('#mathRun').inner_text()
        assert await p.locator('#mathReplay').is_disabled()
        checks.append('Sign-out discards private jobs and falls back to a clearly labelled public example')
        # An accepted job arriving after a newer preview selection must not seize the workspace.
        await p.evaluate("""()=>{window.__managed=true;window.__math.accessChanged();const original=window.__request;window.__request=async(path,opts={})=>{const r=await original(path,opts);if(opts.method==='POST')return await new Promise(resolve=>window.__pending=()=>resolve(r));return r;};}""")
        await p.locator('#mathSampleVerify').click();await p.wait_for_function('Boolean(window.__pending)')
        await p.locator('#mathSampleSelect').select_option('mixed-6');await p.evaluate('window.__pending()');await p.wait_for_timeout(100)
        assert await p.locator('#mathSampleSelect').input_value()=='mixed-6'
        assert 'preview' in await p.locator('#mathStatus').inner_text()
        checks.append('A late POST response cannot overwrite a newer public sample selection')
        await p.evaluate('window.__managed=false;window.__math.reset()')
        await p.locator('#mathSampleSelect').select_option('doubling-6')
        await p.locator('#mathPointY').fill('35');await p.locator('#mathPointEvaluate').click()
        assert 'not on the source' in await p.locator('#mathPointResult').inner_text()
        await p.locator('#mathSampleReset').click()
        await p.locator('#mathPointInfinity').check();assert await p.locator('#mathPointResult .math-point-image').count()==4
        assert (await p.locator('#mathPointResult').inner_text()).count('infinity')==4
        await p.locator('#mathSampleReset').click()
        checks.append('Off-curve points fail; infinity propagates; reset restores the supplied rational point')
        await p.locator('#mathGalleryDisclosure').evaluate('(e)=>e.open=false')
        await p.locator('#mathBuilderDisclosure').evaluate('(e)=>e.open=false')
        await p.locator('#mathPointMultiply').click()
        await p.evaluate("document.activeElement?.blur();window.scrollTo({top:0,behavior:'instant'})")
        await p.wait_for_timeout(100)
        await p.screenshot(path=str(OUT/'desktop.png'),full_page=True,animations='disabled')
        await p.set_viewport_size({'width':390,'height':844})
        assert await p.evaluate('document.documentElement.scrollWidth<=window.innerWidth')
        await p.locator('#mathGraph .math-node').last.click()
        assert '1728' in await p.locator('#mathInspectorBody').inner_text()
        await p.evaluate("document.activeElement?.blur();window.scrollTo({top:0,behavior:'instant'})")
        await p.screenshot(path=str(OUT/'mobile.png'),full_page=True,animations='disabled')
        checks.append('390px mobile layout preserves the graph, exact point controls and zero page overflow')
        await p.set_viewport_size({'width':1600,'height':1120})
        await p.locator('#mathSampleSelect').select_option('five-11a');await p.locator('#mathGraph .math-edge').first.click()
        await p.evaluate("document.activeElement?.blur();window.scrollTo({top:0,behavior:'instant'})")
        await p.screenshot(path=str(OUT/'degree-5.png'),full_page=True,animations='disabled')
        # Deep link with an allowlisted example, and invalid-ID fallback.
        for query,want in [('?math_sample=five-11a','five-11a'),('?math_sample=unknown','doubling-6')]:
            other=await b.new_page();await boot(other,query);assert await other.locator('#mathSampleSelect').input_value()==want
            assert await other.evaluate('window.__calls.length')==0;await other.close()
        checks.append('Deep-link query parsing selects a public example without a job; unknown IDs fall back to the default')
        assert not errors,errors
        await p.evaluate('window.__math.dispose()');await b.close()
        checks.append('No browser exceptions; controller cleanup succeeds')
    result={'status':'passed','count':len(checks),'checks':checks,'scope':'Production UI and exact client arithmetic, bundled candidates; synthetic auth/API for live controls. Not deployed native verification.'}
    (OUT/'browser-samples-validation.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
if __name__=='__main__':asyncio.run(main())
