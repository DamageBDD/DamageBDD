#!/usr/bin/env python3
"""Browser smoke test for the real billing component against a local mock API.
Requires Python playwright + Chromium. Does NOT test Erlang/Cowboy or send mail.
Run from repo root: python tools/check_invoice_ui.py --output /tmp/billing-ui-check
"""
import argparse, copy, json, threading, re
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from playwright.sync_api import sync_playwright, expect

REPO = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--output', default='/tmp/billing-ui-check')
args = parser.parse_args()
OUT = Path(args.output); OUT.mkdir(parents=True, exist_ok=True)
class Static(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw): super().__init__(*a, directory=str(REPO/'apps/damage/priv'), **kw)
    def log_message(self, *a): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Static)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f'http://127.0.0.1:{server.server_port}'
fragment = (REPO/'apps/damage/priv/templates/ui/dashboard/billing_tab.mustache').read_text()
page_html = '''<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="/static/css/billing.css"><style>body{margin:20px;background:#eef2f7;font-family:Arial,sans-serif} .demo{max-width:1320px;margin:auto;color:#40546a;font-size:12px}</style></head><body>
<div class="demo">DAMAGEBDD · INVOICES COMPONENT · DEMONSTRATION DATA ONLY</div><nav><span id="billing-nav" hidden></span></nav>'''+fragment+'''
<script>window.testToken='node-admin';window.TokenManager={getToken:()=>window.testToken};</script>
<script type="module" src="/static/js/billing.js"></script></body></html>'''
customers = [dict(id='example-monthly', name='Example Monthly Pty Ltd', email='example-monthly@example.invalid', address='Attn: Accounts Payable\nExample billing address', abn='', enabled=True, revision=1),
    dict(id='example-fortnightly', name='Example Fortnightly Company', email='example-fortnightly@example.invalid', address='Demonstration account', abn='', enabled=True, revision=1),
    dict(id='max', name='Example customer — details required', email='', address='', abn='', enabled=False, revision=1)]
line = dict(description='Operations & maintenance retainer',quantity=1,unit_price_minor=85000,discount_minor=0,tax_bps=0,subtotal_minor=85000,tax_minor=0,total_minor=85000)
plans = [dict(id='example-monthly-monthly',customer_id='example-monthly',name='Monthly infrastructure support',cadence='monthly',start_date='2026-10-01',next_date='2026-11-01',anchor_day=1,generated_count=1,revision=1,enabled=True,auto_send=False,currency='AUD',terms_days=7,payment_profile='example-monthly',notes='AWS costs excluded.',items=[line])]
invoices = [dict(id='a'*64,plan_id='example-monthly-monthly',customer=copy.deepcopy(customers[0]),period_start='2026-10-01',period_end='2026-10-31',number='DEMO-ENT-000001',status='issued',revision=3,title='Monthly infrastructure support',currency='AUD',terms_days=7,issued_on='2026-10-09',due_on='2026-10-16',created_at=1791500000,items=[line],subtotal_minor=85000,tax_minor=0,total_minor=85000,notes='AWS infrastructure costs are excluded and billed directly. Demonstration only; do not pay.',delivery={'status':'not_sent','generation':0},pdf_sha256='demo',audit=[dict(at=1791500000,action='issued',actor='ak_DemoNodeAdmin',note='Demonstration only')]),
    dict(id='b'*64,plan_id='example-fortnightly-fortnightly',customer=copy.deepcopy(customers[1]),period_start='2026-10-09',period_end='2026-10-22',number=None,status='draft',revision=1,title='Fortnightly operations & support',currency='AUD',terms_days=0,created_at=1791490000,items=[dict(line,unit_price_minor=10000,subtotal_minor=10000,total_minor=10000)],subtotal_minor=10000,tax_minor=0,total_minor=10000,notes='Initial setup waived; commencement and acceptance require review.',delivery={'status':'not_sent','generation':0},audit=[])]
requests=[]; failures=[]; checks=[]; state={'role':'node_admin','fail_write':False}
def mock(route):
    req=route.request; u=urlparse(req.url); path=u.path.removeprefix('/api/billing'); method=req.method
    data=req.post_data_json if req.post_data else {}; requests.append((method,path,data,req.headers))
    def reply(payload, status=200): route.fulfill(status=status,content_type='application/json',body=json.dumps({'status':'ok' if status==200 else 'error', **({'data':payload} if status==200 else {'message':payload})}))
    if req.headers.get('authorization') not in ['Bearer node-admin','Bearer invoice-admin']: return reply('Forbidden',403)
    if path=='/session': return reply(dict(role=state['role'],can_manage_admins=state['role']=='node_admin',clock='node_local',send_hour=9,auto_send_enabled=False,payment_profiles=['default','example-monthly','example-fortnightly']))
    if state['fail_write'] and method!='GET': return reply('Injected save failure',503)
    if path=='/customers':
        if method=='POST': customers.append(dict(data,revision=1)); return reply(customers[-1])
        return reply({'items':customers})
    if path=='/plans':
        if method=='POST': plans.append(dict(data,next_date=data['start_date'],generated_count=0,revision=1)); return reply(plans[-1])
        return reply({'items':plans})
    if path=='/admins': return reply({'items':[{'account':'ak_DemoInvoiceAdmin','source':'managed'}], 'audit':[]})
    if path=='/invoices':
        q=parse_qs(u.query); rows=[i for i in invoices if (not q.get('status') or i['status']==q['status'][0]) and (not q.get('customer_id') or i['customer']['id']==q['customer_id'][0])]
        return reply({'items':rows,'total':len(rows),'offset':0,'limit':50})
    parts=path.strip('/').split('/')
    if len(parts)>=2 and parts[0]=='invoices':
        invoice=next(i for i in invoices if i['id']==parts[1])
        if method=='GET': return reply(invoice)
        assert data['revision']==invoice['revision'], 'Frontend sent stale revision'
        if len(parts)==3 and parts[2]=='send': invoice['delivery']={'status':'sent','generation':1}; invoice['revision']+=1; return reply(invoice)
        if len(parts)==3 and parts[2]=='issue': invoice.update(status='issued',number='DEMO-ENT-000002',issued_on='2026-10-09',due_on='2026-10-09',pdf_sha256='demo',revision=2);return reply(invoice)
        if method=='PUT': invoice.update(data);invoice['revision']+=1;return reply(invoice)
    return reply('Mock route not implemented',404)
try:
    with sync_playwright() as p:
        browser=p.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox'])
        page=browser.new_page(viewport={'width':1440,'height':1100})
        page.on('pageerror',lambda e:failures.append(str(e)))
        page.on('dialog',lambda d:d.accept())
        # No browser navigation or external traffic is needed for a component
        # test. Exercise the actual fetch call through an in-process mock.
        def bridge(_source, url, options):
            class Req: pass
            req=Req(); req.url=BASE+url; req.method=options.get('method','GET'); req.headers={k.lower():v for k,v in options.get('headers',{}).items()}
            req.post_data=options.get('body'); req.post_data_json=json.loads(req.post_data) if req.post_data else None
            class Route:
                request=req
                def fulfill(self, **kw): self.response=kw
            route=Route(); mock(route); return route.response
        page.expose_binding('invoiceMock',bridge)
        html=re.sub(r'<link[^>]+>|<script type="module"[^>]+></script>', '', page_html)
        page.set_content(html)
        page.add_style_tag(content=(REPO/'apps/damage/priv/static/css/billing.css').read_text())
        page.evaluate("""() => {
          const memory=new Map(); Object.defineProperty(window,'localStorage',{value:{getItem:k=>memory.get(k)||null,setItem:(k,v)=>memory.set(k,v),removeItem:k=>memory.delete(k)}});
          window.fetch=async (url,options={})=>{const r=await window.invoiceMock(url,options);return new Response(r.body,{status:r.status||200,headers:{'content-type':r.content_type||'application/json'}})};
        }""")
        page.add_script_tag(type='module',content=(REPO/'apps/damage/priv/static/js/billing.js').read_text())
        expect(page.locator('#billing-invoice-rows tr')).to_have_count(2)
        expect(page.locator('#billing-admins-nav')).to_be_visible(); checks.append('Node administrator discovers billing and role-management UI')
        page.locator('#billing-invoice-rows [data-billing-action=view]').first.click()
        expect(page.locator('#billing-detail')).to_contain_text('AUD 850.00')
        page.screenshot(path=str(OUT/'billing-desktop.png'),full_page=True)
        page.locator('#billing-detail [data-billing-action=send]').click()
        expect(page.locator('#billing-detail')).to_contain_text('sent')
        sends=[r for r in requests if r[0]=='POST' and r[1].endswith('/send')]
        assert len(sends)==1 and sends[0][2]=={'revision':3,'confirm_resend':False}
        checks.append('Send submits one authenticated, revision-checked request after confirmation')
        expect(page.locator('[data-billing-action=next]')).to_be_disabled(); checks.append('Pagination remains disabled at last page after mutations')
        page.locator('[data-billing-pane=customers]').click(); page.locator('[data-billing-action=new-customer]').click()
        form=page.locator('#billing-customer-form'); form.locator('[name=id]').fill('test-customer');form.locator('[name=name]').fill('<img src=x onerror=alert(1)>');form.locator('[name=email]').fill('safe@example.invalid')
        form.locator('button[type=submit]').click(); expect(page.locator('#billing-customer-dialog')).not_to_be_visible()
        expect(page.locator('#billing-customer-rows')).to_contain_text('<img src=x onerror=alert(1)>');assert page.locator('#billing-customer-rows img').count()==0
        checks.append('Customer content is rendered as text, not executable HTML')
        page.locator('[data-billing-pane=plans]').click();page.locator('[data-billing-action=new-plan]').click()
        form=page.locator('#billing-plan-form');form.locator('[name=id]').fill('precise-plan');form.locator('[name=name]').fill('Precise money');form.locator('[name=start_date]').fill('2026-10-09')
        form.locator('[data-line-field=description]').fill('Decimal correctness');form.locator('[data-line-field=unit_price_minor]').fill('0.29');form.locator('[data-line-field=tax_bps]').fill('10.00');form.locator('button[type=submit]').click()
        expect(page.locator('#billing-plan-dialog')).not_to_be_visible();newplan=next(r[2] for r in requests if r[0]=='POST' and r[1]=='/plans')
        assert newplan['items'][0]['unit_price_minor']==29 and newplan['items'][0]['tax_bps']==1000
        checks.append('Form transmits decimal amounts as exact integer cents and integer tax basis points')
        page.locator('[data-billing-pane=customers]').click(); page.locator('[data-billing-action=new-customer]').click()
        form=page.locator('#billing-customer-form');form.locator('[name=id]').fill('failure-test');form.locator('[name=name]').fill('Failure test');state['fail_write']=True
        form.locator('button[type=submit]').click();expect(form.locator('.billing-form-error')).to_contain_text('Injected save failure');expect(form.locator('button[type=submit]')).to_be_enabled()
        checks.append('A failed write displays its reason and re-enables form actions');state['fail_write']=False;form.locator('[data-billing-close]').click()
        page.locator('[data-billing-pane=invoices]').click();page.locator('#billing-invoice-rows [data-billing-action=view]').first.click()
        page.set_viewport_size({'width':390,'height':844});page.screenshot(path=str(OUT/'billing-mobile.png'),full_page=True)
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth+2')
        checks.append('390px layout contains horizontal table scrolling without page overflow')
        state['role']='invoice_admin';page.evaluate("window.testToken='invoice-admin';document.dispatchEvent(new Event('auth:changed'))")
        expect(page.locator('#billing-invoice-rows tr')).to_have_count(2);expect(page.locator('#billing-admins-nav')).not_to_be_visible()
        checks.append('Invoice administrator has billing UI without role-management controls')
        page.evaluate("window.testToken='';localStorage.removeItem('access_token');document.dispatchEvent(new Event('auth:changed'))")
        expect(page.locator('#enterprise-billing')).not_to_be_visible();assert page.locator('#billing-customer-rows').inner_text()=='';assert page.locator('#billing-detail').inner_text()==''
        checks.append('Logout clears billing records, selections, forms and navigation')
        page.evaluate("window.testToken='ordinary';document.dispatchEvent(new Event('auth:changed'))")
        page.wait_for_timeout(100);expect(page.locator('#enterprise-billing')).not_to_be_visible();checks.append('Ordinary account cannot reveal private billing UI')
        assert not failures, failures
        browser.close()
    report={'scope':'Real billing.js/component; mocked API; no Erlang/Cowboy/SMTP exercised','passed':checks,'browser_errors':failures}
    (OUT/'ui-checks.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
finally: server.shutdown()
