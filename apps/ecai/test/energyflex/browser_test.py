#!/usr/bin/env python3
"""Offline Chromium acceptance tests, using the actual EnergyFlex source/assets.

No network service is required. Browser policy can block all navigation: tests
use set_content and module data URLs. Export UI is tested with a test-only Python
SHA-256 adapter because about:blank has no WebCrypto secure context. The real
WebCrypto call is separately exercised by the Node model tests.
Requires the Python playwright package and Chromium (or CHROMIUM env var).
"""
from __future__ import annotations
import asyncio
import base64
import hashlib
import importlib.util
import json
import os
import re
import shutil
from pathlib import Path
from playwright.async_api import async_playwright
APP=Path(__file__).resolve().parents[2]
OUT=Path(os.environ.get('ENERGYFLEX_TEST_OUT','/tmp/energyflex-browser'))

def module(source: str) -> str:
 return 'data:text/javascript;base64,'+base64.b64encode(source.encode()).decode()

def module_urls():
 checker=module((APP/'priv/static/js/energyflex-checker.js').read_text())
 model=module((APP/'priv/static/js/energyflex-model.js').read_text().replace("'./energyflex-checker.js'",repr(checker)))
 ui=module((APP/'priv/static/js/ecai-energyflex.js').read_text().replace("'./energyflex-model.js'",repr(model)))
 return checker,model,ui

def fixture():
 html=(APP/'priv/static/energyflex/index.html').read_text()
 html=re.sub(r'<script\b[^>]*>.*?</script>','',html,flags=re.S)
 html=re.sub(r'<link\b[^>]*>','',html)
 css=(APP/'priv/static/css/ecai-energyflex.css').read_text()+(APP/'priv/static/energyflex/standalone.css').read_text()
 return html.replace('</head>','<style>'+css+'</style></head>')

async def main():
 OUT.mkdir(parents=True,exist_ok=True)
 checks=[];errors=[]
 async with async_playwright() as p:
  browser=await p.chromium.launch(executable_path=os.environ.get('CHROMIUM') or shutil.which('chromium') or shutil.which('chromium-browser'),headless=True,args=['--no-sandbox'])
  page=await browser.new_page(viewport={'width':1460,'height':1060},device_scale_factor=1)
  page.on('pageerror',lambda e:errors.append(str(e)))
  await page.set_content(fixture())
  await page.evaluate('''()=>{window.__requests=[];window.fetch=(...args)=>{window.__requests.push(args);throw Error('Unexpected demo network call');};}''')
  await page.evaluate('''async url=>{const m=await import(url);document.getElementById('energyFlex').hidden=false;window.__demo=m.initEnergyFlex({visible:true});}''',module_urls()[2])
  q=lambda name:page.locator(f'[data-ef="{name}"]')
  assert await q('saving').inner_text()=='A$7.00'
  assert await q('cost').inner_text()=='A$20.35'
  assert await q('passed').inner_text()=='6 / 6 pass'
  assert await page.locator('[data-ef-scenario]').count()==5
  assert not await page.locator('#energyFlex').get_attribute('data-ecai-managed')
  checks.append('Anonymous local reference computes 700-cent savings and six passing constraints')
  await page.screenshot(path=str(OUT/'energyflex-desktop.png'),full_page=True)
  await q('tour-open').click();assert await q('tour').is_visible()
  for _ in range(3):await q('tour-next').click()
  assert '4 OF 4' in await q('tour-counter').inner_text()
  await q('tour-next').click();assert not await q('tour').is_visible()
  checks.append('Four-step guided tour opens, advances and closes')
  await q('play').click();await page.wait_for_timeout(1150);assert await q('clock').inner_text()=='18:00'
  await page.evaluate('window.__demo.setVisible(false)');time=await q('clock').inner_text()
  await page.wait_for_timeout(1100);assert await q('clock').inner_text()==time
  await page.evaluate('window.__demo.setVisible(true)')
  checks.append('Replay advances and stops when the workspace is hidden')
  await q('plan').select_option('earliest');assert '18 kW peak'==await q('peak').inner_text()
  await q('plan').select_option('tariff');assert '17 kW peak'==await q('peak').inner_text()
  checks.append('Plan switching uses each strategy’s actual load')
  await q('squeeze').click();assert 'Previous plan rejected' in await q('stale').inner_text()
  assert await q('export').is_disabled();assert await q('saving').inner_text()=='—'
  await q('run').click();assert await q('passed').inner_text()=='6 / 6 pass'
  assert '16 kW' in await q('capacity-value').inner_text();assert await q('stale').is_hidden()
  checks.append('Capacity changes invalidate old savings/export and re-planning restores a valid result')
  await q('tamper').click();assert 'Rejected:' in await q('test-result').inner_text()
  checks.append('Duplicate-hour fault is rejected without altering the valid plan')
  await page.locator('[data-ef-scenario="impossible"]').click()
  assert await q('cost').inner_text()=='No plan';assert await q('play').is_disabled();assert await q('saving').inner_text()=='—'
  assert 'Only 38 kWh' in await q('message').inner_text()
  checks.append('Infeasible scenario is explicit; no invented cost saving or pass')
  await page.locator('[data-ef-scenario="price-spike"]').click();assert await q('passed').inner_text()=='6 / 6 pass'
  await page.locator('[data-ef-scenario="early-departure"]').click();assert await q('departure').input_value()=='2'
  await q('departure').select_option('4');assert await q('saving').inner_text()=='—'
  await q('run').click();assert await q('passed').inner_text()=='6 / 6 pass'
  checks.append('Every disruption and manual departure control recomputes consistently')
  await q('reset').click()
  await page.locator('[data-ef-slot="2"]').focus();await page.keyboard.press('Enter')
  assert await q('clock').inner_text()=='19:00'
  checks.append('Chart hour selection works with keyboard input')
  if not await page.evaluate('!!crypto.subtle'):
   await q('export').click();assert 'HTTPS or localhost' in await q('message').inner_text()
   checks.append('Insecure-context export fails with an actionable message')
  await page.expose_function('__testSHA',lambda data:hashlib.sha256(bytes(data)).hexdigest())
  await page.evaluate('''()=>{
   Object.defineProperty(crypto,'subtle',{configurable:true,value:{digest:async(algorithm,bytes)=>{
    if(algorithm!=='SHA-256')throw Error('unexpected digest');
    const h=await window.__testSHA(Array.from(new Uint8Array(bytes)));
    return Uint8Array.from(h.match(/../g),x=>parseInt(x,16)).buffer;
   }}});
   window.__exported=null;const create=URL.createObjectURL.bind(URL);
   URL.createObjectURL=blob=>{blob.text().then(t=>window.__exported=t);return create(blob);};
   document.addEventListener('click',e=>{if(e.target.closest('a[download]'))e.preventDefault();},true);
  }''')
  await q('export').click();await page.wait_for_function('window.__exported!==null')
  raw=await page.evaluate('window.__exported');(OUT/'browser-export.evidence.json').write_text(raw)
  spec=importlib.util.spec_from_file_location('verify',APP/'tools/verify_energyflex.py');verify=importlib.util.module_from_spec(spec);spec.loader.exec_module(verify)
  assert verify.verify(json.loads(raw))['saving_cents']==700
  checks.append('Export UI produces independently replayable evidence (test-only digest adapter)')
  await q('present').click()
  assert await page.evaluate("document.fullscreenElement===document.getElementById('energyFlex') || document.getElementById('energyFlex').dataset.present==='true'")
  await page.keyboard.press('Escape');await q('reset').click()
  checks.append('Presentation mode works, including fullscreen-denied fallback')
  await page.emulate_media(reduced_motion='reduce');await q('play').click()
  assert await page.locator('#energyFlex').get_attribute('data-playing')=='false'
  await q('play').click()
  checks.append('Reduced-motion preference disables animated power-flow effects')
  for width in [390,320]:
   await page.set_viewport_size({'width':width,'height':844})
   assert not await page.evaluate('document.documentElement.scrollWidth > window.innerWidth'),f'overflow at {width}'
   assert await q('run').is_enabled()
   if width==390:await page.screenshot(path=str(OUT/'energyflex-mobile.png'),full_page=True)
  checks.append('390px and 320px mobile layouts have no page-level horizontal overflow')
  assert await page.evaluate('window.__requests.length')==0
  checks.append('All demo interactions make zero fetch requests')
  await page.evaluate('window.__demo.dispose()')
  assert not errors,errors
  checks.append('No browser exceptions, including disposal')
  await browser.close()
 report={'status':'passed','count':len(checks),'checks':checks,'scope':'Actual UI/model, offline DOM; browser export uses a test digest adapter; no live Cowboy, authentication backend, ECAI retrieval or DamageBDD execution.'}
 (OUT/'browser-results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))

if __name__=='__main__':asyncio.run(main())
