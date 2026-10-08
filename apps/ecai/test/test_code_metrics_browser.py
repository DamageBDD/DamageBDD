"""Optional isolated Chromium test of review-gate UX and live status metrics.

python3 apps/ecai/test/test_code_metrics_browser.py
Requires playwright + chromium. Simulates node APIs; never pushes to Git.
"""
import asyncio
import re
import tempfile
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
SCREENSHOTS = Path(tempfile.gettempdir())
MOCK = r'''(() => {
  window.__actor = null;
  window.__posts = [];
  window.__forceConflict = false;
  window.__nonAdmin = false;
  window.__omitGate = false;
  window.__mockReview = {
    id:'a'.repeat(64), patch_sha256:'b'.repeat(64), base_commit:'c'.repeat(40),
    fingerprint:'f'.repeat(64), application:'ecai', module:'ecai_patch_worker',
    revision:2, status:'approved', created_at:'2026-10-08T06:40:00Z',
    summary:'Bounded repair prompt', verification:{status:'validated',steps:[{step:'compile',ok:true}]},
    approvals:[{actor:'reviewerA',note:'Validated with tests',at:'2026-10-08T06:42:00Z'}],
    patch:'diff --git a/apps/ecai/src/test.erl b/apps/ecai/src/test.erl\n--- a/apps/ecai/src/test.erl\n+++ b/apps/ecai/src/test.erl\n@@ -1 +1 @@\n-old\n+new\n',events:[]
  };
  window.confirm = () => true;
  window.history.replaceState = () => {};
  window.fetch = async (url, options={}) => {
    const path = String(url).split('?')[0], method=options.method||'GET';
    const actor=window.__actor;
    let payload={ok:true}, status=200;
    if(path==='/accounts/auth/') {
      const data=JSON.parse(options.body);
      window.__actor = data.username.includes('reviewer') ? 'reviewerA' : 'publisherB';
      payload={access_token:'test_bearer_'+window.__actor,email:data.username};
    } else if(path==='/accounts/logout') { window.__actor=null; }
    else if(path==='/ecai/auth/session') payload={authenticated:!!actor,node_admin:!!actor && !window.__nonAdmin,code_admin:!!actor && !window.__nonAdmin,public_key:actor||null};
    else if(path==='/ecai/chat') payload={status:'ok'};
    else if(path==='/yelp/status') payload={index_size:{docs:57}};
    else if(path==='/ecai/index-jobs/status') payload={ok:true,status:{running_jobs:0,queued_jobs:0}};
    else if(path==='/ecai/index-jobs') payload={ok:true,jobs:[]};
    else if(window.__nonAdmin && path.startsWith('/ecai/admin/code/')) {payload={ok:false,error:'admin_role_required'};status=403;}
    else if(path==='/ecai/admin/code/status') {
      payload={ok:true,status:{
        learning:{learner:{cycle:2721,phase:'learning',completed:650,total:700,progress_percent:92.857,
          inflight_count:2,queued:48,last_completed_at:'2026-10-08T06:42:00Z'},
          patch_manager:{active:1,pending:3,queued_live:2,retry_wait:1,max_concurrent:2,stale_running:0,last_run_at:'2026-10-08T06:45:00Z'},
          integration:{cycles:21,job_counts:{clean:36,broken:8}},store:{event_seq:40}},
        reviews:{counts:{approved:1,pending:2,published:3},required_approvals:1,publish_enabled:true,publishing:null}
      }};
    } else if(path==='/ecai/admin/code/repairs') payload={ok:true,total:120,repairs:[]};
    else if(path==='/ecai/admin/code/reviews') payload={ok:true,reviews:[window.__mockReview],queue:{counts:{approved:1,pending:2,published:3},required_approvals:1,publish_enabled:true,publishing:null}};
    else if(path.endsWith('/approve')) {payload={ok:false,error:'already_approved'};status=409;}
    else if(path.endsWith('/publish')) {
      const body=JSON.parse(options.body);
      window.__posts.push({path,method,body,actor});
      if(window.__forceConflict) { payload={ok:false,error:'stale_review_revision'};status=409; }
      else if(actor==='reviewerA') {payload={ok:false,error:'publisher_is_reviewer'};status=409;}
      else {window.__mockReview={...window.__mockReview,status:'publishing',revision:3};payload={ok:true,review:window.__mockReview};status=202;}
    } else if(path.endsWith('/reject')) {payload={ok:false,error:'invalid_review_state'};status=409;}
    else if(path==='/ecai/admin/code/reviews/'+window.__mockReview.id) {
      const r=window.__mockReview;
      payload={ok:true,review:window.__omitGate ? {...r} : {...r,publication_gate:{
        eligible:actor==='publisherB' && r.status==='approved',
        blockers:actor==='reviewerA' ? ['publisher_is_reviewer'] : r.status==='publishing' ? ['review_not_approved'] : [],
        approvals:1,required_approvals:1,publisher_is_reviewer:actor==='reviewerA',git_preflight:'not_checked'
      }}};
    } else if(path.startsWith('/ecai/admin/code/')) {payload={ok:false,error:'not_found'};status=404;}
    else {payload={ok:false,error:'unknown_endpoint'};status=404;}
    return new Response(JSON.stringify(payload),{status,headers:{'Content-Type':'application/json'}});
  };
})();'''

async def login(page, role):
    await page.locator('#loginBtn').click()
    await page.locator('#consoleLoginForm input[name="email"]').fill(role+'@example.invalid')
    await page.locator('#consoleLoginForm input[name="password"]').fill('test-only')
    await page.locator('#consoleLoginSubmit').click()
    await page.locator('#codeAdminNav').wait_for(state='visible', timeout=10000)

async def main():
    async with async_playwright() as pw:
        browser = await pw.chromium.launch(executable_path='/usr/bin/chromium', headless=True,
                                           args=['--no-sandbox', '--disable-dev-shm-usage'])
        page = await browser.new_page(viewport={'width':1440,'height':920})
        errors=[]
        page.on('pageerror', lambda e: errors.append(str(e)))
        await page.goto('about:blank')
        await page.set_content(HTML)
        await page.add_style_tag(content=CSS)
        await page.evaluate(MOCK)
        await page.add_script_tag(content=JS)
        await login(page,'reviewer')
        await page.locator('#codeAdminNav').click()
        await page.locator('#codeMetrics .code-metric').first.wait_for(state='visible')
        assert '650 / 700' in await page.locator('#codeMetrics').inner_text()
        assert 'Repair backlog' in await page.locator('#codeMetrics').inner_text()
        assert '36 / 8' in await page.locator('#codeServiceCards').inner_text()
        assert await page.locator('.code-raw-telemetry').count() == 1
        await page.locator('#codeReviewRows details.code-review-card summary').click()
        await page.locator('#codePublishGate').get_by_text('This account approved the patch', exact=False).wait_for()
        await page.locator('#codePublishPhrase').fill('push to origin')
        assert await page.locator('#codePublish').is_disabled(), 'Reviewer should never publish own approved diff'
        assert await page.evaluate('window.__posts.length') == 0
        await page.screenshot(path=str(SCREENSHOTS / 'ecai-code-metrics-gate-desktop.png'),full_page=True)
        await page.locator('#logoutBtn').click()
        await login(page,'publisher')
        await page.locator('#codeAdminNav').click()
        await page.locator('#codeReviewRows details.code-review-card summary').click()
        await page.locator('#codePublishGate').get_by_text('Eligible for independent publication').wait_for()
        await page.evaluate('window.__omitGate=true')
        await page.locator('#codeReloadReview').click()
        await page.locator('#codePublishGate').get_by_text('does not expose publisher eligibility', exact=False).wait_for()
        assert await page.locator('#codePublish').is_disabled(), 'Older server without gate must fail closed'
        await page.evaluate('window.__omitGate=false')
        await page.locator('#codeReloadReview').click()
        await page.locator('#codePublishGate').get_by_text('Eligible for independent publication').wait_for()
        await page.locator('#codePublishPhrase').fill('push to origin')
        assert await page.locator('#codePublish').is_enabled(), 'Independent authorized publisher should be eligible'
        await page.evaluate('window.__forceConflict=true')
        await page.locator('#codePublish').click()
        await page.locator('#codeActionStatus').get_by_text('review changed',exact=False).wait_for()
        assert await page.evaluate('window.__posts.length') == 1
        # A repeated attempt requires the explicit confirmation and re-evaluates the server gate.
        await page.evaluate('window.__forceConflict=false')
        await page.locator('#codePublish').click()
        await page.wait_for_function('window.__mockReview.status === "publishing"')
        posts=await page.evaluate('window.__posts')
        assert len(posts)==2 and all(p['actor']=='publisherB' and p['body']['revision']==2 for p in posts),posts
        await page.set_viewport_size({'width':390,'height':844})
        await page.wait_for_timeout(150)
        overflow=await page.evaluate('document.documentElement.scrollWidth-document.documentElement.clientWidth')
        await page.screenshot(path=str(SCREENSHOTS / 'ecai-code-metrics-gate-mobile.png'),full_page=True)
        assert overflow <= 1, f'Mobile overflow {overflow}'
        assert not errors, errors
        await page.locator('#logoutBtn').click()
        await page.evaluate('window.__nonAdmin=true')
        await page.locator('#loginBtn').click()
        await page.locator('#consoleLoginForm input[name="email"]').fill('ordinary@example.invalid')
        await page.locator('#consoleLoginForm input[name="password"]').fill('test-only')
        await page.locator('#consoleLoginSubmit').click()
        await page.wait_for_timeout(200)
        assert await page.locator('#codeAdminNav').is_hidden(), 'Nonadmin must not see review queue'
        assert not errors, errors
        print('PASS: accurate status metrics, reviewer separation, older server fallback, independent publisher, 409 stale revision, nonadmin denial, mobile width, no JS errors')
        await browser.close()

if __name__=='__main__': asyncio.run(main())
