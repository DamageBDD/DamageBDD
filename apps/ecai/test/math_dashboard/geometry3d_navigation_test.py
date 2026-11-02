#!/usr/bin/env python3
"""Focused 2D → 3D → exact-sample navigation smoke test, no network."""
import asyncio,os,shutil
from playwright.async_api import async_playwright
from browser_test import APP,MOCK,fixture,module_url
from kernel_browser_test import make_html

async def main():
    async with async_playwright() as pw:
        opts={'headless':True,'args':['--no-sandbox','--disable-dev-shm-usage']}
        chrome=os.environ.get('CHROMIUM') or shutil.which('chromium')
        if chrome:opts['executable_path']=chrome
        browser=await pw.chromium.launch(**opts)
        page=await browser.new_page(viewport={'width':1280,'height':900})
        page.set_default_timeout(6000)
        errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
        html=make_html().replace('</style>',(APP/'priv/static/css/ecai-math-3d.css').read_text()+'</style>')
        await page.set_content(html)
        await page.evaluate('''()=>{const view=document.querySelector('[data-panel="math"]');
          for(const e of document.querySelectorAll('[data-panel]')) {e.hidden=e!==view;e.classList.toggle('is-visible',e===view);}
          document.querySelector('#ecaiConsole').dataset.activeView='math';
          window.__hash=location.hash;}''')
        await page.evaluate('(example)=>{window.__fixture=example;'+MOCK+'}',fixture())
        await page.evaluate('''async url=>{const m=await import(url);window.__math=m.initMathPaths({
           request:window.__request,currentToken:()=>'',managedSession:()=>false,openLogin:()=>{},toast:()=>{}});
           window.__math.setVisible(true);
        }''',module_url((APP/'priv/static/js/ecai-math-paths.js').read_text()))
        assert await page.locator('.math-journey-steps button').count()==5
        await page.locator('#mathKernel [data-math-jump="math3DWorkbench"]').click()
        assert await page.locator('#math3DWorkbench').is_visible()
        assert await page.locator('.math-journey [data-math-jump="mathKernel"]').get_attribute('aria-current')=='step'
        await page.locator('#math3DWorkbench [data-math-jump="mathLibrary"]').click()
        assert await page.locator('#mathLibrary').is_visible()
        assert await page.locator('.math-journey [data-math-jump="mathLibrary"]').get_attribute('aria-current')=='step'
        assert await page.evaluate('location.hash===window.__hash')
        assert await page.evaluate('window.__calls.length')==0
        await page.evaluate('window.__math.dispose()')
        assert not errors,errors
        await browser.close()
        print('PASS: existing 5-stage guide, 2D→3D→exact transitions, ARIA current, #math stable, no jobs')

if __name__=='__main__':asyncio.run(main())
