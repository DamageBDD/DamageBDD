#!/usr/bin/env python3
"""Actual installed console, Payment Guard and (when installed) EnergyFlex.
Authentication/API are synthetic, other workspace controllers are stubs.
No live Cowboy/auth service acceptance is claimed.
"""
import asyncio
import json
import os
import re
import shutil
from playwright.async_api import async_playwright
from browser_test import APP,OUT,module,module_urls


def energy_module():
    checker=module((APP/'priv/static/js/energyflex-checker.js').read_text())
    model=module((APP/'priv/static/js/energyflex-model.js').read_text().replace("'./energyflex-checker.js'",repr(checker)))
    return module((APP/'priv/static/js/ecai-energyflex.js').read_text().replace("'./energyflex-model.js'",repr(model)))


async def main():
    html=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
    html=re.sub(r'<script\b[^>]*>.*?</script>','',html,flags=re.S)
    html=re.sub(r'<link\b[^>]*>','',html)
    html=re.sub(r'\{\{\{?.*?\}\}\}?','',html)
    css='[hidden]{display:none!important}.console-shell{display:grid;grid-template-columns:210px 1fr}.console-main{padding:20px;min-width:0}.console-sidebar{padding:15px;background:#101b22;color:#ddd}.nav-link{display:block}.console-body{min-width:0}body{margin:0;background:#081116}'
    css+=(APP/'priv/static/css/ecai-payment-guard.css').read_text()
    has_energy=(APP/'priv/static/js/ecai-energyflex.js').exists() and 'id="energyFlex"' in html
    if has_energy:css+=(APP/'priv/static/css/ecai-energyflex.css').read_text()
    html=html.replace('</head>','<style>'+css+'</style></head>')
    source=(APP/'priv/static/js/ecai-console.js').read_text()
    generic="const stub=()=>new Proxy({},{get:(_,key)=>key==='then'?undefined:(...args)=>key==='label'?'All indexes':undefined});"
    def replace_import(match):
        names,url=match.groups()
        if 'ecai-payment-guard.js' in url:return 'import {'+names+'} from '+repr(module_urls()[1])+';'
        if 'ecai-energyflex.js' in url and has_energy:return 'import {'+names+'} from '+repr(energy_module())+';'
        if 'wallet-switcher.js' in url:
            code="""export const TokenManager={session:()=>window.__mode==='anonymous'?null:{mode:window.__mode,email:'test@example.invalid',address:'ak-test'},getToken:()=>window.__mode==='anonymous'?'':'fixture-token',getAddress:()=>'ak-test',refreshSession:async()=>{},logout(){window.__mode='anonymous';document.dispatchEvent(new Event('auth:changed'));}};export async function logoutActiveSession(){TokenManager.logout();}"""
        elif 'auth-ui.js' in url:
            code="export function initAuthUI(){window.DamageAuth={open(){window.__loginOpened++;},status(){}};}"
        else:code=generic+'\n'+'\n'.join('export const '+name.strip()+'=stub;' for name in names.split(','))
        return 'import {'+names+'} from '+repr(module(code))+';'
    source=re.sub(r'import\s*\{([^}]+)\}\s*from\s*["\']([^"\']+)["\'];',replace_import,source)
    source=re.sub(r'import\s+["\'][^"\']+["\'];','',source)
    source=re.sub(r'(?<![\w.])location\.', 'window.__location.',source)
    source=source.replace('history.replaceState','window.__history.replaceState')
    checks=[];errors=[]
    async with async_playwright() as p:
        browser=await p.chromium.launch(executable_path=os.environ.get('CHROMIUM') or shutil.which('chromium'),headless=True,args=['--no-sandbox'])
        page=await browser.new_page(viewport={'width':1540,'height':1100})
        page.on('pageerror',lambda e:errors.append(str(e)))
        await page.set_content(html)
        await page.evaluate("""()=>{
          window.__mode='anonymous';window.__loginOpened=0;window.__requests=[];
          window.__location={origin:'https://payment-guard.test',host:'payment-guard.test',pathname:'/dashboard',search:'',hash:'#payment-guard',reload(){}};
          window.__history={replaceState(a,b,url){window.__location.hash=new URL(url,window.__location.origin).hash;}};
          window.fetch=async(url,options={})=>{const path=new URL(url,window.__location.origin).pathname;window.__requests.push({path,method:options.method||'GET'});return {ok:true,status:200,text:async()=>JSON.stringify({status:'ok',jobs:[],presets:[],items:[],authenticated:window.__mode!=='anonymous',public_key:'ak-test',node_admin:false})};};
        }""")
        await page.evaluate('async url=>await import(url)',module(source))
        await page.wait_for_timeout(150)
        assert not errors,errors
        assert await page.locator('[data-panel="payment-guard"]').is_visible()
        assert await page.locator('#viewBreadcrumb').inner_text()=='Agent Payment Guard'
        assert await page.locator('[data-pg="prevented"]').inner_text()=='A$4,800.00'
        assert await page.evaluate('window.__loginOpened')==0
        checks.append('Anonymous direct #payment-guard entry runs with no auth prompt')
        await page.locator('[data-view="search"]').first.click()
        assert await page.locator('[data-panel="payment-guard"]').is_hidden()
        await page.locator('[data-view="payment-guard"]').click()
        assert await page.evaluate('window.__location.hash')=='#payment-guard'
        assert await page.locator('[data-view="payment-guard"]').get_attribute('aria-current')=='page'
        checks.append('Actual console navigation, breadcrumb, hash and active item are integrated')
        for mode in ['wallet','custodial','anonymous']:
            await page.evaluate('(mode)=>{window.__mode=mode;document.dispatchEvent(new Event("auth:changed"));}',mode)
            assert await page.locator('[data-pg="run"]').is_enabled()
            await page.locator('[data-pg="run"]').click()
            assert await page.locator('[data-pg="pass"]').inner_text()=='6 / 6 pass'
        checks.append('Guest, wallet and managed-session transitions retain public sandbox access')
        await page.evaluate("()=>{window.__mode='wallet';document.dispatchEvent(new Event('auth:changed'));}")
        assert await page.locator('[data-panel="indexing"] #indexSampleLoad').is_disabled()
        assert await page.locator('[data-pg="run"]').is_enabled()
        checks.append('Existing wallet restrictions on managed indexing controls remain enforced')
        await page.locator('[data-pg="play"]').click();await page.wait_for_timeout(1300)
        await page.locator('[data-view="search"]').first.click()
        previous=await page.locator('[data-pg="position"]').input_value()
        await page.wait_for_timeout(1300)
        assert await page.locator('[data-pg="position"]').input_value()==previous
        assert await page.locator('#paymentGuard').get_attribute('data-playing')=='false'
        checks.append('Navigating away pauses Payment Guard replay and stops its timer')
        if has_energy:
            await page.locator('[data-view="energyflex"]').click()
            assert await page.locator('[data-panel="energyflex"]').is_visible()
            assert await page.locator('[data-ef="saving"]').inner_text()=='A$7.00'
            assert await page.locator('#viewBreadcrumb').inner_text()=='EnergyFlex'
            checks.append('Existing EnergyFlex remains navigable and retains its reference result')
        await page.locator('[data-view="payment-guard"]').click()
        await page.locator('#refreshView').click()
        assert await page.locator('[data-pg="pass"]').inner_text()=='6 / 6 pass'
        requests=await page.evaluate('window.__requests')
        assert not any(r['method']!='GET' or '/admin/' in r['path'] or 'payment-guard' in r['path'] or 'l402' in r['path'] for r in requests),requests
        assert await page.evaluate('window.__loginOpened')==0
        checks.append('Workspace refresh stays local with no mutation, payment, privileged or new API request')
        await page.locator('[data-pg="play"]').click()
        await page.evaluate("window.dispatchEvent(new Event('beforeunload'))")
        previous=await page.locator('[data-pg="position"]').input_value();await page.wait_for_timeout(1300)
        assert await page.locator('[data-pg="position"]').input_value()==previous
        assert not errors,errors
        checks.append('Disposal clears listeners/timer without console exceptions')
        await browser.close()
    result={'status':'passed','count':len(checks),'checks':checks,'scope':'Retrieved production console plus Payment Guard and prior EnergyFlex; synthetic auth/API; other workspace controllers stubbed. No live server acceptance.'}
    OUT.mkdir(parents=True,exist_ok=True);(OUT/'console-results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':asyncio.run(main())
