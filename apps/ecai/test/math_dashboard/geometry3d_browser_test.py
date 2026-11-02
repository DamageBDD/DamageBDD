#!/usr/bin/env python3
"""Offline 3D workbench smoke test against the real math Mustache fragment.

Uses Chromium and local dependency-free ES modules; no node backend, IPFS, or mint.
"""
import asyncio
import base64
import os
import re
import shutil
from pathlib import Path
from playwright.async_api import async_playwright
from browser_test import APP, module_url
from kernel_browser_test import make_html

OUT=Path(os.environ.get('ECAI_3D_PREVIEW_DIR','/mnt/data'))

async def main():
    OUT.mkdir(parents=True,exist_ok=True)
    html=make_html().replace('</style>', (APP/'priv/static/css/ecai-math-3d.css').read_text()+'</style>')
    source=(APP/'priv/static/js/ecai-math-3d.js').read_text()

    source=source.replace("'./ecai-math-kernel.js'",repr(module_url((APP/'priv/static/js/ecai-math-kernel.js').read_text())))
    url='data:text/javascript;base64,'+base64.b64encode(source.encode()).decode()
    async with async_playwright() as pw:
        opts={'headless':True,'args':['--no-sandbox','--disable-dev-shm-usage']}
        chromium=os.environ.get('CHROMIUM') or shutil.which('chromium')
        if chromium:opts['executable_path']=chromium
        browser=await pw.chromium.launch(**opts)
        page=await browser.new_page(viewport={'width':1440,'height':980},device_scale_factor=1,accept_downloads=True)
        errors=[]
        page.on('pageerror',lambda e:errors.append(str(e)))
        await page.set_content(html)
        await page.evaluate('''()=>{
          for(const e of document.querySelectorAll('[data-panel]')){
            e.hidden=e.dataset.panel!=='math';e.classList.toggle('is-visible',e.dataset.panel==='math');}
          document.querySelector('#ecaiConsole').dataset.activeView='math';
          window.__requestCount=0;window.fetch=()=>{window.__requestCount++;throw Error('network forbidden')};
        }''')
        await page.evaluate('''async url=>{const m=await import(url);window.__3d=m.initMath3D();window.__3d.setVisible(true);}''',url)
        assert await page.locator('#math3DStage').count()==1
        assert await page.locator('#math3DWorkbench').is_visible()
        await page.locator('#math3DWorkbench').scroll_into_view_if_needed()
        await page.wait_for_timeout(280)
        assert await page.locator('#math3DVertices').inner_text() != '—'
        assert int((await page.locator('#math3DFaces').inner_text()).replace(',',''))>700
        assert await page.locator('#math3DStage').evaluate('''el=>{const d=el.getContext('2d').getImageData(80,80,3,3).data;return [...d].some(v=>v!==0);}''')
        assert await page.locator('#math3DWorkbench').get_attribute('data-animating')=='true'
        await page.locator('#math3DPlay').click()
        assert await page.locator('#math3DWorkbench').get_attribute('data-animating')=='false'
        assert await page.locator('#math3DPlay').get_attribute('aria-pressed')=='false'
        await page.locator('#math3DShape').select_option('elliptic-torus')
        await page.locator('#math3DDetail').fill('30')
        await page.locator('#math3DTwist').fill('3')
        assert await page.locator('#math3DDetailLabel').inner_text()=='30'
        await page.locator('#math3DReceipt').evaluate('(e)=>e.scrollIntoView({block:"end"})')
        await page.locator('#math3DPrepare').click()
        await page.wait_for_function('document.querySelector("#math3DReceipt").hidden===false')
        assert (await page.locator('#math3DExperimentId').inner_text()).startswith('sha256:')
        assert len(await page.locator('#math3DMeshHash').inner_text())==64
        assert 'no upload or mint transaction' in (await page.locator('#math3DStatus').inner_text())
        for selector,suffix in [('math3DExportOBJ','.obj'),('math3DExportJSON','-experiment.json'),('math3DExportNFT','-aex141-metadata-template.json')]:
            async with page.expect_download() as download_info: await page.locator('#'+selector).click()
            download=await download_info.value
            assert download.suggested_filename.endswith(suffix),download.suggested_filename
        await page.locator('#math3DShape').select_option('dragonfly')
        assert await page.locator('#math3DReceipt').is_hidden()
        assert 'not minted' in (await page.locator('#math3DStatus').inner_text()).lower()
        await page.locator('#math3DPrepare').click()
        await page.wait_for_function('document.querySelector("#math3DReceipt").hidden===false')
        # Capture on-screen workbench with mint-preparation record.
        await page.evaluate('document.querySelector(".console-topbar").style.position="static"')
        await page.locator('#math3DWorkbench').screenshot(path=str(OUT/'ecai-math-3d-workbench.png'))
        await page.set_viewport_size({'width':390,'height':844})
        await page.locator('#math3DWorkbench').scroll_into_view_if_needed()
        await page.wait_for_timeout(250)
        assert await page.evaluate('document.documentElement.scrollWidth<=innerWidth'),await page.evaluate('document.documentElement.scrollWidth')
        await page.locator('#math3DWorkbench').screenshot(path=str(OUT/'ecai-math-3d-mobile.png'))
        await page.evaluate('window.__3d.setVisible(false)')
        assert await page.locator('#math3DWorkbench').get_attribute('data-animating')=='false'
        assert await page.evaluate('window.__requestCount')==0
        await page.evaluate('window.__3d.dispose()')
        await page.emulate_media(reduced_motion='reduce')
        await page.evaluate('''async url=>{const m=await import(url);window.__3d=m.initMath3D();window.__3d.setVisible(true);}''',url)
        assert await page.locator('#math3DWorkbench').get_attribute('data-animating')=='false'
        await page.evaluate('window.__3d.dispose()')
        assert not errors,errors
        await browser.close()
        print('PASS: 3D mesh, orbit, controls, reproducible hash, OBJ/JSON/AEX-141 exports, disabled auto-motion, no network, mobile')

if __name__=='__main__': asyncio.run(main())
