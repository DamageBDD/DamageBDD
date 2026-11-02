#!/usr/bin/env python3
"""Check actual Math section and scoped curve-to-contour module in Chromium.

No ECAI server, credentials, external API, external JavaScript or network used.
"""
import asyncio
import os
import re
import shutil
from pathlib import Path
from playwright.async_api import async_playwright

from browser_test import APP, module_url


def make_html():
    shell=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
    shell=shell.replace('{{{math_paths_panel}}}',
                        (APP/'priv/templates/ui/dashboard/ecai_math_paths.mustache').read_text())
    shell=re.sub(r'<script\b[^>]*>.*?</script>','',shell,flags=re.S)
    shell=re.sub(r'<link\b[^>]*>','',shell)
    shell=re.sub(r'\{\{\{?.*?\}\}\}?','',shell)
    css=''.join((APP/'priv/static/css'/name).read_text()
                for name in ('ecai-console.css','ecai-math-paths.css','ecai-math-kernel.css'))
    return shell.replace('</head>','<style>'+css+'</style></head>')


async def main():
    async with async_playwright() as pw:
        chromium=os.environ.get('CHROMIUM') or shutil.which('chromium')
        opts={'headless':True,'args':['--no-sandbox','--disable-dev-shm-usage']}
        if chromium:opts['executable_path']=chromium
        browser=await pw.chromium.launch(**opts)
        page=await browser.new_page(viewport={'width':1360,'height':1000},device_scale_factor=1)
        errors=[]
        page.on('pageerror',lambda e: errors.append(str(e)))
        await page.set_content(make_html())
        await page.evaluate('''() => {
          document.querySelector('[data-panel="math"]').hidden=false;
          document.querySelector('[data-panel="math"]').classList.add('is-visible');
          document.querySelector('#ecaiConsole').dataset.activeView='math';
          window.__kernelRequests=0;
          window.fetch=()=>{window.__kernelRequests++;throw Error('Visualizer may not call network')};
        }''')
        await page.evaluate('''async (url) => {
          const m = await import(url);
          window.__kernel = m.initMathKernel();
          window.__kernel.setVisible(true);
        }''',module_url((APP/'priv/static/js/ecai-math-kernel.js').read_text()))
        await page.locator('#mathKernel').scroll_into_view_if_needed()
        await page.wait_for_function('document.querySelector("#mathKernelStage").width > 0')
        assert await page.locator('#mathKernel').is_visible()
        assert await page.locator('#mathSampleSelect').count() == 1
        assert await page.locator('#mathDiscoverForm').count() == 1
        assert await page.locator('#mathKernelStage').evaluate('el=>el.width > 400 && el.height > 250')
        assert await page.locator('#mathKernelStage').evaluate('''el => {
          const {data} = el.getContext('2d').getImageData(30,30,10,10);
          return Array.from(data).some(v => v !== 0);
        }''')
        assert await page.locator('#mathKernel').get_attribute('data-animating') == 'true'
        await page.locator('#mathKernelPlay').click()
        assert await page.locator('#mathKernel').get_attribute('data-animating') == 'false'
        assert await page.locator('#mathKernelPlay').get_attribute('aria-pressed') == 'false'
        await page.locator('#mathKernelTerms').fill('40')
        assert await page.locator('#mathKernelTermsLabel').inner_text() == '40'
        await page.locator('#mathKernelShape').select_option('flower')
        assert await page.locator('#mathKernelShape').input_value() == 'flower'
        await page.locator('#mathKernelReset').click()
        assert await page.locator('#mathKernelTerms').input_value() == '12'
        await page.locator('#mathKernelSpeed').fill('3')
        assert await page.locator('#mathKernelSpeedLabel').inner_text() == '3×'
        await page.locator('#mathKernelPlay').click()
        assert await page.locator('#mathKernel').get_attribute('data-animating') == 'true'
        await page.evaluate('__kernel.setVisible(false)')
        assert await page.locator('#mathKernel').get_attribute('data-animating') == 'false'
        await page.evaluate('__kernel.setVisible(true)')
        assert await page.locator('#mathKernel').get_attribute('data-animating') == 'true'
        assert await page.evaluate('__kernelRequests') == 0
        # Capture the default dragonfly at a usable reconstruction order.
        await page.locator('#mathKernelShape').select_option('dragonfly')
        await page.locator('#mathKernelTerms').fill('64')
        await page.locator('#mathKernelSpeed').fill('4')
        await page.wait_for_timeout(1250)
        await page.screenshot(path=os.environ.get('ECAI_KERNEL_PREVIEW','/mnt/data/ecai-math-kernel-desktop.png'))
        await page.set_viewport_size({'width':390,'height':850})
        await page.locator('#mathKernel').scroll_into_view_if_needed()
        await page.wait_for_timeout(200)
        assert await page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
        await page.screenshot(path=os.environ.get('ECAI_KERNEL_MOBILE','/mnt/data/ecai-math-kernel-mobile.png'))
        await page.evaluate('__kernel.dispose()')
        assert await page.locator('#mathKernel').get_attribute('data-animating') == 'false'
        await page.emulate_media(reduced_motion='reduce')
        await page.evaluate('''async url => {
            const {initMathKernel} = await import(url);
            window.__kernel = initMathKernel();
            window.__kernel.setVisible(true);
        }''',module_url((APP/'priv/static/js/ecai-math-kernel.js').read_text()))
        assert await page.locator('#mathKernelPlay').inner_text() == 'Play'
        assert await page.locator('#mathKernel').get_attribute('data-animating') == 'false'
        await page.evaluate('__kernel.dispose()')
        assert errors==[],errors
        await browser.close()
        print('PASS: Math panel mounting, live animation, controls, visibility/dispose lifecycle, reduced motion, no requests, desktop/mobile layout')


if __name__ == '__main__':
    asyncio.run(main())
