"""Offline mounting adapter for browser environments where all HTTP navigation is
blocked by administrator policy. Storage, origin and reload are explicitly
simulated. UI and wallet protocol adapter modules remain production code.
Use auth_webdriver_fixture.py for real Selenium/Appium HTTP navigation instead.
"""
import base64, re
from auth_webdriver_fixture import fixture_html, STATIC, WALLET

def data(source):return 'data:text/javascript;base64,'+base64.b64encode(source.encode()).decode()
def environment(source):return 'const location=window.__fixtureLocation;const history=window.__fixtureHistory;\n'+source

def offline_html(password=False):
    page=fixture_html(password)
    env=r'''<script>
class FixtureStorage {
  getItem(k){return Object.hasOwn(this,k)?this[k]:null;} setItem(k,v){this[k]=String(v);}
  removeItem(k){delete this[k];} clear(){Object.keys(this).forEach(k=>delete this[k]);}
  key(i){return Object.keys(this)[i]||null;} get length(){return Object.keys(this).length;}
}
Object.defineProperty(window,'localStorage',{value:new FixtureStorage(),configurable:true});
Object.defineProperty(window,'sessionStorage',{value:new FixtureStorage(),configurable:true});
window.__fixtureLocation={origin:'https://auth-fixture.invalid',host:'auth-fixture.invalid',pathname:'/',hash:'',search:'',
  assign(url){window.__fixtureRedirect=url;},reload(){setTimeout(()=>{
    if(window.TokenManager?.isAuthenticated()){window.MicroModal?.close('login-modal');}
    else window.DamageAuth?.open('login');
  },0);}};
window.__fixtureHistory={replaceState(){}};
if(!crypto.randomUUID)crypto.randomUUID=()=>Array.from(crypto.getRandomValues(new Uint8Array(16)),b=>b.toString(16).padStart(2,'0')).join('');
</script>'''
    page=page.replace('<head>','<head><base href="https://auth-fixture.invalid/">'+env,1)
    # The alternate password template uses <head> too.
    page=re.sub(r'<link[^>]+href="(/static/css/[^\"]+)"[^>]*>',
        lambda m:'<style>'+(STATIC/m[1].removeprefix('/static/')).read_text()+'</style>',page)
    page=re.sub(r'<link[^>]+>', '',page)
    page=page.replace('<script src="/static/js/micromodal.min.js"></script>',
        '<script>'+(STATIC/'js/micromodal.min.js').read_text()+'</script>')
    # Mock services run inside a lexical environment, not by modifying native Location.
    page=re.sub(r'<script>(\s*// EXPLICIT TEST-ONLY.*?)</script>',lambda m:'<script>(()=>{'+environment(m[1])+'})();</script>',page,flags=re.S)
    model=data(environment((STATIC/'js/auth-model.js').read_text()))
    wallet=data(environment((STATIC/'js/wallet.js').read_text().replace('"./sidekick.js"',repr(data(WALLET)))))
    token=data(environment((STATIC/'js/wallet-switcher.js').read_text().replace("'./auth-model.js'",repr(model))))
    ui=environment((STATIC/'js/auth-ui.js').read_text().replace("'./wallet-switcher.js'",repr(token)).replace("'./wallet.js'",repr(wallet)).replace("'./auth-model.js'",repr(model)))
    password_code=environment((STATIC/'js/password-completion.js').read_text().replace("'./auth-model.js'",repr(model)))
    page=page.replace('<script type="module" src="/static/js/auth-ui.js"></script>', '<script type="module">'+ui+'</script>')
    page=page.replace('<script type="module" src="/static/js/password-completion.js"></script>', '<script type="module">'+password_code+'</script>')
    page=page.replace('src="/static/img/logo.png"','src="data:image/png;base64,'+base64.b64encode((STATIC/'img/logo.png').read_bytes()).decode()+'"')
    return page
