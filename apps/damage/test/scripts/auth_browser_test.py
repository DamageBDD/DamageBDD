#!/usr/bin/env python3
"""Chromium cross-checks of production auth UI with an explicitly fake RPC/API.
Not Selenium/Appium transport, cryptography, SMTP, or live OTP integration tests.
"""
import argparse, json, threading
from pathlib import Path
from playwright.sync_api import sync_playwright, expect
from auth_webdriver_fixture import server


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--out',default='/tmp/damage-auth-ui');parser.add_argument('--chromium',default='/usr/bin/chromium');parser.add_argument('--dom-only',action='store_true')
    args=parser.parse_args();out=Path(args.out);out.mkdir(parents=True,exist_ok=True)
    service=server(port=0);thread=threading.Thread(target=service.serve_forever,daemon=True);thread.start()
    base=f'http://127.0.0.1:{service.server_address[1]}';checks=[];errors=[]
    try:
        with sync_playwright() as p:
            browser=p.chromium.launch(executable_path=args.chromium,args=['--no-sandbox'])
            def fresh(width=1280,height=1000,path='/'):
                context=browser.new_context(viewport={'width':width,'height':height})
                page=context.new_page();page.on('pageerror',lambda e: errors.append(str(e)))
                if args.dom_only:
                    from auth_dom_fixture import offline_html
                    context.route('**/*',lambda route:route.abort())
                    page.set_content(offline_html(path=='/password'),wait_until='load')
                else:page.goto(base+path)
                page.wait_for_function('typeof window.__authFixture === "object"')
                if path=='/':expect(page.locator('#login-username')).to_be_visible()
                return context,page
            def record(name,fn):
                fn();checks.append({'name':name,'passed':True});print('PASS',name,flush=True)
            def counts(page):return page.evaluate('window.__authFixture.counts')
            def mode(page,value):page.evaluate('(v)=>window.__authFixture.mode=v',value)
            def email(page,value='test@fixture.example'):
                page.fill('#login-username',value);page.fill('#password','TestPassword1!')
            c,page=fresh()
            record('email default and autofocus',lambda:expect(page.locator('#login-username')).to_be_focused())
            record('no wallet prompts on load',lambda:assert_counts(counts(page),connect=0,sign=0,verify=0,tx=0))
            page.screenshot(path=str(out/'login-desktop.png'),full_page=True)
            page.click('#auth-show-password')
            record('password visibility toggle',lambda:expect(page.locator('#password')).to_have_attribute('type','text'))
            page.click('#auth-signup-tab');page.fill('#signup-username','signup@fixture.example');page.press('#signup-username','Enter')
            record('signup Enter sends only signup',lambda:expect(page.locator('#signup-confirmation')).to_be_visible())
            record('signup does not sign in or login',lambda:assert_counts(counts(page),signup=1,login=0,verify=0))
            page.screenshot(path=str(out/'signup-desktop.png'),full_page=True)
            page.click('#auth-login-tab');page.fill('#login-username','return@fixture.example');page.click('#loginResetPasswdBtn')
            record('recovery keeps email',lambda:expect(page.locator('#recovery-email')).to_have_value('return@fixture.example'))
            page.press('#recovery-email','Enter')
            record('recovery has its own submission',lambda:expect(page.locator('#connect-status')).to_contain_text('Reset link'))
            record('recovery never logs in',lambda:assert_counts(counts(page),login=0,recovery=1))
            c.close()
            for failure,text in [('invalid','incorrect'),('unavailable','unavailable'),('malformed','valid browser session')]:
                c,page=fresh();email(page);mode(page,failure);page.click('#loginSubmitBtn')
                record('email error: '+failure,lambda:expect(page.locator('#connect-status')).to_contain_text(text))
                record('email retry enabled: '+failure,lambda:expect(page.locator('#loginSubmitBtn')).to_be_enabled())
                record('email retained: '+failure,lambda:expect(page.locator('#login-username')).to_have_value('test@fixture.example'));c.close()
            c,page=fresh();email(page);mode(page,'html-error');page.click('#loginSubmitBtn')
            record('error HTML rendered as text',lambda:expect(page.locator('#connect-status')).to_contain_text('<img'))
            record('error HTML not executed',lambda:assert_js(page,'!window.pwned && !document.querySelector("#connect-status img")'));c.close()
            c,page=fresh();email(page);mode(page,'hold');page.click('#loginSubmitBtn')
            page.evaluate("document.querySelector('#loginSignupForm').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))")
            record('double submission guarded',lambda:assert_counts(counts(page),login=1))
            record('in-flight controls disabled',lambda:expect(page.locator('#auth-wallet-tab')).to_be_disabled())
            page.evaluate('window.__authFixture.release()')
            record('email session accepted',lambda:expect(page.locator('#auth-fixture-dashboard')).to_be_visible())
            record('browser credentials absent from localStorage',lambda:assert_js(page,'Object.keys(localStorage).length===0'))
            page.click('#fixture-switch')
            record('account switch can be abandoned',lambda:expect(page.locator('#auth-keep-session')).to_be_visible())
            page.click('#auth-keep-session')
            record('abandoning switch keeps current session',lambda:assert_js(page,'window.TokenManager.isAuthenticated() && window.TokenManager.getMode()==="custodial"'))
            record('abandoning switch never signs',lambda:assert_counts(counts(page),sign=0,verify=0));c.close()
            c,page=fresh();page.click('#auth-wallet-tab');page.click('#connect-button')
            record('connection shows review',lambda:expect(page.locator('#wallet-proof')).to_be_visible())
            record('connection alone not authentication',lambda:assert_counts(counts(page),connect=1,challenge=1,sign=0,verify=0,tx=0))
            page.locator('#wallet-proof details').evaluate('(el)=>el.open=true');page.screenshot(path=str(out/'wallet-review-desktop.png'),full_page=True)
            page.click('#wallet-sign-in')
            record('explicit sign completes wallet session',lambda:expect(page.locator('#auth-fixture-dashboard')).to_be_visible())
            record('no transaction from wallet login',lambda:assert_counts(counts(page),sign=1,verify=1,tx=0))
            record('wallet-only transfer disabled',lambda:expect(page.locator('#fixture-pay')).to_be_disabled())
            page.evaluate("document.querySelector('#fixture-transfer').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))")
            record('wallet-only form submit blocked',lambda:assert_counts(counts(page),tx=0))
            mode(page,'logout-error');page.click('#fixture-disconnect')
            record('failed logout keeps authenticated state',lambda:assert_js(page,'window.TokenManager.isAuthenticated()'))
            record('failed logout is visible in the wallet panel',lambda:expect(page.locator('[data-session-feedback]')).to_contain_text('Sign-out could not be confirmed'))
            # Error must finish before another explicit operation; never claim a failed sign-out succeeded.
            page.wait_for_function('document.querySelector("#login-modal").getAttribute("aria-busy")==="false"')
            mode(page,'ok');page.click('#fixture-disconnect')
            record('disconnect signs out, no fallback identity',lambda:expect(page.locator('#login-username')).to_be_visible());c.close()
            for failure,text in [('connect-reject','declined'),('wrong-network','ae_mainnet')]:
                c,page=fresh();page.click('#auth-wallet-tab');mode(page,failure);page.click('#connect-button')
                record('wallet connection error: '+failure,lambda:expect(page.locator('#connect-status')).to_contain_text(text))
                record('connection failure cannot sign in: '+failure,lambda:assert_counts(counts(page),sign=0,verify=0));c.close()
            for failure,text in [('sign-reject','declined'),('account-changed','changed'),('verify-error','expired')]:
                c,page=fresh();page.click('#auth-wallet-tab');page.click('#connect-button');expect(page.locator('#wallet-proof')).to_be_visible()
                mode(page,failure);page.click('#wallet-sign-in')
                record('signature failure: '+failure,lambda:expect(page.locator('#connect-status')).to_contain_text(text))
                record('signature failure leaves no session: '+failure,lambda:assert_js(page,'!window.TokenManager.isAuthenticated()'));c.close()
            c,page=fresh();page.click('#auth-wallet-tab');mode(page,'hold');page.click('#connect-button');page.click('#auth-cancel');page.evaluate('window.__authFixture.release()')
            page.wait_for_timeout(100)
            record('cancelled late wallet reply ignored',lambda:assert_counts(counts(page),challenge=0,sign=0,verify=0,tx=0))
            record('cancel returns usable controls',lambda:expect(page.locator('#connect-button')).to_be_enabled());c.close()
            c,page=fresh();page.click('#auth-wallet-tab');page.click('#connect-button');expect(page.locator('#wallet-proof')).to_be_visible()
            mode(page,'hold');page.click('#wallet-sign-in');page.click('#auth-cancel');page.evaluate('window.__authFixture.release()');page.wait_for_timeout(100)
            record('cancelled late signature not submitted',lambda:assert_counts(counts(page),verify=0,tx=0));c.close()
            for width in [320,390,768,1440]:
                c,page=fresh(width,1000)
                for tab in ['#auth-login-tab','#auth-signup-tab','#auth-wallet-tab']:
                    page.click(tab)
                    record(f'no horizontal overflow {width} {tab}',lambda:assert_js(page,'document.documentElement.scrollWidth<=window.innerWidth && [...document.querySelectorAll(".auth-modal")].every(el=>el.scrollWidth<=el.clientWidth+1)'))
                if width==390:
                    page.screenshot(path=str(out/'wallet-mobile.png'),full_page=True)
                    page.click('#connect-button');expect(page.locator('#wallet-proof')).to_be_visible();page.screenshot(path=str(out/'wallet-review-mobile.png'),full_page=True)
                c.close()
            c,page=fresh();page.focus('#auth-login-tab');page.keyboard.press('ArrowRight')
            record('keyboard mode selection',lambda:expect(page.locator('#auth-signup-tab')).to_be_focused());c.close()
            c,page=fresh(path='/password')
            page.fill('#new-password','TestPassword1!');page.fill('#confirm-password','DifferentPassword2!');page.click('#resetPasswdBtn')
            record('password mismatch before request',lambda:expect(page.locator('#password-result')).to_contain_text('do not match'))
            record('mismatch sends no request',lambda:assert_counts(counts(page),verify=0))
            page.fill('#confirm-password','TestPassword1!');page.click('#resetPasswdBtn')
            record('password completion offers sign-in, not auto-login',lambda:expect(page.locator('#password-sign-in')).to_be_visible());c.close()
            browser.close()
    finally:service.shutdown();service.server_close();thread.join(timeout=5)
    # Production wallet.js may have unrelated browser diagnostics; no runtime exceptions are accepted.
    report={'checks':checks,'passed':len(checks),'page_errors':errors,'dom_environment_simulated':args.dom_only,'scope':'Chromium; fake Sidekick and fake auth API, real production UI modules. Not OTP/Selenium/Appium/crypto.'}
    (out/'verification.json').write_text(json.dumps(report,indent=2))
    if errors:raise AssertionError(errors)
    print(json.dumps({'passed':len(checks),'page_errors':errors}))

def assert_counts(counts,**expected):
    for key,val in expected.items():assert counts[key]==val,(key,counts,expected)
def assert_js(page,expr):assert page.evaluate(expr),expr
if __name__=='__main__':main()
