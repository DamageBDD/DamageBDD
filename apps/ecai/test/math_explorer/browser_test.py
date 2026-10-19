#!/usr/bin/env python3
"""Actual workspace module/markup; independent-Python synthetic API fixtures.
No real server, native Erlang execution, remote accounts or paid operations.
"""
import asyncio,base64,hashlib,json,os,re,shutil,tempfile,sys,ast
from pathlib import Path
from playwright.async_api import async_playwright
from fixtures import explore
from reference_checker import verify_exploration,pathcheck
APP=Path(__file__).resolve().parents[2]
OUT=Path(os.environ.get('ECAI_EXPLORER_PREVIEW_DIR',tempfile.mkdtemp(prefix='ecai-source-explorer-')))
OUT.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(APP/'test/math_dashboard'))
from browser_test import module_url

def job(report,id='e'*32):
    raw=json.dumps(report,separators=(',',':'))
    return dict(id=id,status='succeeded',operation='explore',created_at_ms=1792141585000,
        retention='Synthetic browser fixture. Real node records are volatile.',result=dict(exploration=report,exploration_json=raw,
        artifact_sha256=hashlib.sha256(raw.encode()).hexdigest().upper(),elapsed_ms=23,checked_at_ms=1792141585023,
        metadata=dict(mode='source_only_exploration',generation_bounds=report['bounds'],note='Independent Python fixture, not native Erlang execution.')))

MOCK=r"""
window.managed=false;window.calls=[];window.jobs=[];window.nextReport=null;
window.req=async(path,options={})=>{
  calls.push({path,...options});
  if(!managed){const e=Error('unauthorized');e.status=401;throw e;}
  if(path==='/ecai/math/jobs' && options.method==='POST'){
    const j=structuredClone(nextReport||fixture);j.id='job-'+calls.length;
    jobs.unshift(j);return {ok:true,data:j};
  }
  if(path.endsWith('/replay')){
    const old=jobs.find(j=>j.id===path.split('/').at(-2));
    const row=old.result.exploration.results.find(r=>r.model_id===options.body.model_id);
    if(!row)throw Error('model not found');
    const j={id:'replay-'+calls.length,status:'succeeded',operation:'replay',created_at_ms:1792141585100,
      replayed_job_id:old.id,replayed_model_id:row.model_id,retention:old.retention,
      result:{path:JSON.parse(row.path_json),path_json:row.path_json,artifact_sha256:row.artifact_sha256,
        elapsed_ms:1,checked_at_ms:1792141585101,metadata:{mode:'replay'}}};jobs.unshift(j);return {ok:true,data:j};
  }
  if(path==='/ecai/math/jobs')return {ok:true,data:jobs.map(({result,...j})=>j)};
  const j=jobs.find(j=>j.id===path.split('/').at(-1));if(!j)throw Error('missing job');
  return {ok:true,data:structuredClone(j)};
};
"""
async def main():
    checks=[]
    async with async_playwright() as pw:
        opts={'headless':True,'args':['--no-sandbox','--disable-dev-shm-usage']}
        binary=os.environ.get('CHROMIUM') or shutil.which('chromium')
        if binary:opts['executable_path']=binary
        browser=await pw.chromium.launch(**opts)
        page=await browser.new_page(viewport={'width':1536,'height':1080},device_scale_factor=1)
        errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
        shell=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
        for key,name in [('math_paths_panel','ecai_math_paths'),('market_maker_panel','ecai_market_maker'),('compute_settings_panel','compute_settings'),('ollama_keys_panel','ollama_keys')]:
            shell=shell.replace('{{{'+key+'}}}',(APP/f'priv/templates/ui/dashboard/{name}.mustache').read_text())
        shell=re.sub(r'<script\b[^>]*>.*?</script>','',shell,flags=re.S)
        shell=re.sub(r'<link\b[^>]*>','',shell);shell=re.sub(r'\{\{\{?.*?\}\}\}?','',shell)
        css=(APP/'priv/static/css/ecai-console.css').read_text()+(APP/'priv/static/css/ecai-math-paths.css').read_text()
        shell=shell.replace('</head>','<style>'+css+'</style></head>')
        await page.set_content(shell)
        await page.evaluate("""()=>{for(const e of document.querySelectorAll('[data-panel]')){e.hidden=e.dataset.panel!=='math';e.classList.toggle('is-visible',e.dataset.panel==='math');}
        for(const e of document.querySelectorAll('[data-view]'))e.classList.toggle('is-active',e.dataset.view==='math');
        document.querySelector('#ecaiConsole').dataset.activeView='math';document.querySelector('#viewBreadcrumb').textContent='Mathematical paths';
        document.querySelector('#topbarRuntime').textContent='Preview · synthetic API';} """)
        await page.evaluate('(fixture)=>{window.fixture=fixture;'+MOCK+'}',job(explore()))
        module=module_url((APP/'priv/static/js/ecai-math-paths.js').read_text())
        await page.evaluate("""async url=>{const m=await import(url);window.ui=m.initMathPaths({request:req,currentToken:()=>managed?'test-token':'',managedSession:()=>managed,openLogin:()=>{},toast:()=>{}});ui.setVisible(true);} """,module)
        await page.locator('#mathBuilderDisclosure').evaluate('(e)=>e.open=true')
        # Public sample stays the initial preview; the solver test supplies its own seed.
        await page.locator('[name=source_a2]').fill('0')
        await page.locator('[name=source_a4]').fill('-1')
        await page.locator('[name=source_a6]').fill('0')
        assert await page.locator('#mathSampleSelect option').count()==13
        assert await page.locator('#mathStatus').inner_text()=='Example preview · not a live run'
        assert await page.locator('#mathGraph .math-node').count()==4
        assert await page.locator('[name=max_curves]').get_attribute('max')=='32'
        assert await page.locator('[name=max_curves]').evaluate('(e)=>e.checkValidity()')
        checks.append('Latest 13-example gallery/default doubling survives; source-mode model budget is valid')
        assert await page.locator('#mathMode').input_value()=='explore'
        assert await page.locator('#mathTargetFields').is_hidden()
        assert await page.locator('[name=target_a4]').is_disabled()
        checks.append('Default source-only mode hides and disables target inputs')
        assert await page.locator('#mathDiscover').is_disabled();assert await page.evaluate('calls.length')==0
        checks.append('No anonymous computation or automatic sample job')
        await page.evaluate('managed=true;ui.accessChanged()')
        await page.locator('#mathDiscover').click()
        await page.wait_for_function("document.querySelector('#mathStatus').textContent==='Bounded exploration complete'")
        sent=await page.evaluate("calls.find(c=>c.method==='POST').body")
        assert sent['operation']=='explore' and 'target' not in sent and sent['source']['a4']==['-1','1']
        assert sent['bounds']['timeout_ms']==8000
        checks.append('Request carries one exact source plus bounds and no destination')
        assert await page.locator('.math-explore-row').count()==7
        assert await page.locator('#mathExploreMetrics strong').all_text_contents()==['7','3','4','3']
        checks.append('Seven retained models and four local classes rendered from response')
        assert await page.locator('.math-relation-different').count()==3
        assert 'Isomorphic to source' in await page.locator('#mathExploreResults').inner_text()
        checks.append('Non-isomorphic models are distinct from alternate source models')
        assert await page.locator('#mathGraph .math-node').count()==2
        assert 'Q-isomorphism to source' in await page.locator('#mathChecks').inner_text()
        checks.append('A non-isomorphic result automatically opens its checked path')
        await page.locator('#mathNonIsoOnly').check()
        assert await page.locator('.math-explore-row').count()==3
        await page.locator('#mathNonIsoOnly').uncheck()
        checks.append('Non-isomorphic-only filter uses verified classification, not j equality')
        await page.locator('.math-explore-row').last.click()
        assert await page.locator('#mathGraph .math-edge').count()==2
        assert 'Checked isomorphism' in await page.locator('#mathChecks').inner_text()
        checks.append('Selecting an alternate model changes path and classification inspector')
        # These controls came from the newer sample workbench. They must operate
        # on the selected row, not a stale sample or a top-level job.path field.
        assert await page.locator('#mathPointEvaluate').is_enabled()
        assert await page.locator('#mathSageExport').is_enabled()
        await page.locator('#mathPointX').fill('1')
        await page.locator('#mathPointY').fill('0')
        await page.locator('#mathPointEvaluate').click()
        assert await page.locator('#mathPointResult .math-point-image').count()==3
        assert await page.locator('#mathPointResult.math-point-error').count()==0
        await page.locator('#mathPointMultiply').click()
        assert '[2]P = O' in await page.locator('#mathScalarResult').inner_text()
        checks.append('Exact point tracing and group-law tools use the selected exploration path')
        async with page.expect_download() as d:
            await page.locator('#mathSageExport').click()
        sage_source=Path(await (await d.value).path()).read_text()
        ast.parse(sage_source)
        assert 'fixture' in sage_source  # Native fixture IDs belong to this report.
        checks.append('Sage exporter accepts selected exploration path; generated script parses')
        await page.locator('.math-explore-row').first.click()
        assert await page.locator('#mathPointResult').inner_text()==''
        assert await page.locator('#mathScalarResult').inner_text()==''
        await page.locator('#mathPointEvaluate').click()
        assert await page.locator('#mathPointResult .math-point-image').count()==1
        await page.locator('.math-explore-row').last.click()
        assert await page.locator('#mathPointResult').inner_text()==''
        checks.append('Changing the retained model clears stale point calculations, including zero-hop paths')
        async with page.expect_download() as d:
            await page.locator('#mathExport').click()
        raw=Path(await (await d.value).path()).read_text()
        check=pathcheck.verify_document(json.loads(raw));assert check['total_degree']==4
        expected=explore()['results'][-1]['path_json'];assert raw==expected
        checks.append('Selected path exports unchanged bytes accepted by independent algebra checker')
        async with page.expect_download() as d:
            await page.locator('#mathExploreExport').click()
        raw_report=Path(await (await d.value).path()).read_text()
        assert verify_exploration(json.loads(raw_report))['local_q_classes']==4
        checks.append('Exploration export passes independent path and classification checks')
        async with page.expect_download() as d:
            await page.locator('#mathBundle').click()
        bundle=json.loads(Path(await (await d.value).path()).read_text())
        assert bundle['selected_model_id']==await page.locator('.math-explore-row').last.get_attribute('data-model-id')
        assert bundle['job']['result']['exploration_json']==raw_report
        checks.append('Evidence bundle records selected model without changing the original exploration JSON')
        old_job=await page.locator('#mathJobs [aria-current=true]').get_attribute('data-job-id')
        posts_before=await page.evaluate("calls.filter(c=>c.method==='POST').length")
        await page.locator('#mathSampleSelect').select_option('five-11a')
        assert await page.locator('#mathExploration').is_hidden()
        assert await page.locator('#mathExploreResults').inner_text()==''
        assert await page.locator('#mathExploreExport').is_disabled()
        assert await page.locator('#mathStatus').inner_text()=='Example preview · not a live run'
        assert 'Live node replay' in await page.locator('#mathChecks').inner_text()
        assert 'Not run' in await page.locator('#mathChecks').inner_text()
        assert await page.evaluate("calls.filter(c=>c.method==='POST').length")==posts_before
        checks.append('Switching from a private exploration to a public sample clears exploration evidence without a job')
        await page.locator('#mathSampleEdit').click()
        assert await page.locator('#mathMode').input_value()=='discover'
        assert await page.locator('#mathTargetFields').is_visible()
        assert await page.locator('[name=max_curves]').get_attribute('max')=='64'
        await page.locator('#mathMode').select_option('explore')
        assert await page.locator('#mathTargetFields').is_hidden()
        assert await page.locator('[name=max_curves]').get_attribute('max')=='32'
        assert await page.locator('[name=max_curves]').evaluate('(e)=>e.checkValidity()')
        checks.append('Endpoint-editor action still selects two-curve mode; switching back enforces source-only limits')
        await page.locator(f'#mathJobs [data-job-id="{old_job}"]').click()
        await page.wait_for_function("document.querySelectorAll('.math-explore-row').length===7")
        await page.locator('.math-explore-row').last.click()
        chosen=await page.locator('.math-explore-row').last.get_attribute('data-model-id')
        await page.locator('#mathReplay').click()
        await page.wait_for_function("document.querySelector('#mathStatus').textContent==='Algebraically verified'")
        last=await page.evaluate("calls.findLast(c=>c.method==='POST')")
        assert last['path'].endswith('/replay') and last['body']=={'model_id':chosen}
        checks.append('Replay selects exact owner-job/model pair rather than an arbitrary path')
        assert await page.locator('#mathExploration').is_hidden()
        assert 'Not attached to this job' in await page.locator('#mathChecks').inner_text()
        checks.append('Replay remains separate from independent checker and DamageBDD evidence')
        await page.evaluate('(j)=>{nextReport=j}',job(explore(max_curves=2)))
        await page.locator('[name=source_a2]').fill('0')
        await page.locator('[name=source_a4]').fill('-1')
        await page.locator('[name=source_a6]').fill('0')
        await page.locator('#mathDiscover').click()
        await page.wait_for_function("document.querySelector('#mathStatus').textContent.startsWith('Partial exploration')")
        assert 'model_budget' in await page.locator('#mathExploreScope').inner_text()
        assert await page.locator('.math-explore-row').count()==2
        checks.append('Budget-limited response retains checked results and is labelled partial')
        await page.evaluate('(j)=>{nextReport=j}',job(explore(depth=0)))
        await page.locator('#mathDiscover').click()
        await page.wait_for_function("document.querySelectorAll('.math-explore-row').length===1")
        assert await page.locator('#mathGraph .math-edge').count()==0
        await page.locator('#mathNonIsoOnly').check()
        assert 'not proof' in await page.locator('#mathExploreResults').inner_text()
        checks.append('Zero-discovery result and empty filter make no global non-existence claim')
        await page.locator('#mathMode').select_option('discover')
        assert await page.locator('#mathTargetFields').is_visible()
        assert await page.locator('[name=target_a4]').is_enabled()
        assert await page.locator('[name=timeout_ms]').is_disabled()
        await page.locator('#mathMode').select_option('explore')
        assert await page.locator('#mathTargetFields').is_hidden()
        checks.append('Existing endpoint-connection mode remains available')
        await page.evaluate('managed=false;ui.reset()')
        assert await page.locator('#mathExploration').is_hidden()
        assert await page.locator('#mathExploreExport').is_disabled()
        assert await page.locator('#mathExploreResults').inner_text()==''
        checks.append('Sign-out clears all exploration artifacts and disables report export')
        await page.evaluate('(j)=>{managed=true;nextReport=j;jobs=[];ui.accessChanged()}',job(explore()))
        for name,value in [('source_a2','0'),('source_a4','-1'),('source_a6','0'),('max_depth','2'),('max_curves','24')]:
            await page.locator(f'[name={name}]').fill(value)
        await page.locator('#mathPointX').fill('1')
        await page.locator('#mathPointY').fill('0')
        await page.locator('#mathDiscover').click()
        await page.wait_for_function("document.querySelectorAll('.math-explore-row').length===7")
        await page.locator('#mathGraph .math-edge').first.click()
        await page.evaluate("document.documentElement.style.scrollBehavior='auto';document.activeElement?.blur();window.scrollTo({top:0,behavior:'instant'})")
        await page.wait_for_timeout(150)
        await page.screenshot(path=str(OUT/'source-only-desktop.png'),full_page=True)
        await page.set_viewport_size({'width':390,'height':844})
        assert await page.evaluate('document.documentElement.scrollWidth<=innerWidth')
        await page.locator('.math-explore-row').nth(2).click()
        await page.evaluate("document.activeElement?.blur();window.scrollTo({top:0,behavior:'instant'})")
        await page.wait_for_timeout(150)
        await page.screenshot(path=str(OUT/'source-only-mobile.png'),full_page=True)
        checks.append('390px mobile layout and model selection without page overflow')
        await page.evaluate('ui.dispose()')
        assert not errors,errors
        checks.append('No browser exceptions; lifecycle disposal succeeds')
        await browser.close()
    result=dict(status='passed',count=len(checks),checks=checks,scope='Production workspace markup/JS with independent-Python synthetic API fixtures; not Erlang or live Cowboy execution')
    (OUT/'source-only-browser-validation.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
if __name__=='__main__':asyncio.run(main())
