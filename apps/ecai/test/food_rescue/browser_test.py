#!/usr/bin/env python3
"""Actual UI + model in Chromium. Default: offline DOM; test-only SHA adapter.
FR_TEST_HTTP=1 serves real assets on loopback with native Web Crypto.
Neither mode is live Cowboy/auth/DamageBDD acceptance.
"""
import asyncio,base64,functools,hashlib,http.server,importlib.util,json,os,re,shutil,threading
from pathlib import Path
from playwright.async_api import async_playwright
APP=Path(os.environ.get('ECAI_APP',Path(__file__).resolve().parents[2]))
OUT=Path(os.environ.get('FR_TEST_OUT','/tmp/food-rescue-browser'))
def module(source):return 'data:text/javascript;base64,'+base64.b64encode(source.encode()).decode()
def module_urls():
 model=module((APP/'priv/static/js/food-rescue-model.js').read_text())
 ui=module((APP/'priv/static/js/ecai-food-rescue.js').read_text().replace("'./food-rescue-model.js?v=food-rescue-v1'",repr(model)))
 return model,ui
def fixture_html():
 h=(APP/'priv/static/food-rescue/index.html').read_text();h=re.sub(r'<script\b[^>]*>.*?</script>','',h,flags=re.S);h=re.sub(r'<link\b[^>]*>','',h)
 css=(APP/'priv/static/css/ecai-food-rescue.css').read_text()+(APP/'priv/static/food-rescue/standalone.css').read_text()
 return h.replace('</head>','<style>'+css+'</style></head>')
def verifier():
 s=importlib.util.spec_from_file_location('frverify',APP/'tools/verify_food_rescue.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*args):pass
def server():
 s=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Quiet,directory=str(APP/'priv')))
 threading.Thread(target=s.serve_forever,daemon=True).start();return s
async def main():
 OUT.mkdir(parents=True,exist_ok=True);checks=[];errors=[];requests=[];http_mode=os.environ.get('FR_TEST_HTTP')=='1';httpd=server() if http_mode else None
 try:
  async with async_playwright() as p:
   browser=await p.chromium.launch(executable_path=os.environ.get('CHROMIUM') or shutil.which('chromium'),headless=True,args=['--no-sandbox'])
   page=await browser.new_page(viewport={'width':1440,'height':1080},accept_downloads=True)
   page.on('pageerror',lambda e:errors.append(str(e)));page.on('request',lambda r:requests.append((r.url,r.method)))
   origin=f'http://127.0.0.1:{httpd.server_port}' if http_mode else ''
   if http_mode:await page.goto(origin+'/static/food-rescue/index.html')
   else:
    await page.set_content(fixture_html());await page.evaluate("()=>{window.fetch=()=>{throw Error('Unexpected demo fetch')};}")
    await page.evaluate('async url=>{const m=await import(url);document.getElementById("foodRescue").hidden=false;window.__fr=m.initFoodRescue({visible:true});}',module_urls()[1])
   q=lambda name:page.locator(f'[data-fr="{name}"]')
   await page.wait_for_function("document.querySelector('[data-fr=rescued]').textContent==='400 kg'")
   assert await q('uplift').inner_text()=='+40 kg';assert await q('pass').inner_text()=='7 / 7 pass';assert await page.locator('[data-fr-scenario]').count()==8
   checks.append('Anonymous reference: 400kg rescued vs 360kg baseline; eight scenarios; seven checks')
   await page.screenshot(path=str(OUT/'food-rescue-desktop.png'),full_page=True)
   await q('position').fill('10');await q('position').dispatch_event('input');await page.locator('.fr-stage-grid').screenshot(path=str(OUT/'food-rescue-map.png'))
   assert 'VAN-' not in await q('map').inner_text() # compact van labels use A/B
   assert '160 kg' in await q('map').inner_text()
   checks.append('Schematic map renders moving van loads and route paths at replay time')
   await q('tour-open').click();assert await q('tour').is_visible()
   for _ in range(3):await q('tour-next').click()
   assert await q('tour-counter').inner_text()=='04 OF 04';await q('tour-next').click();assert await q('tour').is_hidden()
   assert await q('tour-open').evaluate('(n)=>n===document.activeElement')
   checks.append('Four-step guided tour completes and restores keyboard focus')
   expected={'road-closure':400,'cold-chain':330,'missing-record':340,'recall':310,'late-recall':310,'demand-surge':400,'van-outage':290}
   for scenario,kg in expected.items():
    await page.locator(f'[data-fr-scenario="{scenario}"]').click();assert await q('rescued').inner_text()==f'{kg} kg';assert await q('pass').inner_text()=='7 / 7 pass'
   checks.append('Every preset computes its scenario-specific delivered, held and unmet quantities')
   await page.locator('[data-fr-scenario="missing-record"]').click();assert await q('held').inner_text()=='0 / 60 kg';assert 'Unverifiable' in await q('lots').inner_text()
   await page.locator('[data-fr-scenario="cold-chain"]').click();assert await q('held').inner_text()=='70 / 0 kg';assert 'Quarantined' in await q('lots').inner_text()
   checks.append('Missing evidence remains unknown, separate from warm-telemetry quarantine')
   await page.locator('[data-fr-scenario="late-recall"]').click()
   for t,expected in [('29','No active recall'),('30','HOLD ACTIVE')]:
    await q('position').fill(t);await q('position').dispatch_event('input');assert await q('recall-badge').inner_text()==expected
   assert 'Recipient recall hold' in await q('recall').inner_text();assert 'Community kitchen' in await q('recall').inner_text()
   assert '90 kg placed on hold' in await q('held-note').inner_text();assert await q('rescued').inner_text()=='310 kg'
   await page.locator('.fr-recall-card').screenshot(path=str(OUT/'food-rescue-recall.png'))
   checks.append('09:30 recall traces both dairy lots to kitchen holds and excludes 90kg from final rescued totals')
   await page.locator('[data-fr-destination="kitchen"]').click();assert await q('lots').locator('.fr-lot').count()==3
   await q('show-all').click();assert await q('lots').locator('.fr-lot').count()==6
   await page.locator('[data-fr-node="pantry"]').focus();await page.keyboard.press('Enter');assert await q('lots').locator('.fr-lot').count()==2
   await q('show-all').click()
   checks.append('Recipient and map keyboard controls filter lot traceability without altering the plan')
   await q('path').select_option('baseline');assert 'simple dispatch' in await q('map-state').inner_text();assert await q('rescued').inner_text()=='310 kg'
   await q('path').select_option('rescue');await q('position').fill('270');await q('position').dispatch_event('input');assert '310 kg' in await q('live-counts').inner_text()
   checks.append('Selected-plan replay and final rescue-plan metrics remain explicitly separated')
   await q('capacity').fill('80');await q('capacity').dispatch_event('input');assert await q('stale').is_visible();assert await q('rescued').inner_text()=='—'
   assert await q('export').is_disabled();assert await q('play').is_disabled()
   await q('stale-check').click();assert 'Stale snapshot rejected' in await q('message').inner_text()
   await q('run').click();assert await q('stale').is_hidden();assert await q('export').is_enabled()
   checks.append('Control changes invalidate metrics, playback and export; stale schedule checking is explicit')
   await page.locator('[data-fr-scenario="road-closure"]').click();assert 'BRIDGE CLOSED' in await q('map').inner_text()
   await q('delay').select_option('15');await q('run').click();assert await q('rescued').inner_text()!='400 kg'
   checks.append('Bridge closure uses the detour; dispatch delay exposes expiry losses rather than silent repair')
   await q('challenge').click();assert 'Blocked: YOG-04: Recalled batch DAIRY-42' in await q('challenge-result').inner_text()
   await q('suite').click();assert '112 / 112' in await q('challenge-result').inner_text();assert 'No remote DamageBDD run' in await q('challenge-result').inner_text()
   checks.append('Forged recalled-lot release is rejected; eight-scenario local suite runs from the UI')
   await q('reset').click();await q('play').click();await page.wait_for_timeout(350);assert int(await q('position').input_value())>0
   await q('play').click();at=await q('position').input_value();await page.wait_for_timeout(250);assert await q('position').input_value()==at
   await q('position').focus();await page.keyboard.press('ArrowRight');assert int(await q('position').input_value())==int(at)+1
   await q('next').click();assert int(await q('position').input_value())>int(at)+1
   checks.append('Playback, pause, next-event and keyboard scrubbing work without creating new deliveries')
   await q('play').click();await q('lots').locator('summary').first.click();assert await page.locator('#foodRescue').get_attribute('data-playing')=='false'
   await q('lots').locator('summary').first.click()
   checks.append('Inspecting lot evidence pauses animation so details remain readable')
   file=OUT/'browser-export.evidence.json'
   if http_mode:
    async with page.expect_download() as info:await q('export').click()
    await (await info.value).save_as(str(file))
   else:
    if not await page.evaluate('!!crypto.subtle'):
     await q('export').click();assert 'HTTPS or localhost' in await q('message').inner_text()
    await page.expose_function('__testSHA',lambda data:hashlib.sha256(bytes(data)).hexdigest())
    await page.evaluate('''()=>{
      Object.defineProperty(crypto,'subtle',{configurable:true,value:{digest:async(algorithm,bytes)=>{if(algorithm!=='SHA-256')throw Error('Unexpected hash');const h=await window.__testSHA(Array.from(new Uint8Array(bytes)));return Uint8Array.from(h.match(/../g),x=>parseInt(x,16)).buffer;}}});
      window.__exported=null;const create=URL.createObjectURL.bind(URL);URL.createObjectURL=blob=>{blob.text().then(t=>window.__exported=t);return create(blob);};document.addEventListener('click',e=>{if(e.target.closest('a[download]'))e.preventDefault();},true);
    }''')
    await q('export').click();await page.wait_for_function('window.__exported!==null');file.write_text(await page.evaluate('window.__exported'))
   assert verifier().verify(verifier().load(file))['status']=='verified'
   checks.append('UI-exported evidence reconstructs independently in Python'+(' with native Web Crypto' if http_mode else ' (test-only SHA adapter; secure-context error also checked)'))
   if not http_mode:
    await page.evaluate('''()=>{window.__exported=null;window.__originalDigest=crypto.subtle.digest;crypto.subtle.digest=async(...args)=>{await new Promise(resolve=>window.__releaseDigest=resolve);return window.__originalDigest(...args);};}''')
    await q('export').click();await page.wait_for_function('!!window.__releaseDigest');await page.locator('[data-fr-scenario="recall"]').click();await page.evaluate('window.__releaseDigest()');await page.wait_for_timeout(100)
    assert await page.evaluate('window.__exported') is None;await page.evaluate('()=>{crypto.subtle.digest=window.__originalDigest;}')
    checks.append('A scenario change during hashing prevents stale export')
   await q('present').click();assert await page.evaluate('document.fullscreenElement===document.getElementById("foodRescue")||document.getElementById("foodRescue").dataset.present==="true"')
   await q('present').click();checks.append('Presentation mode enters and exits without losing the scenario')
   await page.emulate_media(reduced_motion='reduce');await q('play').click();assert await page.locator('#foodRescue').get_attribute('data-playing')=='false';assert 'Reduced motion' in await q('message').inner_text()
   checks.append('Reduced-motion preference disables automatic movement and explains manual replay')
   for width in [390,320]:
    await page.set_viewport_size({'width':width,'height':844});assert not await page.evaluate('document.documentElement.scrollWidth>innerWidth'),f'overflow at {width}'
    assert not await page.locator('.fr-metric strong').evaluate_all('(nodes)=>nodes.some(n=>n.scrollWidth>n.clientWidth)'),f'metric clipping at {width}'
    assert await q('run').is_enabled()
    if width==390:await page.screenshot(path=str(OUT/'food-rescue-mobile.png'),full_page=True)
   checks.append('390px and 320px layouts retain all controls without page overflow or metric clipping')
   assert (all(url.startswith(origin+'/static/') and method=='GET' for url,method in requests) if http_mode else not requests),requests
   assert not errors,errors;checks.append('No API, external, model, payment or dispatch requests; no browser exceptions')
   await browser.close()
 finally:
  if httpd:httpd.shutdown();httpd.server_close()
 report={'status':'passed','count':len(checks),'checks':checks,'scope':('Native localhost assets and Web Crypto.' if http_mode else 'Actual UI/model in offline DOM; test-only SHA adapter for export. HTTP navigation blocked by build environment.')+' No live Erlang server or real deliveries.'}
 (OUT/'browser-results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':asyncio.run(main())
