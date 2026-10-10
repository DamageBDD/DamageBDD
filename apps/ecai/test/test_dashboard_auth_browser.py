#!/usr/bin/env python3
"""Chromium regressions using production ECAI + shared DamageBDD auth assets.

All APIs and wallet transport are mocked. This exercises DOM, module loading,
callbacks, reload and browser-cookie handling, not Cowboy, SMTP, real wallet
signatures or Lightning. No external endpoint is contacted.
"""
import asyncio
import sys
import json
import os
import re
import shutil
import tempfile
import time
import html
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
from playwright.async_api import async_playwright

APP = Path(__file__).resolve().parents[1]
DAMAGE = APP.parent / 'damage'
ORIGIN = 'https://ecai-auth.test'
A = 'ak_2a9NeTAfBwLn87TT77raYc6MKmwsZApa3PBLMTwkvcCHkaGpHE'
B = 'ak_11111111111111111111111111111111273Yts'
OUT = Path(os.environ.get('ECAI_SCREENSHOTS', tempfile.gettempdir()))
DOM_ONLY = '--dom-only' in sys.argv

def render(text, ctx):
    sections = re.compile(r'{{([#^])\s*(\w+)\s*}}((?:(?!{{[#^]).)*?){{/\s*\2\s*}}', re.S)
    while sections.search(text):
        text = sections.sub(lambda m: m[3] if bool(ctx.get(m[2])) == (m[1] == '#') else '', text)
    text = re.sub(r'{{{\s*(\w+)\s*}}}', lambda m: str(ctx.get(m[1], '')), text)
    return re.sub(r'{{\s*(\w+)\s*}}', lambda m: html.escape(str(ctx.get(m[1], ''))), text)

def console_html():
    ctx = dict(node_version='auth fixture', logo_image='/ecai/auth-assets/img/logo.png',
               auth_auto_open='false', auth_callback_path='/dashboard', auth_allow_guest=True,
               auth_hide_node_wallet=True)
    ctx['browser_auth_modal'] = render((DAMAGE/'priv/templates/ui/dashboard/auth_modal.mustache').read_text(), ctx)
    return render((APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text(), ctx)

WALLET = '''// TEST DOUBLE: no actual extension, signing keys or transactions.
const W = window.__walletFixture = {connects:0, signs:0, tx:0, network:'ae_mainnet',
  account:'ADDRESS', reject:false, hold:false, release:null};
export async function detect(){return {ok:true,result:{networkId:W.network}};}
export async function connect(){W.connects++;return {ok:!W.reject,result:{networkId:W.network}};}
export async function address(){return {ok:true,result:{address:{current:{[W.account]:{}}}}};}
export async function msg_sign(){W.signs++;if(W.hold)await new Promise(r=>W.release=r);
  return {ok:!W.reject,result:{signature:'a'.repeat(128)}};}
export const cl=()=>({});
'''.replace('ADDRESS', A)

class Backend:
    def __init__(self):
        self.sessions = {}; self.serial = 0; self.requests = []; self.admin = True
        self.login_error = False; self.signup_error = False; self.logout_error = False; self.signup_markup = False
        self.wallet_missing = False; self.challenge_used = False; self.last_challenge = None
        self.deep_link = None; self.delay_admin = None
    def issue(self, mode, address=A):
        self.serial += 1
        token = 'ds1.' + format(self.serial, '064x')
        s = dict(authenticated=True,status='ok',mode=mode,address=address,access_token=token,
                 email='operator@example.test' if mode=='custodial' else None,
                 expires_at=int(time.time())+3600,
                 capabilities=dict(execute=mode=='custodial', transfer=mode=='custodial',
                                   reason='Wallet-only paid operations unavailable'))
        self.sessions[token] = s
        return s
    def session(self, request):
        token = request.headers.get('authorization','').removeprefix('Bearer ')
        if not token:
            m=re.search(r'(?:^|;\s*)sessionid=([^;]+)',request.headers.get('cookie',''))
            token=m[1] if m else ''
        return self.sessions.get(token)
    def count(self, path, method=None):
        return sum(p==path and (not method or m==method) for m,p in self.requests)
    async def route(self, route):
        req=route.request; u=urlsplit(req.url); p=u.path; method=req.method
        if u.netloc=='wallet.superhero.com':
            self.deep_link=req.url
            return await route.fulfill(body='<title>Fake wallet app</title>', content_type='text/html')
        if u.netloc!=urlsplit(ORIGIN).netloc:
            return await route.abort()
        if p in ('/','/dashboard'):
            return await route.fulfill(body=console_html(),content_type='text/html')
        if p.startswith('/ecai/auth-assets/'):
            rel=p.removeprefix('/ecai/auth-assets/')
            if rel=='js/sidekick.js':
                return await route.fulfill(body=WALLET,content_type='text/javascript')
            if rel=='js/wallet.js' and self.wallet_missing:
                return await route.fulfill(body='export const legacy=true;',content_type='text/javascript')
            file=DAMAGE/'priv/static'/rel
        elif p.startswith('/static/'):
            file=APP/'priv/static'/p.removeprefix('/static/')
        else:
            file=None
        if file:
            if not file.is_file(): return await route.fulfill(status=404,body='Asset missing')
            mime='text/javascript' if file.suffix=='.js' else 'text/css' if file.suffix=='.css' else 'image/png'
            return await route.fulfill(body=file.read_bytes(),content_type=mime)
        self.requests.append((method,p))
        data={}; status=200; headers={'content-type':'application/json','cache-control':'no-store'}
        s=self.session(req)
        body=req.post_data_json if req.post_data else {}
        if p.startswith('/accounts/'):
            # Mirror the uploaded HTTP flow's browser header/origin boundary.
            if req.headers.get('x-damage-auth')!='1' or (method=='POST' and req.headers.get('origin')!=ORIGIN):
                return await route.fulfill(status=403,json={'message':'Origin rejected'})
        if p=='/accounts/auth/options': data=dict(origin=ORIGIN,network_id='ae_mainnet')
        elif p=='/accounts/session':
            data=s or dict(authenticated=False,error='session_expired');status=200 if s else 401
        elif p=='/accounts/login':
            if self.login_error: data={'message':'Email or password is incorrect.'};status=401
            else:
                data=self.issue('custodial');headers['set-cookie']='sessionid='+data['access_token']+'; Path=/; HttpOnly; Secure; SameSite=Lax'
        elif p=='/accounts/signup':
            data={'message':('<img src=x onerror=alert(1)> ' if self.signup_markup else 'Check your inbox. ')+ 'Confirmation requested for '+body.get('email','')}
            if self.signup_error: data={'message':'Mail unavailable. Try again.'};status=503
        elif p=='/accounts/recovery': data={'message':'Check your inbox for the reset link.'}
        elif p=='/accounts/wallet/challenge':
            self.challenge_used=False
            self.last_challenge=dict(status='ok',address=body['address'],network_id='ae_mainnet',
                challenge_id='c'*64,message='Sign in to DamageBDD\nOrigin: '+ORIGIN+'\nNo payments or channels authorized.',
                expires_at=int(time.time())+180)
            data=self.last_challenge
        elif p=='/accounts/wallet/verify':
            if self.challenge_used or not self.last_challenge or body.get('challenge_id')!=self.last_challenge['challenge_id']:
                data={'message':'Invalid or used challenge'};status=401
            else:
                self.challenge_used=True
                data=self.issue('wallet',self.last_challenge['address'])
                headers['set-cookie']='sessionid='+data['access_token']+'; Path=/; HttpOnly; Secure; SameSite=Lax'
        elif p=='/accounts/session/logout':
            if self.logout_error: data={'message':'Auth unavailable'};status=503
            else:
                if s:self.sessions.pop(s['access_token'],None)
                data={'status':'ok'};headers['set-cookie']='sessionid=; Path=/; HttpOnly; Secure; Max-Age=0'
        elif p=='/ecai/auth/session':
            admin=bool(s and s['mode']=='custodial' and self.admin)
            data=dict(authenticated=bool(s),public_key=s['address'] if s else None,
                      node_admin=admin,code_admin=admin,code_admin_enabled=True,auth_mode=s['mode'] if s else 'anonymous')
        elif p=='/ecai/chat': data={'status':'ok'}
        elif p=='/ecai/search': data={'results':[], 'proofs':[]}
        elif p=='/yelp/status': data={'index_size':{'docs':120}}
        elif p.startswith('/ecai/admin/') and (not s or s['mode']=='wallet' or not self.admin):
            data={'ok':False,'error':'admin_role_required'};status=403
        elif p=='/ecai/admin/code/status':
            if self.delay_admin: await self.delay_admin.wait()
            data={'ok':True,'status':{'learning':{'learner':{'completed':6,'total':10,'phase':'learning','progress_percent':60},
                 'patch_manager':{'active':1,'pending':2,'max_concurrent':2},'integration':{'job_counts':{'clean':3,'broken':0}}},
                 'reviews':{'required_approvals':1,'publish_enabled':False,'counts':{}}}}
        elif p=='/ecai/admin/code/repairs':data={'ok':True,'repairs':[]}
        elif p=='/ecai/admin/code/reviews':data={'ok':True,'reviews':[],'queue':{}}
        elif p=='/ecai/admin/index-pool/status':data={'ok':True,'enabled':False,'peers':[],'jobs':[]}
        elif p=='/ecai/index-jobs/status':data={'ok':True,'status':{'running_jobs':0,'queued_jobs':0,'canceled_checkpoint_retry':True}}
        elif p=='/ecai/index-jobs/presets':data={'ok':True,'presets':[]}
        elif p=='/ecai/index-jobs':data={'ok':True,'jobs':[]}
        else: data={'error':'unexpected_mock_route','path':p};status=404
        await route.fulfill(status=status,body=json.dumps(data),headers=headers)

async def ready(page):
    await page.wait_for_function('!!window.DamageAuth && !!window.TokenManager')
    await page.wait_for_timeout(150)

async def mount(browser, backend, viewport=None):
    ctx=await browser.new_context(viewport=viewport or {'width':1440,'height':950})
    if DOM_ONLY:
        from dashboard_auth_dom_fixture import install_transport
        await install_transport(ctx,backend)
    else:
        await ctx.route('**/*',backend.route)
    page=await ctx.new_page();page.set_default_timeout(12000);errors=[]
    page.on('pageerror',lambda e:errors.append(str(e)))
    page.on('dialog',lambda d:asyncio.create_task(d.dismiss()))
    page.fixture_backend=backend
    await visit(page, ORIGIN+'/dashboard');await ready(page)
    return ctx,page,errors

async def visit(page, url):
    if not DOM_ONLY: return await page.goto(url)
    from dashboard_auth_dom_fixture import offline_html
    try: storage=await page.evaluate('Object.fromEntries(Object.entries(sessionStorage))')
    except Exception:storage={}
    await page.goto('about:blank')
    await page.set_content(offline_html(console_html(),WALLET,page.fixture_backend.wallet_missing,storage,
        '#'+urlsplit(url).fragment if urlsplit(url).fragment else ''))

async def finish_reload(page):
    if DOM_ONLY:
        await page.wait_for_function('window.__requestedReload === true')
        await visit(page,ORIGIN+'/dashboard');await ready(page)

async def reload_page(page):
    if DOM_ONLY: await visit(page,ORIGIN+'/dashboard')
    else: await page.reload()
    await ready(page)

async def wallet_link(page,backend):
    if DOM_ONLY:
        await page.wait_for_function('!!window.__fixtureRedirect')
        return await page.evaluate('window.__fixtureRedirect')
    await page.wait_for_url('https://wallet.superhero.com/**')
    return backend.deep_link

async def email_login(page):
    await page.locator('#loginBtn').click()
    await page.locator('#login-username').fill('operator@example.test')
    await page.locator('#password').fill('FixtureOnly!123')
    await page.locator('#loginSubmitBtn').click()
    await finish_reload(page)
    await page.locator('#logoutBtn').wait_for(state='visible')
    await page.wait_for_timeout(250)

async def scenario_guest(browser):
    b=Backend();ctx,p,errors=await mount(browser,b)
    assert await p.locator('#login-modal').is_hidden()
    assert b.count('/ecai/index-jobs/status')==0
    assert b.count('/ecai/admin/code/status')==0
    b.signup_markup=True
    await p.locator('#createAccountBtn').click()
    await p.locator('#signup-username').fill('new@example.test')
    await p.locator('#signup-username').press('Enter')
    await p.locator('#signup-confirmation').wait_for(state='visible')
    assert b.count('/accounts/signup','POST')==1 and b.count('/accounts/login','POST')==0
    assert await p.locator('#connect-status img').count()==0
    assert '<img' in await p.locator('#connect-status').inner_text()
    assert not await p.evaluate('TokenManager.isAuthenticated()')
    assert await p.locator('#codeAdminNav').is_hidden()
    b.signup_markup=False
    await p.locator('#signupSubmitBtn').click()
    await p.locator('#connect-status').get_by_text('Check your inbox',exact=False).wait_for()
    OUT.mkdir(parents=True,exist_ok=True)
    await p.screenshot(path=str(OUT/'ecai-account-create-desktop.png'),full_page=False)
    await p.locator('#auth-login-tab').click()
    await p.locator('#login-username').fill('recover@example.test')
    await p.locator('#loginResetPasswdBtn').click()
    await p.locator('#recovery-email').press('Enter')
    await p.locator('#connect-status').get_by_text('reset link',exact=False).wait_for()
    assert b.count('/accounts/recovery','POST')==1 and b.count('/accounts/login')==0
    await p.locator('[data-auth-dismiss]').click()
    assert await p.locator('#login-modal').is_hidden()
    b.signup_error=True
    await p.locator('#createAccountBtn').click()
    await p.locator('#signupSubmitBtn').click()
    await p.locator('#connect-status').get_by_text('Mail unavailable',exact=False).wait_for()
    assert await p.locator('#signup-username').input_value()=='new@example.test'
    assert not errors,errors
    await ctx.close()
    return 'signup, recovery, form isolation, email retention, error escaping, guest access'

async def scenario_managed(browser):
    b=Backend();ctx,p,errors=await mount(browser,b)
    await email_login(p)
    await p.locator('#codeAdminNav').wait_for(state='visible')
    assert await p.evaluate('TokenManager.getToken().startsWith("ds1.")')
    assert await p.evaluate('localStorage.getItem("access_token")') is None
    await p.locator('#codeAdminNav').click()
    await p.locator('#codeMetrics .code-metric').first.wait_for(state='visible')
    assert '6 / 10' in await p.locator('#codeMetrics').inner_text()
    await reload_page(p)
    await p.locator('#codeAdminNav').wait_for(state='visible')
    assert await p.locator('#login-modal').is_hidden()
    b.logout_error=True
    await p.locator('#logoutBtn').click()
    await p.locator('#consoleAuthStatus').get_by_text('could not be confirmed',exact=False).wait_for()
    assert await p.evaluate('TokenManager.isAuthenticated()')
    b.logout_error=False
    await p.locator('#logoutBtn').click()
    await finish_reload(p)
    await p.locator('#loginBtn').wait_for(state='visible')
    assert await p.locator('#codeAdminNav').is_hidden()
    assert not await p.evaluate('TokenManager.getToken()')
    assert b.count('/accounts/auth/')==0 and b.count('/accounts/logout')==0
    assert not errors,errors
    await ctx.close()
    return 'managed ds1 login, reload restoration, admin metrics, revoking logout and failure handling'

async def scenario_wallet(browser):
    b=Backend();ctx,p,errors=await mount(browser,b)
    await p.locator('#connectWalletBtn').click()
    assert await p.evaluate('window.__walletFixture === undefined')
    await p.locator('#connect-button').click()
    await p.locator('#wallet-proof').wait_for(state='visible')
    assert not await p.evaluate('TokenManager.isAuthenticated()')
    assert await p.evaluate('__walletFixture.signs')==0
    await p.locator('#wallet-proof summary').click()
    assert ORIGIN in await p.locator('#wallet-proof-message').inner_text()
    await p.screenshot(path=str(OUT/'ecai-wallet-proof-desktop.png'),full_page=False)
    await p.set_viewport_size({'width':390,'height':844})
    await p.locator('#wallet-proof summary').click()  # compact default on a phone
    await p.screenshot(path=str(OUT/'ecai-wallet-proof-mobile.png'),full_page=False)
    assert await p.evaluate('document.documentElement.scrollWidth <= innerWidth')
    await p.locator('#wallet-sign-in').click()
    await finish_reload(p)
    await p.locator('#consoleWalletNotice').wait_for(state='visible')
    assert await p.evaluate('TokenManager.session().mode')=='wallet'
    assert await p.locator('#codeAdminNav').is_hidden() and await p.locator('#indexPoolNav').is_hidden()
    assert b.count('/ecai/index-jobs/status')==0 and b.count('/ecai/admin/code/status')==0
    await p.locator('#openNav').click()
    await p.locator('[data-view="indexing"]').click()
    assert await p.locator('#customJobForm button[type="submit"]').is_disabled()
    assert b.count('/ecai/index-jobs/status')==0
    await p.locator('#walletManagedLogin').click()
    await p.locator('#login-username').fill('bad@example.test')
    await p.locator('#password').fill('invalid')
    b.login_error=True
    await p.locator('#loginSubmitBtn').click()
    await p.locator('#connect-status').get_by_text('incorrect',exact=False).wait_for()
    assert await p.evaluate('TokenManager.session().mode')=='wallet'
    await p.locator('#auth-keep-session').click()
    assert await p.locator('#login-modal').is_hidden()
    assert not errors,errors
    await ctx.close()
    return 'lazy wallet connect, explicit proof, restricted wallet session, mobile layout, failed switch preserves identity'

async def scenario_wallet_errors(browser):
    b=Backend();b.wallet_missing=True;ctx,p,errors=await mount(browser,b)
    await p.locator('#connectWalletBtn').click();await p.locator('#connect-button').click()
    await p.locator('#connect-status').get_by_text('outdated wallet module',exact=False).wait_for()
    await p.locator('#auth-login-tab').click()
    await p.locator('#login-username').fill('operator@example.test');await p.locator('#password').fill('FixtureOnly!123')
    await p.locator('#loginSubmitBtn').click();await finish_reload(p);await p.locator('#logoutBtn').wait_for(state='visible')
    assert not errors,errors;await ctx.close()
    b=Backend();ctx,p,errors=await mount(browser,b)
    await p.locator('#connectWalletBtn').click();await p.locator('#connect-button').click()
    await p.locator('#wallet-proof').wait_for(state='visible')
    await p.evaluate('__walletFixture.account="'+B+'"')
    await p.locator('#wallet-sign-in').click()
    await p.locator('#connect-status').get_by_text('account changed',exact=False).wait_for()
    assert b.count('/accounts/wallet/verify')==0
    await p.evaluate('__walletFixture.account="'+A+'";__walletFixture.hold=true')
    await p.locator('#wallet-sign-in').click()
    await p.wait_for_function('__walletFixture.release !== null')
    await p.locator('#auth-cancel').click()
    await p.evaluate('__walletFixture.release()')
    await p.wait_for_timeout(100)
    assert b.count('/accounts/wallet/verify')==0
    assert not await p.evaluate('TokenManager.isAuthenticated()')
    assert not errors,errors;await ctx.close()
    return 'missing-wallet module recovery, account mismatch and cancelled signature cannot authenticate'

async def scenario_mobile(browser):
    b=Backend();ctx,p,errors=await mount(browser,b)
    await p.locator('#connectWalletBtn').click()
    await p.locator('#connect-mobile-wallet').click()
    link=await wallet_link(p,b)
    u=parse_qs(urlsplit(link).query);callback=u['x-success'][0]
    assert urlsplit(callback).path=='/dashboard' and '#wallet-callback?' in callback
    callback=callback.replace('{address}',A).replace('{networkId}','ae_mainnet')
    await visit(p,callback);await ready(p)
    await p.locator('#wallet-proof').wait_for(state='visible')
    assert '#wallet-callback?' not in (await p.evaluate('window.__fixtureLocation.hash') if DOM_ONLY else p.url)
    assert b.count('/accounts/wallet/verify')==0
    await p.locator('#wallet-sign-in').click()
    link=await wallet_link(p,b)
    u=parse_qs(urlsplit(link).query);assert 'encoding' not in u
    assert ORIGIN in u['message'][0]
    callback=u['x-success'][0].replace('{address}',A).replace('{signature}','a'*128)
    await visit(p,callback);await ready(p)
    await finish_reload(p)
    await p.locator('#consoleWalletNotice').wait_for(state='visible')
    assert b.count('/accounts/wallet/verify')==1
    # Reusing the callback after its tab nonce was removed must fail before POST.
    await visit(p,callback);await ready(p)
    await p.locator('#connect-status').get_by_text('stale',exact=False).wait_for()
    assert b.count('/accounts/wallet/verify')==1
    assert not errors,errors;await ctx.close()
    return 'mobile address/sign handoffs, /dashboard return, fragment scrubbing and replay rejection'

async def main():
    OUT.mkdir(parents=True,exist_ok=True)
    async with async_playwright() as pw:
        executable=os.environ.get('CHROMIUM') or shutil.which('chromium')
        browser=await pw.chromium.launch(**({'executable_path':executable} if executable else {}),
                  headless=True,args=['--no-sandbox','--disable-dev-shm-usage'])
        for scenario in [scenario_guest,scenario_managed,scenario_wallet,scenario_wallet_errors,scenario_mobile]:
            print('PASS:',await scenario(browser),flush=True)
        await browser.close()
    print('All dashboard browser-auth scenarios passed; API and wallet mocked.' + (' DOM-only: origin, storage, cookies and reload simulated.' if DOM_ONLY else ''))

if __name__=='__main__':asyncio.run(main())
