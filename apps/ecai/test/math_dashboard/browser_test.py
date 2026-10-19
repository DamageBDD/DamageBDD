#!/usr/bin/env python3
"""Real module/markup in Chromium, synthetic API/auth fixtures. NOT Cowboy tests.
Requires playwright + Chromium. Writes screenshots/results to ECAI_MATH_PREVIEW_DIR
(default a temporary directory), never contacts a live node or spends funds.
"""
import asyncio, base64, hashlib, json, os, re, shutil, tempfile
from pathlib import Path
from playwright.async_api import async_playwright

APP = Path(__file__).resolve().parents[2]
OUT = Path(os.environ.get('ECAI_MATH_PREVIEW_DIR', tempfile.mkdtemp(prefix='ecai-math-ui-')))
OUT.mkdir(parents=True, exist_ok=True)

def module_url(source):
    # Bundle our same-origin ES module dependencies for the offline DOM fixture.
    for name in ('ecai-math-samples.js', 'ecai-math-exact.js'):
        dependency = APP / 'priv/static/js' / name
        source = re.sub(r"(['\"])\./" + re.escape(name) + r"(?:\?[^'\"]*)?\1",
                        lambda m: repr(module_url(dependency.read_text())), source)
    return 'data:text/javascript;base64,' + base64.b64encode(source.encode()).decode()

def fixture():
    g = json.loads((APP/'priv/math_pathfinder/demo_graph.json').read_text())
    checks = [dict(status='verified',scope='rational_map_identity',checker='ecai_exact_q_map_v1',
        formal_proof=False,degree=2,degree_checked=True,origin_preserved=True,
        polynomial_identity='zero',source_id=f'fixture-curve-{i}',target_id=f'fixture-curve-{i+1}',map_id=f'fixture-map-{i}') for i in range(2)]
    p = dict(schema=1, kind='mathematical_path',id='fixture-path-not-a-native-id',source=g['curves'][0],target=g['curves'][2],
        steps=g['edges'], hops=2,total_degree='4',total_cost=2,search=dict(checked_edges=6,rejected_edges=0,depth_pruned=1),
        verification=dict(status='verified',source_id='fixture-curve-0',target_id='fixture-curve-2',
                          checker='ecai_exact_q_path_v1',formal_proof=False,total_degree='4',steps=checks))
    raw=json.dumps(p,separators=(',',':'))
    return dict(id='fixture-job-1',status='succeeded',operation='demo',created_at_ms=1792141585000,
        retention='Volatile test fixture; not deployed evidence.',result=dict(path=p,path_json=raw,
            artifact_sha256=hashlib.sha256(raw.encode()).hexdigest(),elapsed_ms=21,checked_at_ms=1792141585021,
            metadata=dict(mode='explicit_demo',note='Synthetic API fixture used only for browser tests.')))

MOCK=r"""
window.__managed=false;window.__calls=[];window.__jobs=[];window.__delay=false;window.__held=[];
window.__request=async(path,opts={})=>{
  window.__calls.push({path,...opts});
  if(!window.__managed){let e=Error('Unauthorized');e.status=401;throw e;}
  if(path==='/ecai/math/jobs' && opts.method==='POST'){
    if(opts.body.operation==='import'){
      if(opts.body.path_json==='oops') {const j={id:'invalid-import',status:'failed',operation:'import',error:'invalid_json',created_at_ms:Date.now()};window.__jobs.unshift(j);return{ok:true,data:j};}
      const j=structuredClone(window.__fixture);j.id='imported';j.operation='import';window.__jobs.unshift(j);return{ok:true,data:j};
    }
    const j=structuredClone(window.__fixture);j.id='new-'+window.__calls.length;j.operation=opts.body.operation;
    window.__jobs.unshift(j);return{ok:true,data:j};
  }
  if(path.endsWith('/replay')){const j=structuredClone(window.__fixture);j.id='replayed';j.operation='replay';j.replayed_job_id=path.split('/').at(-2);window.__jobs.unshift(j);return{ok:true,data:j};}
  if(path==='/ecai/math/jobs')return{ok:true,data:window.__jobs.map(({result,...j})=>structuredClone(j))};
  const j=window.__jobs.find(j=>j.id===path.split('/').at(-1));
  if(!j)throw Error('Unknown test route '+path);
  const result={ok:true,data:structuredClone(j)};
  if(window.__delay)return await new Promise(resolve=>window.__held.push(()=>resolve(result)));
  return result;
};
"""
async def main():
    checks=[]
    async with async_playwright() as pw:
        options={'headless':True,'args':['--no-sandbox','--disable-dev-shm-usage']}
        chromium=os.environ.get('CHROMIUM') or shutil.which('chromium')
        if chromium: options['executable_path']=chromium
        browser=await pw.chromium.launch(**options)
        page=await browser.new_page(viewport={'width':1536,'height':1120},device_scale_factor=1)
        errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
        shell=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
        for key,name in [('math_paths_panel','ecai_math_paths'),('market_maker_panel','ecai_market_maker'),('compute_settings_panel','compute_settings'),('ollama_keys_panel','ollama_keys')]:
            shell=shell.replace('{{{'+key+'}}}',(APP/f'priv/templates/ui/dashboard/{name}.mustache').read_text())
        shell=re.sub(r'<script\b[^>]*>.*?</script>','',shell,flags=re.S)
        shell=re.sub(r'<link\b[^>]*>','',shell)
        shell=re.sub(r'\{\{\{?.*?\}\}\}?','',shell)
        css=(APP/'priv/static/css/ecai-console.css').read_text()+(APP/'priv/static/css/ecai-math-paths.css').read_text()
        shell=shell.replace('</head>','<style>'+css+'</style></head>')
        await page.set_content(shell)
        await page.evaluate("""()=>{for(const e of document.querySelectorAll('[data-panel]')){e.hidden=e.dataset.panel!=='math';e.classList.toggle('is-visible',e.dataset.panel==='math');}
          for(const e of document.querySelectorAll('[data-view]'))e.classList.toggle('is-active',e.dataset.view==='math');
          document.querySelector('#ecaiConsole').dataset.activeView='math';document.querySelector('#viewBreadcrumb').textContent='Mathematical paths';document.querySelector('#topbarRuntime').textContent='Browser test fixture';} """)
        await page.evaluate('(fixture)=>{window.__fixture=fixture;'+MOCK+'}',fixture())
        await page.evaluate("""async url=>{const m=await import(url);window.__module=m;window.__math=m.initMathPaths({request:window.__request,
          currentToken:()=>window.__managed?'fixture-token':'',managedSession:()=>window.__managed,openLogin:()=>{},toast:()=>{}});window.__math.setVisible(true);} """,module_url((APP/'priv/static/js/ecai-math-paths.js').read_text()))
        await page.locator('#mathBuilderDisclosure').evaluate('(e)=>e.open=true')
        assert await page.locator('#mathDemo').is_disabled()
        assert await page.evaluate('window.__calls.length')==0
        checks.append('Guest controls denied; no automatic computation')
        await page.evaluate('window.__managed=true;window.__math.accessChanged()')
        await page.locator('#mathDemo').click()
        await page.wait_for_function("document.querySelector('#mathStatus').textContent==='Algebraically verified'")
        assert await page.locator('#mathGraph .math-node').count()==3
        assert await page.locator('#mathGraph .math-edge').count()==2
        checks.append('Live-response path renders three models and two selectable maps')
        await page.locator('#mathGraph .math-edge').first.click()
        assert 'x² − 1' in await page.locator('#mathInspectorBody').inner_text()
        checks.append('First exact rational map inspected')
        await page.locator('#mathGraph .math-edge').nth(1).click()
        assert 'x² − 4' in await page.locator('#mathInspectorBody').inner_text()
        checks.append('Second exact rational map inspected')
        await page.locator('#mathGraph .math-node').nth(2).click()
        assert '16x' in await page.locator('#mathInspectorBody').inner_text()
        checks.append('Curve inspector shows exact model and coefficients')
        assert 'Not attached to this job' in await page.locator('#mathChecks').inner_text()
        assert 'Not provided' in await page.locator('#mathChecks').inner_text()
        checks.append('No fabricated independent-check, report, or formal-proof badge')
        await page.locator('#mathTabChecks').focus();await page.keyboard.press('ArrowRight')
        assert await page.locator('#mathSearch').is_visible()
        assert 'checked_edges' in await page.locator('#mathSearch').inner_text()
        await page.keyboard.press('End');assert await page.locator('#mathRun').is_visible()
        checks.append('Keyboard tabs expose search bounds and scoped provenance')
        async with page.expect_download() as download:
            await page.locator('#mathExport').click()
        d=await download.value;path=await d.path()
        raw=Path(path).read_text()
        assert raw==fixture()['result']['path_json']
        checks.append('Native path JSON download preserves supplied bytes and rational strings')
        await page.locator('#mathReplay').click()
        await page.wait_for_function("document.querySelector('#mathRun').textContent.includes('replayed')")
        assert (await page.evaluate('window.__calls.findLast(x=>x.method===\'POST\')'))['body']=={}
        checks.append('Replay submits a new explicit job, not a client-side badge change')
        await page.locator('#mathMode').select_option('discover')
        await page.locator('[name=source_a4]').fill('9007199254740993/7')
        await page.locator('#mathDiscover').click()
        await page.wait_for_function("window.__calls.some(x=>x.body?.source?.a4?.[0]==='9007199254740993')")
        checks.append('Discovery request preserves integers beyond JavaScript Number precision')
        await page.locator('[name=source_a4]').fill('-1')
        await page.locator('#mathImportFile').set_input_files({'name':'bad.json','mimeType':'application/json','buffer':b'oops'})
        await page.locator('#mathImport').click()
        await page.wait_for_function("document.querySelector('#mathStatus').textContent==='failed'")
        assert await page.locator('#mathExport').is_disabled()
        assert await page.locator('#mathGraph .math-node').count()==0
        checks.append('Failed import clears previous path and disables export')
        await page.evaluate('window.__delay=true')
        await page.locator('#mathJobs [data-job-id="replayed"]').click()
        await page.wait_for_function('window.__held.length>0')
        await page.evaluate('window.__managed=false;window.__math.reset();window.__held.forEach(f=>f())')
        await page.wait_for_timeout(60)
        assert 'preview' in await page.locator('#mathStatus').inner_text()
        assert 'fixture-job' not in await page.locator('#mathRun').inner_text()
        assert await page.locator('#mathReplay').is_disabled()
        checks.append('Late response from previous account cannot repopulate private data')
        await page.evaluate('window.__delay=false;window.__jobs=[structuredClone(window.__fixture)];window.__managed=true;window.__math.accessChanged()')
        await page.locator('#mathJobs [data-job-id="fixture-job-1"]').click()
        await page.wait_for_function("document.querySelectorAll('#mathGraph .math-node').length===3")
        # A source label must render as inert text, not HTML.
        await page.evaluate("window.__fixture.result.path.steps[0].origins=['<img src=x onerror=alert(1)>'];window.__jobs=[structuredClone(window.__fixture)];window.__math.reset();window.__math.accessChanged()")
        await page.locator('#mathJobs [data-job-id="fixture-job-1"]').click()
        await page.wait_for_function("document.querySelectorAll('#mathGraph .math-edge').length===2")
        await page.locator('#mathGraph .math-edge').first.click()
        assert await page.locator('#mathInspectorBody img').count()==0
        assert '<img' in await page.locator('#mathInspectorBody').inner_text()
        checks.append('Source labels are inert text; no innerHTML injection')
        await page.evaluate("window.__fixture.result.path.steps[0].origins=['local'];window.__jobs=[structuredClone(window.__fixture)];window.__math.reset();window.__math.accessChanged()")
        await page.locator('#mathJobs [data-job-id="fixture-job-1"]').click()
        await page.wait_for_function("document.querySelectorAll('#mathGraph .math-edge').length===2")
        await page.locator('#mathGraph .math-edge').first.click()
        await page.locator('#mathTabChecks').click()
        await page.evaluate("document.documentElement.style.scrollBehavior='auto';document.activeElement?.blur();window.scrollTo({top:0,behavior:'instant'})")
        await page.wait_for_function('window.scrollY===0')
        await page.evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))')
        await page.wait_for_timeout(100)
        await page.screenshot(path=str(OUT/'desktop.png'),full_page=True)
        await page.set_viewport_size({'width':390,'height':844})
        assert await page.evaluate('document.documentElement.scrollWidth<=window.innerWidth'),await page.evaluate("[...document.querySelectorAll('body *')].filter(e=>e.getBoundingClientRect().right>window.innerWidth+1 && e.getBoundingClientRect().width>0).map(e=>[e.tagName,e.id,e.className,e.getBoundingClientRect().width,e.getBoundingClientRect().right]).slice(0,25)")
        await page.locator('#mathGraph .math-node').nth(2).click()
        await page.evaluate("document.activeElement?.blur();window.scrollTo({top:0,behavior:'instant'})")
        await page.wait_for_function('window.scrollY===0')
        await page.evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))')
        await page.wait_for_timeout(100)
        await page.screenshot(path=str(OUT/'mobile.png'),full_page=True)
        checks.append('390px mobile layout has no page overflow and preserves graph interactions')
        await page.evaluate('window.__math.dispose()')
        assert not errors,errors
        checks.append('No browser JavaScript errors; controller disposes cleanly')
        await browser.close()
    result={'status':'passed','count':len(checks),'checks':checks,'scope':'Chromium DOM with synthetic API/auth fixtures; not native Erlang or live HTTP verification'}
    (OUT/'browser-validation.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2));print('Artifacts:',OUT)

if __name__=='__main__': asyncio.run(main())
