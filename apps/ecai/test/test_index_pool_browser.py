"""Real Chromium + mocked HTTP: no CLN, funding or real work is executed.

Run with Python Playwright and Chromium. Screenshots go to ECAI_SCREENSHOTS
(or the system temporary directory). This tests browser integration only.
"""
import asyncio
import copy
import hashlib
import json
import os
import re
from types import SimpleNamespace
import tempfile
from pathlib import Path
from urllib.parse import urlparse
from playwright.async_api import async_playwright

APP = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get('ECAI_SCREENSHOTS', tempfile.gettempdir()))
ROOT = '/ecai/admin/index-pool'
OWNER = 'ak_creator_demo'
LN = '02' + '1'*64
PLAN = 'a'*64
UNITS = [dict(id=str(i)*64,ordinal=i,bytes=i*2000000,lines=i*100) for i in [1,2,3]]

def peer(name, n):
    return dict(node_name='damage@'+name,account='ak_'+name,lightning_node='02'+str(n)*64,
                network='regtest',pipeline_sha256='b'*64,enabled=True,observed_at=1791504000)

class Backend:
    def __init__(self):
        self.auth=False; self.admin=True; self.token=True; self.fail_create=True
        self.posts=[]; self.jobs=[]; self.peers=[peer('desktop-a',2)]; self.status_calls=0
        self.delay_status=0; self.op=None

    def status(self):
        return dict(enabled=True,actor=OWNER,network='regtest',payments_enabled=True,
            max_budget_sats=100000,max_fee_sats=10,refund_node=LN,
            available_nodes=['damage@desktop-a','damage@desktop-b'],peers=self.peers,
            plans=[dict(id=PLAN,label='simplewiki desktop segments',segments=3,source_bytes=12000000)],
            source_jobs=[dict(id='ijob-source',kind='wikipedia_jsonl',state='paused')],
            jobs=self.jobs,operation=self.op,channels=dict(observed_at=1791504000,advisory_only=True,
                channels=[dict(peer_id=self.peers[0]['lightning_node'],channel_id='7'*64,
                    state='CHANNELD_NORMAL',connected=True,spendable_msat=42000000,receivable_msat=5000000)]))

    def quote(self,b):
        def divide(n):
            weights={u['id']:u['bytes'] for u in UNITS}; total=sum(weights.values())
            values={k:n*w//total for k,w in weights.items()}
            remain=n-sum(values.values())
            order=sorted(weights,key=lambda k:(-(n*weights[k]%total),k))
            for k in order[:remain]: values[k]+=1
            return values
        fee=3*(2 if b['verifier_percent'] else 1)*b['fee_sats']; reward=b['budget_sats']-fee
        verify=reward*b['verifier_percent']//100; indexing=reward-verify
        ips,vps=divide(indexing),divide(verify)
        prices={u['id']:dict(index_msat=ips[u['id']]*1000,verify_msat=vps[u['id']]*1000) for u in UNITS}
        ps=[p for p in self.peers if p['node_name'] in b['nodes']]
        local=dict(node_name='damage@coordinator',account=OWNER,lightning_node=LN,unpaid_local_verifier=True)
        assignments={u['id']:dict(ordinal=u['ordinal'],indexer=ps[(u['ordinal']-1)%len(ps)],
            verifier=ps[u['ordinal']%len(ps)] if verify else local) for u in UNITS}
        budget=dict(total_sats=b['budget_sats'],indexing_sats=indexing,verification_sats=verify,
            fee_reserve_sats=fee,segments=3,source_bytes=12000000,unit_prices=prices,
            minimum_index_reward_sats=min(ips.values()),maximum_index_reward_sats=max(ips.values()))
        contract=dict(schema='ecai-index-participation/v1',owner=OWNER,plan_id=PLAN,
            budget=budget,assignments=assignments,refund_node=LN,verification_policy='full-independent-rebuild/v1')
        return dict(quote_hash=hashlib.sha256(json.dumps(contract,sort_keys=True).encode()).hexdigest(),
            label='simplewiki desktop segments',plan_id=PLAN,contract=contract)

    async def route(self,route):
        r=route.request; path=urlparse(r.url).path
        if path=='/':
            html=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text().replace('{{node_version}}','browser test')
            return await route.fulfill(body=html,content_type='text/html')
        if path.startswith('/static/'):
            if path=='/static/js/sidekick.js': return await route.fulfill(body='',content_type='text/javascript')
            p=APP/'priv'/path.lstrip('/')
            return await route.fulfill(body=p.read_text(),content_type='text/css' if p.suffix=='.css' else 'text/javascript')
        body=json.loads(r.post_data or '{}'); result={}; code=200
        if path=='/accounts/auth/':
            self.auth=True; result=dict(access_token='demo_explicit_token_12345',email='admin@example.invalid')
        elif path=='/accounts/logout': self.auth=False; result=dict(ok=True)
        elif path=='/ecai/auth/session': result=dict(authenticated=self.auth,node_admin=self.auth and self.admin,public_key=OWNER,code_admin_enabled=True)
        elif path=='/ecai/chat': result=dict(status='ok')
        elif path=='/yelp/status': result=dict(index_size=dict(docs=10))
        elif path=='/ecai/index-jobs/status': result=dict(ok=True,status=dict(running_jobs=0,queued_jobs=0,canceled_checkpoint_retry=True))
        elif path=='/ecai/index-jobs': result=dict(ok=True,jobs=[])
        elif path=='/ecai/index-jobs/presets': result=dict(ok=True,presets=[])
        elif path.startswith('/ecai/admin/code/'):
            result=dict(ok=True,status=dict(learning={},reviews={}),repairs=[],reviews=[],queue={})
        elif path.startswith(ROOT):
            if not self.auth or not self.admin: code=403; result=dict(ok=False,error='node_admin_required')
            elif r.method=='POST' and not r.headers.get('authorization'):
                code=403; result=dict(ok=False,error='bearer_required')
            else:
                suffix=path[len(ROOT):]; data={}
                if r.method=='POST': self.posts.append(dict(path=suffix,body=body,headers=r.headers))
                if suffix=='/status':
                    self.status_calls+=1
                    data=copy.deepcopy(self.status())
                    if self.delay_status: await asyncio.sleep(self.delay_status)
                elif suffix=='/nodes':
                    if not any(p['node_name']==body['node'] for p in self.peers): self.peers.append(peer('desktop-b',3))
                    data=dict(state='working'); self.op=dict(kind='join',state='complete')
                elif suffix=='/prepare': data=dict(state='working'); self.op=dict(kind='prepare',state='complete')
                elif suffix=='/channels': data=dict(state='working'); self.op=dict(kind='channels',state='complete')
                elif suffix=='/quote': data=self.quote(body)
                elif suffix=='/jobs':
                    if self.fail_create:
                        self.fail_create=False; code=503; result=dict(ok=False,error='simulated_response_loss')
                    else:
                        data=self.quote(body); data.update(id='c'*64,owner=OWNER,units=copy.deepcopy(UNITS),stage='awaiting_funding',active=False,auto_pay=False,results={},last_error=None)
                        data['accounting']=dict(state='awaiting_funding',funded_msat=0,reserved_msat=0,spent_msat=0,funding=dict(bolt11='lnbcrt1mock_invoice_not_payable'),payouts=[],node_allocations=[])
                        self.jobs=[data]
                elif suffix.endswith('/start'):
                    self.jobs[0].update(active=True,auto_pay=body['auto_pay'],stage='indexing'); data=self.jobs[0]
                elif suffix.endswith('/pause'):
                    self.jobs[0].update(active=False,auto_pay=False); data=self.jobs[0]
                elif suffix.endswith('/contract'): data=dict(job=self.jobs[0],channel_observations=self.status()['channels'])
                elif suffix.endswith('/reconcile'): data=dict(state='working')
                else: code=404; result=dict(ok=False,error='unknown_pool_route')
                if not result: result=dict(ok=True,data=data)
        else: code=404; result=dict(ok=False,error='unknown_route')
        await route.fulfill(status=code,body=json.dumps(result),content_type='application/json')

async def load_fixture(page, backend):
    # Browser policy may prohibit network navigation in CI. Keep the document
    # about:blank and bridge fetch to the same HTTP fixtures in Python.
    async def bridge(url, opts):
        fake=SimpleNamespace(request=SimpleNamespace(url=url,method=opts.get('method','GET'),
            post_data=opts.get('body'),headers={k.lower():v for k,v in opts.get('headers',{}).items()}))
        captured={}
        async def fulfill(**kwargs): captured.update(kwargs)
        fake.fulfill=fulfill
        await backend.route(fake)
        return dict(status=captured.get('status',200),body=captured.get('body',''))
    await page.expose_function('__pool_http_fixture', bridge)
    html=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
    html=re.sub(r'<script[^>]*src="[^"]+"[^>]*></script>','',html)
    html=re.sub(r'<link[^>]*href="[^"]+"[^>]*>','',html)
    await page.goto('about:blank'); await page.set_content(html.replace('{{node_version}}','browser test'))
    for name in ['ecai-console.css','ecai-index-pool.css']:
        await page.add_style_tag(content=(APP/'priv/static/css'/name).read_text())
    await page.evaluate("""() => {
      window.confirm=()=>true; window.__exports=[];
      HTMLAnchorElement.prototype.click=function(){window.__exports.push(this.download);};
      if (!crypto.randomUUID) crypto.randomUUID=()=>Array.from(crypto.getRandomValues(new Uint8Array(16)),b=>b.toString(16).padStart(2,'0')).join('');
      window.fetch=async (url,opts={})=>{
        const res=await window.__pool_http_fixture(String(url),{method:opts.method||'GET',body:opts.body,headers:opts.headers||{}});
        return new Response(res.body,{status:res.status,headers:{'Content-Type':'application/json'}});
      };
    }""")
    await page.add_script_tag(content=(APP/'priv/static/js/ecai-index-pool.js').read_text())
    main=(APP/'priv/static/js/ecai-console.js').read_text().replace('new URL(value, location.origin)','new URL(value, "http://fixture.test")').replace('url.origin !== location.origin','url.origin !== "http://fixture.test"')
    await page.add_script_tag(content=main)

async def login(page):
    await page.locator('#loginBtn').click()
    await page.locator('#consoleLoginForm input[name=email]').fill('admin@example.invalid')
    await page.locator('#consoleLoginForm input[name=password]').fill('mock-only')
    await page.locator('#consoleLoginSubmit').click()
    await page.locator('#indexPoolNav').wait_for(state='visible')

async def main():
    OUT.mkdir(parents=True,exist_ok=True)
    async with async_playwright() as pw:
        browser=await pw.chromium.launch(executable_path=os.environ.get('CHROMIUM','/usr/bin/chromium'),headless=True,args=['--no-sandbox','--disable-dev-shm-usage'])
        context=await browser.new_context(viewport=dict(width=1440,height=1100),accept_downloads=True)
        backend=Backend()
        page=await context.new_page(); errors=[]
        page.on('pageerror',lambda e:errors.append(str(e)))
        page.on('dialog',lambda d: asyncio.create_task(d.accept()))
        await load_fixture(page, backend)
        await login(page)
        await page.locator('#indexPoolNav').click()
        await page.locator('#poolNodes .pool-node').wait_for()
        assert await page.locator('#poolCreate').is_disabled()
        assert not backend.posts, 'Read-only status must not fund or dispatch work'
        # Native hidden-details validation must not prevent a clear refund message.
        await page.locator('#poolNodeChoices input').first.check()
        await page.locator('#poolRefundNode').evaluate('(e)=>{e.value=""; e.dispatchEvent(new Event("input",{bubbles:true}));}')
        await page.locator('#poolPreview').click()
        await page.locator('#poolNotice').get_by_text('external Lightning node',exact=False).wait_for()
        assert not backend.posts
        await page.locator('#poolRefundNode').fill(LN)
        await page.locator('#poolAvailableNode').select_option('damage@desktop-b')
        await page.locator('#poolJoin').click()
        await page.wait_for_function('document.querySelectorAll("#poolNodes .pool-node").length===2')
        await page.locator('#poolNodeChoices input').nth(1).check()
        await page.locator('#poolPreview').click()
        await page.wait_for_function('!document.getElementById("poolCreate").disabled')
        assert '9,997 sats' in await page.locator('#poolQuote').inner_text()
        assert all(p['path']!='/jobs' for p in backend.posts)
        # Any pricing change invalidates the pinned quote.
        await page.locator('#poolBudget').fill('10001')
        assert await page.locator('#poolCreate').is_disabled()
        await page.locator('#poolBudget').fill('10000')
        await page.locator('#poolPreview').click()
        await page.wait_for_function('!document.getElementById("poolCreate").disabled')
        await page.locator('#poolCreate').click()
        await page.locator('#poolNotice').get_by_text('simulated_response_loss').wait_for()
        await page.locator('#poolCreate').click()
        await page.locator('#poolJobs .pool-job summary').wait_for()
        creates=[p for p in backend.posts if p['path']=='/jobs']
        assert len(creates)==2 and creates[0]['headers']['idempotency-key']==creates[1]['headers']['idempotency-key']
        await page.locator('#poolJobs .pool-job summary').click()
        await page.locator('textarea[aria-label="Funding invoice"]').wait_for()
        assert await page.locator('#poolJobs').get_by_role('button',name='Start',exact=True).is_disabled()
        # Funding confirmation is a server fixture mutation, not a UI claim.
        j=backend.jobs[0]; j['stage']='funded'; j['accounting'].update(state='funded',funded_msat=10000000)
        await page.locator('#poolRefresh').click()
        start=page.locator('#poolJobs').get_by_role('button',name='Start',exact=True)
        await start.wait_for(); await page.wait_for_function('!Array.from(document.querySelectorAll("#poolJobs button")).find(b=>b.textContent==="Start").disabled')
        await start.click()
        await page.wait_for_function('Array.from(document.querySelectorAll("#poolJobs button")).some(b=>b.textContent==="Update authorization")')
        first=[p for p in backend.posts if p['path'].endswith('/start')][-1]
        assert first['body']['auto_pay'] is False and first['body']['confirm']=='start funded indexing'
        await page.locator('#poolJobs').get_by_role('button',name='Pause',exact=True).click()
        await page.wait_for_function('Array.from(document.querySelectorAll("#poolJobs button")).some(b=>b.textContent==="Start")')
        await page.locator('.pool-pay-consent input').check()
        await page.locator('#poolJobs').get_by_role('button',name='Start',exact=True).click()
        await page.wait_for_function('Array.from(document.querySelectorAll("#poolJobs button")).some(b=>b.textContent==="Update authorization")')
        last=[p for p in backend.posts if p['path'].endswith('/start')][-1]
        assert last['body']['auto_pay'] is True and last['body']['confirm']=='start and pay verified segments'
        # Mock a verified segment to inspect metrics and accountability display.
        j['results']={UNITS[0]['id']:dict(phase='accepted'),UNITS[1]['id']:dict(phase='verifying')}
        j['accounting'].update(reserved_msat=7500000,spent_msat=1666200,node_allocations=[dict(actor='ak_desktop-a',paid_reward_msat=1666000,earned_unpaid_msat=0,reserved_msat=5000000)])
        await page.locator('#poolRefresh').click(); await page.locator('#poolMetrics').get_by_text('1,666.2 sats').wait_for()
        assert await page.locator('#poolJobs details[open]').count()==1
        await page.evaluate('window.scrollTo(0,0)')
        await page.screenshot(path=str(OUT/'ecai-funded-indexing-desktop.png'),full_page=True)
        await page.locator('#poolJobs').get_by_role('button',name='Export contract').click()
        await page.wait_for_function('window.__exports.length===1')
        assert (await page.evaluate('window.__exports[0]')).startswith('ecai-index-contract-')
        await page.set_viewport_size(dict(width=390,height=844))
        await page.evaluate('window.scrollTo(0,0)'); await page.wait_for_timeout(120)
        overflow=await page.evaluate('document.documentElement.scrollWidth-document.documentElement.clientWidth')
        assert overflow<=1, f'Mobile overflow: {overflow}'
        await page.screenshot(path=str(OUT/'ecai-funded-indexing-mobile.png'),full_page=True)
        # Cookie-only restored sessions may read but must not offer mutations.
        cookie=await context.new_page(); cookie.on('pageerror',lambda e:errors.append(str(e)))
        await load_fixture(cookie, backend)
        await cookie.locator('#indexPoolNav').wait_for(state='visible')
        await cookie.locator('#indexPoolNav').click()
        await cookie.locator('#poolNodes .pool-node').first.wait_for()
        assert await cookie.locator('#poolPreview').is_disabled()
        assert await cookie.locator('#poolJoin').is_disabled()
        await cookie.close()
        # A delayed read must not restore sensitive pool state after logout.
        backend.delay_status=0.4
        await page.evaluate('void window.EcaiIndexPool.refresh()')
        await page.locator('#logoutBtn').click(); await page.wait_for_timeout(600)
        assert await page.locator('#indexPoolNav').is_hidden()
        assert await page.locator('#poolJobs').inner_text()==''
        assert await page.locator('#poolNodeChoices').inner_text()==''
        assert 'simplewiki' not in await page.locator('#poolPlan').inner_text()
        backend.delay_status=0; backend.admin=False
        await page.set_viewport_size(dict(width=1440,height=1100))
        await page.locator('#loginBtn').click()
        await page.locator('#consoleLoginForm input[name=email]').fill('ordinary@example.invalid')
        await page.locator('#consoleLoginForm input[name=password]').fill('mock-only')
        await page.locator('#consoleLoginSubmit').click(); await page.wait_for_timeout(200)
        assert await page.locator('#indexPoolNav').is_hidden()
        assert not errors, errors
        print('PASS: admin navigation; signed-join request; budget quote/invalidation; idempotent create retry; funding gate; separate payment consent; accordion preservation; contract export; desktop/mobile layout; cookie-only read-only; logout race; non-admin exclusion.')
        print('Browser tests use mocked HTTP. No backend, CLN or payment executed.')
        await browser.close()

if __name__=='__main__': asyncio.run(main())
