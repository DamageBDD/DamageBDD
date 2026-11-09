#!/usr/bin/env python3
"""Production console + Food Rescue, EnergyFlex, Payment Guard; synthetic auth/API.
Other workspace controllers are stubbed. Not a live Cowboy/auth acceptance test.
"""
import asyncio,json,os,re,shutil
from playwright.async_api import async_playwright
from browser_test import APP,OUT,module,module_urls

def energy_module():
 checker=module((APP/'priv/static/js/energyflex-checker.js').read_text())
 model=module((APP/'priv/static/js/energyflex-model.js').read_text().replace("'./energyflex-checker.js'",repr(checker)))
 return module((APP/'priv/static/js/ecai-energyflex.js').read_text().replace("'./energyflex-model.js'",repr(model)))
def payment_module():
 model=module((APP/'priv/static/js/payment-guard-model.js').read_text())
 return module((APP/'priv/static/js/ecai-payment-guard.js').read_text().replace("'./payment-guard-model.js?v=payment-guard-v1'",repr(model)))
async def main():
 html=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text();html=re.sub(r'<script\b[^>]*>.*?</script>','',html,flags=re.S);html=re.sub(r'<link\b[^>]*>','',html);html=re.sub(r'\{\{\{?.*?\}\}\}?','',html)
 css='[hidden]{display:none!important}.console-shell{display:grid;grid-template-columns:210px 1fr}.console-main{padding:20px;min-width:0}.console-sidebar{padding:15px;background:#101b22;color:#ddd}.nav-link{display:block}.console-body{min-width:0}body{margin:0;background:#081116}'
 css+=(APP/'priv/static/css/ecai-food-rescue.css').read_text()
 energy=(APP/'priv/static/js/ecai-energyflex.js').exists() and 'id="energyFlex"' in html
 payment=(APP/'priv/static/js/ecai-payment-guard.js').exists() and 'id="paymentGuard"' in html
 if energy:css+=(APP/'priv/static/css/ecai-energyflex.css').read_text()
 if payment:css+=(APP/'priv/static/css/ecai-payment-guard.css').read_text()
 html=html.replace('</head>','<style>'+css+'</style></head>')
 source=(APP/'priv/static/js/ecai-console.js').read_text()
 generic="const stub=()=>new Proxy({},{get:(_,key)=>key==='then'?undefined:(...args)=>key==='label'?'All indexes':undefined});"
 def replace_import(match):
  names,url=match.groups()
  if 'ecai-food-rescue.js' in url:return 'import {'+names+'} from '+repr(module_urls()[1])+';'
  if 'ecai-energyflex.js' in url and energy:return 'import {'+names+'} from '+repr(energy_module())+';'
  if 'ecai-payment-guard.js' in url and payment:return 'import {'+names+'} from '+repr(payment_module())+';'
  if 'wallet-switcher.js' in url:
   code="""export const TokenManager={session:()=>window.__mode==='anonymous'?null:{mode:window.__mode,email:'test@example.invalid',address:'ak-test'},getToken:()=>window.__mode==='anonymous'?'':'fixture-token',getAddress:()=>'ak-test',refreshSession:async()=>{},logout(){window.__mode='anonymous';document.dispatchEvent(new Event('auth:changed'));}};export async function logoutActiveSession(){TokenManager.logout();}"""
  elif 'auth-ui.js' in url:code="export function initAuthUI(){window.DamageAuth={open(){window.__loginOpened++;},status(){}};}"
  else:code=generic+'\n'+'\n'.join('export const '+name.strip()+'=stub;' for name in names.split(','))
  return 'import {'+names+'} from '+repr(module(code))+';'
 source=re.sub(r'import\s*\{([^}]+)\}\s*from\s*["\']([^"\']+)["\'];',replace_import,source)
 source=re.sub(r'import\s+["\'][^"\']+["\'];','',source);source=re.sub(r'(?<![\w.])location\.','window.__location.',source);source=source.replace('history.replaceState','window.__history.replaceState')
 checks=[];errors=[]
 async with async_playwright() as p:
  browser=await p.chromium.launch(executable_path=os.environ.get('CHROMIUM') or shutil.which('chromium'),headless=True,args=['--no-sandbox'])
  page=await browser.new_page(viewport={'width':1540,'height':1100});page.on('pageerror',lambda e:errors.append(str(e)))
  await page.set_content(html)
  await page.evaluate("""()=>{
    window.__mode='anonymous';window.__loginOpened=0;window.__requests=[];
    window.__location={origin:'https://food-rescue.test',host:'food-rescue.test',pathname:'/dashboard',search:'',hash:'#food-rescue',reload(){}};
    window.__history={replaceState(a,b,url){window.__location.hash=new URL(url,window.__location.origin).hash;}};
    window.fetch=async(url,options={})=>{const path=new URL(url,window.__location.origin).pathname;window.__requests.push({path,method:options.method||'GET'});return {ok:true,status:200,text:async()=>JSON.stringify({status:'ok',jobs:[],presets:[],items:[],authenticated:window.__mode!=='anonymous',public_key:'ak-test',node_admin:false})};};
  }""")
  await page.evaluate('async url=>await import(url)',module(source));await page.wait_for_timeout(150)
  assert not errors,errors
  assert await page.locator('[data-panel="food-rescue"]').is_visible();assert await page.locator('#viewBreadcrumb').inner_text()=='Food Rescue & Recall'
  assert await page.locator('[data-fr="rescued"]').inner_text()=='400 kg';assert await page.evaluate('window.__loginOpened')==0
  checks.append('Anonymous #food-rescue entry computes the reference without a login prompt')
  await page.locator('[data-view="search"]').first.click();assert await page.locator('#foodRescue').is_hidden()
  await page.locator('[data-view="food-rescue"]').click();assert await page.evaluate('window.__location.hash')=='#food-rescue'
  assert await page.locator('[data-view="food-rescue"]').get_attribute('aria-current')=='page'
  checks.append('Actual console navigation updates panel, breadcrumb, hash and active sidebar item')
  for mode in ['wallet','custodial','anonymous']:
   await page.evaluate('(mode)=>{window.__mode=mode;document.dispatchEvent(new Event("auth:changed"));}',mode)
   assert await page.locator('[data-fr="run"]').is_enabled();await page.locator('[data-fr="run"]').click();assert await page.locator('[data-fr="pass"]').inner_text()=='7 / 7 pass'
  checks.append('Wallet, managed and signed-out transitions retain public demo access')
  await page.evaluate("()=>{window.__mode='wallet';document.dispatchEvent(new Event('auth:changed'));}")
  assert await page.locator('[data-panel="indexing"] #indexSampleLoad').is_disabled();assert await page.locator('[data-fr="run"]').is_enabled()
  checks.append('Existing wallet restrictions on managed indexing remain enforced')
  await page.locator('[data-fr="play"]').click();await page.wait_for_timeout(250);await page.locator('[data-view="search"]').first.click()
  before=await page.locator('[data-fr="position"]').input_value();await page.wait_for_timeout(350);assert await page.locator('[data-fr="position"]').input_value()==before
  assert await page.locator('#foodRescue').get_attribute('data-playing')=='false'
  checks.append('Navigating away stops Food Rescue playback')
  if energy:
   await page.locator('[data-view="energyflex"]').click();assert await page.locator('[data-panel="energyflex"]').is_visible();assert await page.locator('[data-ef="saving"]').inner_text()=='A$7.00'
   checks.append('Existing EnergyFlex remains navigable with its unchanged reference result')
  if payment:
   await page.locator('[data-view="payment-guard"]').click();assert await page.locator('[data-panel="payment-guard"]').is_visible();assert await page.locator('[data-pg="prevented"]').inner_text()=='A$4,800.00'
   checks.append('Existing Payment Guard remains navigable with its unchanged reference result')
  await page.locator('[data-view="food-rescue"]').click();await page.locator('#refreshView').click();assert await page.locator('[data-fr="pass"]').inner_text()=='7 / 7 pass'
  await page.locator('[data-fr="capacity"]').fill('80');await page.locator('[data-fr="capacity"]').dispatch_event('input');await page.locator('#refreshView').click()
  assert await page.locator('[data-fr="export"]').is_disabled();assert await page.locator('[data-fr="rescued"]').inner_text()=='—'
  await page.locator('[data-fr="run"]').click()
  requests=await page.evaluate('window.__requests');assert not any(r['method']!='GET' or '/admin/' in r['path'] or 'food-rescue' in r['path'] or 'l402' in r['path'] for r in requests),requests
  assert await page.evaluate('window.__loginOpened')==0
  checks.append('Refresh preserves stale-input protection and makes no mutation, privileged or demo API call')
  await page.locator('[data-fr="play"]').click();await page.evaluate("window.dispatchEvent(new Event('beforeunload'))")
  before=await page.locator('[data-fr="position"]').input_value();await page.wait_for_timeout(350);assert await page.locator('[data-fr="position"]').input_value()==before
  assert not errors,errors;checks.append('Disposal stops timers with no console exceptions')
  await browser.close()
 report={'status':'passed','count':len(checks),'checks':checks,'scope':'Retrieved production console plus prior EnergyFlex/Payment Guard. Actual demo modules; synthetic authentication/API; unrelated controllers stubbed. Not live server acceptance.'}
 OUT.mkdir(parents=True,exist_ok=True);(OUT/'console-results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':asyncio.run(main())
