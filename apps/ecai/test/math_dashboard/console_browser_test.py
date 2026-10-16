#!/usr/bin/env python3
"""Smoke-test production console navigation/request/account lifecycle with fake auth/API.
This checks the actual console and math module, not a live server or real wallet.
"""
import asyncio,json,re,os,shutil
from pathlib import Path
from playwright.async_api import async_playwright
from browser_test import APP, module_url, fixture, MOCK

async def main():
    shell=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
    for key,name in [('math_paths_panel','ecai_math_paths'),('market_maker_panel','ecai_market_maker'),('compute_settings_panel','compute_settings'),('ollama_keys_panel','ollama_keys')]:
        shell=shell.replace('{{{'+key+'}}}',(APP/f'priv/templates/ui/dashboard/{name}.mustache').read_text())
    shell=re.sub(r'<script\b[^>]*>.*?</script>','',shell,flags=re.S)
    shell=re.sub(r'<link\b[^>]*>','',shell)
    shell=re.sub(r'\{\{\{?.*?\}\}\}?','',shell)
    css=(APP/'priv/static/css/ecai-console.css').read_text()+(APP/'priv/static/css/ecai-math-paths.css').read_text()
    shell=shell.replace('</head>','<style>'+css+'</style></head>')
    token=module_url('''export const TokenManager={
      session:()=>window.__managed?{mode:window.__mode,email:'test@example.invalid',address:'ak-test'}:null,
      getToken:()=>window.__managed?'fixture-'+window.__mode+'-token':'',getAddress:()=>'ak-test',
      refreshSession:async()=>{},logout(){window.__managed=false;document.dispatchEvent(new Event('auth:changed'));}};
      export async function logoutActiveSession(){TokenManager.logout();}''')
    auth=module_url('export function initAuthUI(){}')
    stub='const empty=()=>({reset(){},dispose(){},setVisible(){},accountChanged(){},accessChanged(){},refresh:async()=>{}});'
    video=module_url(stub+'export const initVideoStudio=empty;')
    mm=module_url(stub+'export const initMarketMaker=empty;')
    math=module_url((APP/'priv/static/js/ecai-math-paths.js').read_text())
    console=(APP/'priv/static/js/ecai-console.js').read_text()
    for pattern,replacement in [
        (r'"/ecai/auth-assets/js/wallet-switcher.js"',repr(token)),
        (r'"/ecai/auth-assets/js/auth-ui.js[^\"]*"',repr(auth)),
        (r'"/static/js/ecai-video.js[^\"]*"',repr(video)),
        (r'"/static/js/ecai-market-maker.js[^\"]*"',repr(mm)),
        (r'"/static/js/ecai-math-paths.js[^\"]*"',repr(math))]:
        console,n=re.subn(pattern,lambda m:replacement,console);assert n==1,pattern
    console="const location=window.__location;const history=window.__history;\n"+console
    async with async_playwright() as pw:
        opts={'headless':True,'args':['--no-sandbox','--disable-dev-shm-usage']}
        chromium=os.environ.get('CHROMIUM') or shutil.which('chromium')
        if chromium:opts['executable_path']=chromium
        b=await pw.chromium.launch(**opts);p=await b.new_page(viewport={'width':1440,'height':1000})
        errors=[];p.on('pageerror',lambda e:errors.append(str(e)))
        await p.set_content(shell)
        await p.evaluate('(f)=>{window.__fixture=f;'+MOCK+'}',fixture())
        await p.evaluate('''()=>{
            window.__managed=true;window.__mode='custodial';window.__wire=[];
            window.__location={origin:'https://ecai-math.test',host:'ecai-math.test',pathname:'/dashboard',hash:'',reload(){}};
            window.__history={replaceState(a,b,url){window.__location.hash=new URL(url,window.__location.origin).hash;}};
            window.fetch=async(url,opts={})=>{
              const path=new URL(url,window.__location.origin).pathname;window.__wire.push([path,opts]);
              let result;
              if(path.startsWith('/ecai/math/'))result=await window.__request(path,{method:opts.method||'GET',body:opts.body?JSON.parse(opts.body):undefined});
              else if(path==='/ecai/auth/session')result={authenticated:window.__managed,public_key:'ak-test',mode:window.__mode};
              else if(path==='/ecai/index-jobs')result={jobs:[]};
              else if(path.endsWith('/presets'))result={presets:[]};
              else result={ok:true,status:{},jobs:[]};
              return new Response(JSON.stringify(result),{status:200,headers:{'Content-Type':'application/json'}});
            };
        }''')
        await p.evaluate('async url=>{await import(url)}',module_url(console))
        await p.wait_for_timeout(150)
        assert not errors,errors
        assert await p.evaluate('window.__location.hash')=='#math'
        assert await p.locator('#mathSampleSelect').input_value()=='doubling-6'
        await p.locator('[data-view=math]').click()
        assert await p.locator('[data-panel=math]').is_visible()
        assert await p.locator('[data-panel=overview]').is_hidden()
        assert await p.locator('#viewBreadcrumb').inner_text()=='Mathematical paths'
        assert await p.evaluate('window.__location.hash')=='#math'
        await p.locator('#mathBuilderDisclosure').evaluate('(e)=>e.open=true')
        await p.locator('#mathDemo').click()
        await p.wait_for_function("document.querySelector('#mathStatus').textContent==='Algebraically verified'")
        write=await p.evaluate("window.__wire.find(x=>x[0]==='/ecai/math/jobs'&&x[1].method==='POST')")
        assert write[1]['headers']['Authorization']=='Bearer fixture-custodial-token'
        assert write[1]['mode']=='same-origin'
        await p.evaluate("window.__mode='wallet';document.dispatchEvent(new Event('auth:changed'))")
        assert await p.locator('#mathDemo').is_disabled()
        assert 'preview' in await p.locator('#mathStatus').inner_text()
        assert 'fixture-job' not in await p.locator('#mathRun').inner_text()
        await p.evaluate("window.__jobs=[];window.__mode='custodial';document.dispatchEvent(new Event('auth:changed'))")
        await p.wait_for_function("document.querySelector('#mathDemo').disabled===false")
        await p.locator('#mathBuilderDisclosure').evaluate('(e)=>e.open=true')
        await p.locator('#mathDemo').click()
        await p.wait_for_function("document.querySelectorAll('#mathGraph .math-node').length===3")
        await p.evaluate("window.__managed=false;document.dispatchEvent(new Event('auth:changed'))")
        assert 'preview' in await p.locator('#mathStatus').inner_text()
        assert 'fixture-job' not in await p.locator('#mathRun').inner_text()
        assert await p.locator('#mathExport').is_enabled()  # public candidate only
        await p.locator('[data-view=search]').click()
        assert await p.locator('[data-panel=search]').is_visible()
        await p.locator('[data-view=math]').click()
        assert await p.locator('[data-panel=math]').is_visible()
        assert not errors,errors
        await p.evaluate("window.dispatchEvent(new Event('beforeunload'))")
        await b.close()
    print(json.dumps({'status':'passed','checks':[
        'Empty dashboard hash defaults to math and the doubling example',
        'Actual console navigation activates math panel, breadcrumb and hash',
        'Shared request wrapper supplies bearer and same-origin mode',
        'Managed-to-wallet switch clears artifacts and disables computation',
        'Wallet-to-managed switch restores valid controls',
        'Sign-out removes private artifacts while public sample export remains available',
        'Navigation to existing search workspace still works',
        'No browser exceptions in console integration'],
        'count':8,'scope':'Production console/module with synthetic auth/API; other workspace controllers stubbed'},indent=2))
if __name__=='__main__':asyncio.run(main())
