#!/usr/bin/env python3
"""Guided #math journey in Chromium, real templates/modules with offline fixtures.

This exercises in-panel navigation and the public visualizer. It does not verify
an ECAI node, execute Erlang, or contact the web.
"""
import asyncio
import os
import shutil
from pathlib import Path
from playwright.async_api import async_playwright
from browser_test import APP, MOCK, fixture, module_url
from kernel_browser_test import make_html

OUT=Path(os.environ.get('ECAI_MATH_GUIDE_PREVIEW_DIR','/mnt/data'))


async def main():
    OUT.mkdir(parents=True,exist_ok=True)
    async with async_playwright() as pw:
        browser_opts={'headless':True,'args':['--no-sandbox','--disable-dev-shm-usage']}
        chrome=os.environ.get('CHROMIUM') or shutil.which('chromium')
        if chrome: browser_opts['executable_path']=chrome
        browser=await pw.chromium.launch(**browser_opts)
        page=await browser.new_page(viewport={'width':1440,'height':1000},device_scale_factor=1)
        errors=[]
        page.on('pageerror',lambda error:errors.append(str(error)))
        await page.set_content(make_html())
        await page.evaluate('''() => {
          const view=document.querySelector('[data-panel="math"]');
          for(const panel of document.querySelectorAll('[data-panel]')) {
            panel.hidden=panel!==view;panel.classList.toggle('is-visible',panel===view);
          }
          document.querySelector('#ecaiConsole').dataset.activeView='math';
          document.querySelector('#viewBreadcrumb').textContent='Mathematical paths';
          for(const nav of document.querySelectorAll('[data-view]'))nav.classList.toggle('is-active',nav.dataset.view==='math');
          window.__locationHash=location.hash;
          window.__kernelRequests=0;
        }''')
        await page.evaluate('(example)=>{window.__fixture=example;'+MOCK+'}',fixture())
        await page.evaluate('''async ([paths,kernel])=>{
          const p=await import(paths);
          window.__math=p.initMathPaths({request:window.__request,currentToken:()=>window.__managed?'fixture-token':'',
            managedSession:()=>window.__managed,openLogin:()=>{},toast:()=>{}});
          window.__math.setVisible(true);
          const k=await import(kernel);
          window.__kernel=k.initMathKernel();window.__kernel.setVisible(true);
        }''',[module_url((APP/'priv/static/js/ecai-math-paths.js').read_text()),
               module_url((APP/'priv/static/js/ecai-math-kernel.js').read_text())])
        ids=['mathKernel','mathLibrary','mathBuilderDisclosure','mathResults','mathECAIBridge']
        assert await page.locator('.math-journey-steps button').count()==5
        positions=await page.evaluate('(ids)=>ids.map(id=>document.getElementById(id).getBoundingClientRect().top+window.scrollY)',ids)
        assert positions==sorted(positions),positions
        assert await page.locator('#mathGraph .math-node').count()>0
        assert 'preview' in (await page.locator('#mathStatus').inner_text()).lower()
        assert await page.evaluate('window.__calls.length')==0
        assert await page.locator('#mathKernelStage').count()==1
        assert await page.locator('#mathECAIBridge [data-go="search"]').count()==1
        assert await page.locator('a[href="https://damagebdd.com/ecai/"][rel="noopener noreferrer"]').count()>=1
        assert await page.locator('#mathECAIBridge').get_by_text('not automatically a verified relationship',exact=False).count()==1
        for id in ids:
            button=page.locator(f'.math-journey [data-math-jump="{id}"]')
            await button.click()
            assert await button.get_attribute('aria-current')=='step'
            assert await page.locator('.math-journey button[aria-current="step"]').count()==1
            assert await page.locator(f'#{id}').is_visible()
            if id=='mathBuilderDisclosure':
                assert await page.locator('#mathBuilderDisclosure').evaluate('(el)=>el.open')
                assert await page.locator('#mathDiscoverForm').is_visible()
            assert await page.evaluate('location.hash===window.__locationHash')
        # Test the same progression using the integrated next-stage actions.
        await page.locator('#mathKernel [data-math-jump="mathLibrary"]').click()
        assert await page.locator('.math-journey [data-math-jump="mathLibrary"]').get_attribute('aria-current')=='step'
        await page.locator('#mathLibrary [data-math-jump="mathBuilderDisclosure"]').click()
        assert await page.locator('#mathBuilderDisclosure').evaluate('(el)=>el.open')
        await page.locator('#mathBuilderDisclosure [data-math-jump="mathResults"]').click()
        await page.locator('#mathGraph .math-edge').first.click()
        assert 'Not run here' in await page.locator('#mathInspectorBody').inner_text()
        await page.locator('#mathResults [data-math-jump="mathECAIBridge"]').click()
        assert await page.locator('.math-journey [data-math-jump="mathECAIBridge"]').get_attribute('aria-current')=='step'
        assert await page.evaluate('window.__calls.length')==0
        # A populated, actually animated kernel for a real preview.
        await page.locator('.math-journey [data-math-jump="mathKernel"]').click()
        await page.locator('#mathKernelShape').select_option('dragonfly')
        await page.locator('#mathKernelTerms').fill('72')
        await page.locator('#mathKernelSpeed').fill('4')
        if await page.locator('#mathKernelPlay').inner_text()=='Play':
            await page.locator('#mathKernelPlay').click()
        await page.wait_for_timeout(2300)
        assert await page.locator('#mathKernel').get_attribute('data-animating')=='true'
        # Temporarily drop topbar stickiness for artifact captures: Playwright element
        # screenshot scrolling otherwise places the sticky bar *inside* the canvas.
        await page.evaluate('document.querySelector(".console-topbar").style.position="static"')
        await page.locator('#mathKernel').screenshot(path=str(OUT/'ecai-math-guided-kernel.png'))
        await page.evaluate('window.scrollTo({top:0,behavior:"instant"});document.activeElement?.blur()')
        await page.wait_for_timeout(160)
        await page.screenshot(path=str(OUT/'ecai-math-guided-overview.png'))
        await page.set_viewport_size({'width':390,'height':850})
        await page.evaluate('window.scrollTo({top:0,behavior:"instant"});document.activeElement?.blur()')
        await page.wait_for_timeout(160)
        assert await page.evaluate('document.documentElement.scrollWidth<=window.innerWidth')
        await page.screenshot(path=str(OUT/'ecai-math-guided-mobile.png'))
        await page.locator('.math-journey [data-math-jump="mathBuilderDisclosure"]').click()
        assert await page.locator('#mathDiscoverForm').is_visible()
        await page.locator('.math-journey [data-math-jump="mathECAIBridge"]').click()
        assert await page.locator('#mathECAIBridge').is_visible()
        assert await page.evaluate('document.documentElement.scrollWidth<=window.innerWidth')
        assert await page.evaluate('window.__calls.length')==0
        assert errors==[],errors
        await page.evaluate('window.__math.dispose();window.__kernel.dispose()')
        await browser.close()
        print('PASS: 5 ordered stages; jump/focus/aria-current; #math hash stable; builder expansion; sample evidence; no network jobs; live visualizer; concept links; desktop/390px mobile')


if __name__=='__main__': asyncio.run(main())
