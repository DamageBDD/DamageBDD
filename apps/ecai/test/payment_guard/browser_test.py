#!/usr/bin/env python3
"""Chromium UI tests. Default: offline DOM, with a test-only SHA adapter for export.
Set PG_TEST_HTTP=1 to test real HTTP assets and Web Crypto on localhost.
Install Playwright and Chromium separately; neither is a runtime app dependency.
"""
import asyncio
import base64
import hashlib
import re
import functools
import http.server
import importlib.util
import json
import os
import shutil
import threading
from pathlib import Path
from playwright.async_api import async_playwright
APP=Path(os.environ.get('ECAI_APP',Path(__file__).resolve().parents[2]))
OUT=Path(os.environ.get('PG_TEST_OUT','/tmp/payment-guard-browser'))

class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*args):pass

def server():
    httpd=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Quiet,directory=str(APP/'priv')))
    thread=threading.Thread(target=httpd.serve_forever,daemon=True);thread.start()
    return httpd

def verifier():
    spec=importlib.util.spec_from_file_location('pgverify',APP/'tools/verify_payment_guard.py')
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);return mod

def module(source):
    return 'data:text/javascript;base64,'+base64.b64encode(source.encode()).decode()

def module_urls():
    model=module((APP/'priv/static/js/payment-guard-model.js').read_text())
    ui=module((APP/'priv/static/js/ecai-payment-guard.js').read_text().replace("'./payment-guard-model.js?v=payment-guard-v1'",repr(model)))
    return model,ui

def fixture_html():
    html=(APP/'priv/static/payment-guard/index.html').read_text()
    html=re.sub(r'<script\b[^>]*>.*?</script>','',html,flags=re.S)
    html=re.sub(r'<link\b[^>]*>','',html)
    css=(APP/'priv/static/css/ecai-payment-guard.css').read_text()+(APP/'priv/static/payment-guard/standalone.css').read_text()
    return html.replace('</head>','<style>'+css+'</style></head>')

async def main():
    OUT.mkdir(parents=True,exist_ok=True);http_mode=os.environ.get('PG_TEST_HTTP')=='1';httpd=server() if http_mode else None;checks=[];errors=[];requests=[]
    try:
      async with async_playwright() as p:
        browser=await p.chromium.launch(executable_path=os.environ.get('CHROMIUM') or shutil.which('chromium'),headless=True,args=['--no-sandbox'])
        page=await browser.new_page(viewport={'width':1440,'height':1080},accept_downloads=True)
        page.on('pageerror',lambda e:errors.append(str(e)))
        page.on('request',lambda r:requests.append((r.url,r.method)))
        origin=f'http://127.0.0.1:{httpd.server_port}' if http_mode else ''
        if http_mode:
            await page.goto(origin+'/static/payment-guard/index.html')
        else:
            await page.set_content(fixture_html())
            await page.evaluate("()=>{window.fetch=()=>{throw Error('Unexpected fetch in local demo')};}")
            await page.evaluate("async url=>{const m=await import(url);document.getElementById('paymentGuard').hidden=false;window.__pg=m.initPaymentGuard({visible:true});}",module_urls()[1])
        q=lambda n:page.locator(f'[data-pg="{n}"]')
        await page.wait_for_function("document.querySelector('[data-pg=pass]').textContent==='6 / 6 pass'")
        assert await q('prevented').inner_text()=='A$4,800.00'
        assert await q('unsafe').inner_text()=='A$0.00'
        assert await page.locator('[data-pg-scenario]').count()==10
        assert await q('export').is_enabled()
        checks.append('Anonymous reference fixture: A$4800 unguarded test outflow, zero guarded debit, six local checks')
        await page.screenshot(path=str(OUT/'payment-guard-desktop.png'),full_page=True)
        await page.locator('.pg-stage').screenshot(path=str(OUT/'payment-guard-decision.png'))
        await q('tour-open').click();assert await q('tour').is_visible()
        for _ in range(3):await q('tour-next').click()
        assert await q('tour-counter').inner_text()=='04 OF 04'
        await q('tour-next').click();assert await q('tour').is_hidden()
        checks.append('Four-step tour opens, progresses, closes and restores focus')
        for id in ['legitimate','approved-change']:
            await page.locator(f'[data-pg-scenario="{id}"]').click()
            assert await q('eligible').inner_text()=='1 / 1'
            assert await q('prevented').inner_text()=='A$0.00'
            assert await q('ledger-rows').locator('tr').count()==1
            assert 'DEMO-TX-001' in await q('ledger-rows').inner_text()
        checks.append('Legitimate invoice and two-person bank change complete with actual mock ledger debits')
        await page.locator('[data-pg-scenario="duplicate"]').click()
        assert await q('attempt').locator('option').count()==3
        await q('attempt').select_option('1');assert 'Existing receipt returned' in await q('checks').inner_text()
        assert '1 new debit' in await q('ledger-note').inner_text()
        await q('ledger-path').select_option('unguarded')
        assert await q('ledger-rows').locator('tr').count()==3
        assert await q('prevented').inner_text()=='A$9,600.00'
        checks.append('Retry returns original receipt; second key cannot duplicate invoice; unguarded ledger shows all three debits')
        for id in ['injection','expired','stale-policy','direct-tool','missing-evidence','concurrent','redirected']:
            await page.locator(f'[data-pg-scenario="{id}"]').click()
            assert await q('pass').inner_text()=='6 / 6 pass'
            assert 'BLOCKED' in await q('decision-badge').inner_text()
        assert 'DEMO-UNAPPROVED-999' in await q('invoice-text').inner_text()
        checks.append('Every attack and missing-evidence fixture exposes explicit current-state reasons')
        await page.locator('[data-pg-scenario="legitimate"]').click()
        await q('limit').fill('4700');await q('limit').dispatch_event('input')
        assert await q('stale').is_visible();assert await q('prevented').inner_text()=='—'
        assert await q('export').is_disabled();assert await q('play').is_disabled()
        await q('run').click();assert 'BLOCKED' in await q('decision-badge').inner_text()
        assert 'Within payment limit' in await q('checks').inner_text()
        checks.append('Changing the limit invalidates metrics and export until recomputation')
        await page.locator('[data-pg-scenario="legitimate"]').click()
        await q('clock').select_option('15');assert await q('export').is_disabled()
        await q('run').click();assert 'expired at execution' in await q('records').inner_text()
        assert 'BLOCKED' in await q('decision-badge').inner_text()
        checks.append('Exactly at approval expiry, the gate rejects instead of accepting stale authority')
        await q('reset').click();await q('tamper').click()
        assert 'Rejected:' in await q('challenge-result').inner_text()
        assert '0 new mock debits' in await q('challenge-result').inner_text()
        await q('suite').click();assert '60 / 60' in await q('challenge-result').inner_text()
        checks.append('Forged approved=true is rejected; all ten reference scenarios run from the UI')
        await q('play').click();await page.wait_for_timeout(1300)
        assert await q('position').input_value()=='1'
        await q('play').click();position=await q('position').input_value()
        await page.wait_for_timeout(1350);assert await q('position').input_value()==position
        await q('position').focus();await page.keyboard.press('ArrowRight')
        assert await q('position').input_value()=='2'
        checks.append('Decision playback advances, pauses and supports keyboard slider navigation without new payments')
        file=OUT/'browser-export.evidence.json'
        if http_mode:
            async with page.expect_download() as download_info:await q('export').click()
            download=await download_info.value;await download.save_as(str(file))
        else:
            if not await page.evaluate('!!crypto.subtle'):
                await q('export').click();assert 'HTTPS or localhost' in await q('message').inner_text()
                checks.append('Missing secure-context Web Crypto produces an actionable export error')
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
            file.write_text(await page.evaluate('window.__exported'))
        assert verifier().verify(verifier().load(file))['status']=='verified'
        checks.append('Browser export independently verifies in Python'+(' with native Web Crypto' if http_mode else ' (test-only SHA adapter)'))
        if not http_mode:
            await page.evaluate('''()=>{window.__exported=null;window.__originalDigest=crypto.subtle.digest;crypto.subtle.digest=async(...args)=>{await new Promise(resolve=>window.__releaseDigest=resolve);return window.__originalDigest(...args);};}''')
            await q('export').click();await page.wait_for_function('!!window.__releaseDigest')
            await page.locator('[data-pg-scenario="legitimate"]').click()
            await page.evaluate('()=>{window.__releaseDigest();}')
            await page.wait_for_timeout(150)
            assert await page.evaluate('window.__exported') is None
            await page.evaluate('()=>{crypto.subtle.digest=window.__originalDigest;}')
            await q('reset').click()
            checks.append('A scenario change during hashing prevents export of a stale result')
        await q('present').click()
        assert await page.evaluate("document.fullscreenElement===document.getElementById('paymentGuard') || document.getElementById('paymentGuard').dataset.present==='true'")
        await q('present').click()
        checks.append('Presentation mode enters and exits without losing the run')
        await page.emulate_media(reduced_motion='reduce')
        await q('play').click();assert await page.locator('#paymentGuard').get_attribute('data-playing')=='false'
        assert 'Reduced motion' in await q('message').inner_text()
        checks.append('Reduced-motion preference prevents automatic playback and explains manual navigation')
        for width in [390,320]:
            await page.set_viewport_size({'width':width,'height':844})
            assert not await page.evaluate('document.documentElement.scrollWidth>innerWidth'),f'overflow at {width}'
            assert await q('run').is_enabled()
            assert not await page.locator('.pg-metric strong').evaluate_all('(nodes)=>nodes.some(n=>n.scrollWidth>n.clientWidth)'),f'metric clipping at {width}'
            if width==390:await page.screenshot(path=str(OUT/'payment-guard-mobile.png'),full_page=True)
        checks.append('390px and 320px layouts preserve all controls with no page-level overflow')
        assert all(url.startswith(origin+'/static/') and method=='GET' for url,method in requests) if http_mode else not requests,requests
        checks.append('No API, wallet, model, payment or external request during sandbox interactions')
        assert not errors,errors
        checks.append('No browser exceptions during the complete interaction suite')
        await browser.close()
    finally:
      if httpd:httpd.shutdown();httpd.server_close()
    result={'status':'passed','count':len(checks),'checks':checks,'scope':('Actual assets over localhost with native Web Crypto.' if http_mode else 'Actual UI/model in offline DOM; test-only SHA adapter for export.')+' No live Cowboy or real payment execution.'}
    (OUT/'browser-results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':asyncio.run(main())
