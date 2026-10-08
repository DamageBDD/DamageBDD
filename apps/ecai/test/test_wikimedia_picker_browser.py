"""Optional Chromium regression for Wikimedia dataset selection and durable queueing.

Run: python3 apps/ecai/test/test_wikimedia_picker_browser.py
All requests are mocked; nothing is sent to a real node.
"""
import asyncio
import re
from pathlib import Path
from playwright.async_api import async_playwright

APP = Path(__file__).resolve().parents[1]
HTML = (APP / 'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
HTML = re.sub(r'<script[^>]+src="[^"]+"[^>]*></script>', '', HTML)
HTML = re.sub(r'<link[^>]+href="/static/css/ecai-console.css"[^>]*>', '', HTML)
JS = (APP / 'priv/static/js/ecai-console.js').read_text().replace(
    '''    const url = new URL(value, location.origin);
    if (url.origin !== location.origin || !value.startsWith("/")) throw new Error("Only local ECAI endpoints are permitted");
    return url.pathname + url.search;''',
    '''    if (!value.startsWith("/")) throw new Error("Test route must be local");
    return value;''')
CSS = (APP / 'priv/static/css/ecai-console.css').read_text()
MOCK = r'''(() => {
  window.__loggedIn = false;
  window.__posts = [];
  window.__failOnce = true;
  window.__planCount = 0;
  window.confirm = () => true;
  window.history.replaceState = () => {};
  window.fetch = async (uri, options={}) => {
    const u = new URL(String(uri), 'http://mock.test');
    const path = u.pathname, method = options.method || 'GET';
    let payload = {ok:true}, status = 200;
    if (path === '/ecai/auth/session') payload = {authenticated:window.__loggedIn, node_admin:false, code_admin:false, public_key: window.__loggedIn ? 'ak-test' : null};
    else if (path === '/accounts/auth/') {window.__loggedIn = true; payload={access_token:'test_bearer',email:'operator@testing.invalid'};}
    else if (path === '/accounts/logout') {window.__loggedIn = false;}
    else if (path === '/ecai/chat') payload={status:'ok'};
    else if (path === '/yelp/status') payload={index_size:{docs:100}};
    else if (path === '/ecai/index-jobs/status') payload={ok:true,status:{running_jobs:0,queued_jobs:0}};
    else if (path === '/ecai/index-jobs/presets') payload={ok:true,presets:[
      {id:'enwiki',label:'English Wikipedia',description:'English articles',project:'enwiki'},
      {id:'dewiki',label:'German Wikipedia',description:'German articles',project:'dewiki'},
      {id:'frwiki',label:'French Wikipedia',description:'French articles',project:'frwiki'}]};
    else if (path === '/ecai/index-jobs' && method === 'GET') payload={ok:true,jobs:[]};
    else if (path.startsWith('/ecai/index-jobs/presets/') && method === 'POST') {
      window.__posts.push({path,method,key:options.headers['Idempotency-Key'],body:JSON.parse(options.body)});
      if (path.endsWith('/dewiki') && window.__failOnce) {
        window.__failOnce = false; payload={ok:false,error:'temporary_backend_failure'};status=503;
      } else payload={ok:true,job:{id:'ijob-'+path.split('/').at(-1),state:'queued'}};
    } else if (path === '/ecai/wikimedia/sources') {
      payload={ok:true,sources:{schema:'ecai-wikimedia-catalog/v1',project:u.searchParams.get('project'),pageview_project:u.searchParams.get('pageview_project'),
        available_cirrus_releases:['20260915','20260820'],requested_pageview_months:['2026-01','2026-02','2026-03','2026-04','2026-05','2026-06','2026-07','2026-08']}};
    } else if (path === '/ecai/wikimedia/plan') {
      window.__planCount++;
      const months=u.searchParams.get('months').split(','), project=u.searchParams.get('project'), release=u.searchParams.get('content_release');
      payload={ok:true,plan:{spec:{schema:'ecai-index-job/v1',kind:'wikimedia_visibility',owner:'',
        source:{project,pageview_project:u.searchParams.get('pageview_project'),content_release:release,pageview_months:months},
        target:{index_id:'ecai-wikimedia-'+project,base_dir:'/var/lib/damage/ecai/wikimedia/'+project},
        options:{limit:Number(u.searchParams.get('limit')),minimum_active_months:Number(u.searchParams.get('minimum_active_months'))},finalize:{}},
        catalog:{cirrus_release:release,content_shards:3,pageview_files:months.length}}};
    } else if (path === '/ecai/index-jobs' && method === 'POST') {
      const body=JSON.parse(options.body);
      window.__posts.push({path,method,key:options.headers['Idempotency-Key'],body});
      payload={ok:true,job:{id:'ijob-custom-frwiki',state:'queued'}};
    } else if (path === '/ecai/admin/code/status') { payload={ok:false,error:'admin_role_required'}; status=403; }
    else {payload={ok:false,error:'unknown_mock_endpoint:'+path};status=404;}
    return new Response(JSON.stringify(payload),{status,headers:{'Content-Type':'application/json'}});
  };
})();'''

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(executable_path='/usr/bin/chromium', headless=True,
                                          args=['--no-sandbox','--disable-dev-shm-usage'])
        page = await browser.new_page(viewport={'width':1440,'height':900})
        errors=[]
        page.on('pageerror', lambda e: errors.append(str(e)))
        await page.goto('about:blank')
        await page.set_content(HTML)
        await page.add_style_tag(content=CSS)
        await page.evaluate(MOCK)
        await page.add_script_tag(content=JS)
        await page.locator('[data-view="wikimedia"]').click()
        assert await page.locator('#wikiQueueSelected').is_disabled()
        await page.locator('#loginBtn').click()
        await page.locator('#consoleLoginForm input[name="email"]').fill('operator@testing.invalid')
        await page.locator('#consoleLoginForm input[name="password"]').fill('mock-secret')
        await page.locator('#consoleLoginSubmit').click()
        await page.locator('.wiki-project-card').first.wait_for(state='visible')
        assert await page.locator('.wiki-project-card').count() == 3
        await page.locator('#wikiPresetSearch').fill('German')
        assert await page.locator('.wiki-project-card').count() == 1
        await page.locator('#wikiSelectAll').click()
        assert '1 selected' in await page.locator('#wikiSelectedCount').inner_text()
        await page.locator('#wikiPresetSearch').fill('')
        await page.locator('.wiki-project-card').first.locator('input[type=checkbox]').check()
        assert '2 selected' in await page.locator('#wikiSelectedCount').inner_text()
        await page.locator('#wikiQueueSelected').click()
        await page.wait_for_function('window.__posts.length === 2')
        await page.locator('#wikiPickerStatus').get_by_text('1/2 jobs accepted',exact=False).wait_for()
        posts=await page.evaluate('window.__posts')
        assert posts[0]['path'].endswith('/enwiki') and posts[1]['path'].endswith('/dewiki'),posts
        assert posts[0]['key'] != posts[1]['key'],posts
        assert '1 selected' in await page.locator('#wikiSelectedCount').inner_text()
        await page.locator('#wikiQueueSelected').click()
        await page.wait_for_function('window.__posts.length === 3')
        await page.locator('#wikiPickerStatus').get_by_text('1/1 jobs accepted',exact=False).wait_for()
        posts=await page.evaluate('window.__posts')
        assert posts[1]['key'] == posts[2]['key'], 'Idempotency key must survive a transient failure'
        assert '0 selected' in await page.locator('#wikiSelectedCount').inner_text()
        await page.locator('#wikiProject').select_option('frwiki')
        assert await page.locator('#wikiPageviewProject').input_value() == 'fr.wikipedia'
        await page.locator('#wikiSourcesBtn').click()
        await page.locator('.wiki-month-choice').first.wait_for(state='visible')
        assert await page.locator('.wiki-month-choice').count() == 8
        assert '6 selected' in await page.locator('#wikiMonthCount').inner_text()
        await page.locator('#wikiRecentAll').click()
        assert '8 selected' in await page.locator('#wikiMonthCount').inner_text()
        await page.locator('#wikiRecentSix').click()
        await page.locator('#wikiPlanLimit').fill('5000')
        await page.locator('#wikiPlanBtn').click()
        await page.locator('#wikiQueuePlanBtn').wait_for(state='visible')
        await page.wait_for_function('!document.getElementById("wikiQueuePlanBtn").disabled')
        assert '20260915' in await page.locator('#wikiPlanOutput').text_content()
        await page.locator('#wikiPlanLimit').fill('6000')
        assert await page.locator('#wikiQueuePlanBtn').is_disabled(), 'Changing inputs must invalidate prior server validation'
        await page.locator('#wikiPlanBtn').click()
        await page.locator('#wikiQueuePlanBtn').wait_for(state='visible')
        await page.wait_for_function('!document.getElementById("wikiQueuePlanBtn").disabled')
        await page.locator('#wikiQueuePlanBtn').click()
        await page.wait_for_function('window.__posts.length === 4')
        await page.locator('#wikiPlanStatus').get_by_text('Queued frwiki:',exact=False).wait_for()
        assert await page.locator('#wikiQueuePlanBtn').is_disabled()
        posts=await page.evaluate('window.__posts')
        custom=posts[-1]
        assert custom['path']=='/ecai/index-jobs' and custom['method']=='POST'
        assert custom['body']['source']['project']=='frwiki'
        assert custom['body']['source']['pageview_months']==['2026-03','2026-04','2026-05','2026-06','2026-07','2026-08']
        assert custom['body']['options']['limit']==6000
        await page.evaluate('window.scrollTo(0, 0)')
        await page.wait_for_timeout(200)
        await page.screenshot(path='/mnt/data/ecai-wikimedia-source-picker-desktop.png',full_page=True)
        await page.set_viewport_size({'width':390,'height':844})
        await page.wait_for_timeout(150)
        overflow=await page.evaluate('document.documentElement.scrollWidth-document.documentElement.clientWidth')
        await page.screenshot(path='/mnt/data/ecai-wikimedia-source-picker-mobile.png',full_page=True)
        assert overflow <= 1, f'Mobile overflow: {overflow}px'
        assert not errors, errors
        print('PASS: guest gate, searchable multi-select, partial queue recovery, per-preset idempotency, catalog release/month picker, validated-plan invalidation, custom enqueue, mobile layout, no JS errors')
        await browser.close()

if __name__ == '__main__': asyncio.run(main())
