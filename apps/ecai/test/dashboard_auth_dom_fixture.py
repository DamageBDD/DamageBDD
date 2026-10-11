"""DOM-only adapter for hosts whose Chromium policy blocks all HTTP navigation.

Uses production sources. Location, storage, requests, cookies, wallet transport
and reload are explicitly simulated; this is NOT HTTP/Cowboy/cookie validation.
"""
import base64
import html
import json
import re
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import urlsplit
APP=Path(__file__).resolve().parents[1]
DAMAGE=APP.parent/'damage'
def data(source):return 'data:text/javascript;base64,'+base64.b64encode(source.encode()).decode()
def env(source):return 'const location=window.__fixtureLocation;const history=window.__fixtureHistory;\n'+source

def offline_html(markup, wallet, wallet_missing=False, storage=None, fragment=''):
    environment='''<script>
class FixtureStorage {
  constructor(initial={}){Object.assign(this,initial);}
  getItem(k){return Object.hasOwn(this,k)?this[k]:null;}setItem(k,v){this[k]=String(v);}
  removeItem(k){delete this[k];}clear(){Object.keys(this).forEach(k=>delete this[k]);}
}
Object.defineProperty(window,'localStorage',{value:new FixtureStorage(),configurable:true});
Object.defineProperty(window,'sessionStorage',{value:new FixtureStorage(STORAGE),configurable:true});
window.__fixtureLocation={origin:'https://ecai-auth.test',host:'ecai-auth.test',pathname:'/dashboard',hash:FRAGMENT,search:'',
  assign(url){window.__fixtureRedirect=url;},reload(){window.__requestedReload=true;}};
window.__fixtureHistory={replaceState(a,b,url){const u=new URL(url,window.__fixtureLocation.origin);
  window.__fixtureLocation.pathname=u.pathname;window.__fixtureLocation.hash=u.hash;}};
window.fetch=async(url,opts={})=>{const r=await window.__authMockRequest(String(url),{
  method:opts.method||'GET',headers:opts.headers||{},body:opts.body||''});
  if(opts.signal?.aborted)throw new DOMException('Aborted','AbortError');
  return new Response(r.body,{status:r.status,headers:r.headers});};
if(!crypto.randomUUID)crypto.randomUUID=()=>Array.from(crypto.getRandomValues(new Uint8Array(16)),b=>b.toString(16).padStart(2,'0')).join('');
window.confirm=()=>true;
</script>'''.replace('STORAGE',json.dumps(storage or {})).replace('FRAGMENT',json.dumps(fragment))
    markup=markup.replace('<head>','<head>'+environment)
    def stylesheet(m):
        path=urlsplit(m[1]).path
        file=DAMAGE/'priv/static'/path.removeprefix('/ecai/auth-assets/') if path.startswith('/ecai/auth-assets/') else APP/'priv/static'/path.removeprefix('/static/')
        return '<style>'+file.read_text()+'</style>'
    markup=re.sub(r'<link[^>]+href="([^"]+)"[^>]*>',stylesheet,markup)
    markup=markup.replace('src="/static/img/ecai-brain.svg"','src="data:image/svg+xml;base64,'+base64.b64encode((APP/'priv/static/img/ecai-brain.svg').read_bytes()).decode()+'"')
    model=data(env((DAMAGE/'priv/static/js/auth-model.js').read_text()))
    walletcode='export const legacy=true;' if wallet_missing else (DAMAGE/'priv/static/js/wallet.js').read_text().replace('"./sidekick.js"',repr(data(wallet)))
    walleturl=data(env(walletcode))
    loader=(DAMAGE/'priv/static/js/auth-wallet-loader.js').read_text()
    loader,n=re.subn(r"(['\"])\./wallet\.js\?v=[a-f0-9]+\1",lambda _:repr(walleturl),loader);assert n==1
    loaderurl=data(env(loader))
    token=data(env((DAMAGE/'priv/static/js/wallet-switcher.js').read_text().replace("'./auth-model.js'",repr(model))))
    ui=data(env((DAMAGE/'priv/static/js/auth-ui.js').read_text().replace("'./wallet-switcher.js'",repr(token)).replace("'./auth-wallet-loader.js'",repr(loaderurl)).replace("'./auth-model.js'",repr(model))))
    console=(APP/'priv/static/js/ecai-console.js').read_text().replace('"/ecai/auth-assets/js/wallet-switcher.js"',repr(token)).replace('"/ecai/auth-assets/js/auth-ui.js?v=ecai-browser-v1"',repr(ui))
    def script(m):
        path=urlsplit(m[1]).path
        if path=='/ecai/auth-assets/js/micromodal.min.js':return '<script>'+(DAMAGE/'priv/static/js/micromodal.min.js').read_text()+'</script>'
        if path=='/static/js/ecai-console.js':return '<script type="module">'+env(console)+'</script>'
        if path=='/static/js/ecai-index-pool.js':return '<script type="module">'+env((APP/'priv/static/js/ecai-index-pool.js').read_text())+'</script>'
        raise ValueError(path)
    markup=re.sub(r'<script[^>]+src="([^"]+)"[^>]*></script>',script,markup)
    return markup

async def install_transport(context,backend):
    backend.fixture_cookie=''
    async def request(source,url,opts):
        path=urlsplit(url).path
        headers={k.lower():v for k,v in opts['headers'].items()}
        headers['cookie']=backend.fixture_cookie
        if opts['method']=='POST':headers['origin']='https://ecai-auth.test'
        req=SimpleNamespace(url='https://ecai-auth.test'+path+'?'+urlsplit(url).query,
            method=opts['method'],headers=headers,post_data=opts['body'],
            post_data_json=json.loads(opts['body']) if opts['body'] else None)
        class Route:
            def __init__(self):self.request=req;self.result=None
            async def fulfill(self,status=200,body=None,headers=None,content_type=None,json=None):
                import json as jsonlib
                h=headers or {'content-type':content_type or 'application/json'}
                if 'set-cookie' in h:
                    backend.fixture_cookie=h['set-cookie'].split(';')[0]
                self.result={'status':status,'body':body if body is not None else jsonlib.dumps(json),'headers':h}
            async def abort(self):raise RuntimeError('Unexpected external request in DOM fixture')
        route=Route();await backend.route(route);return route.result
    await context.expose_binding('__authMockRequest',request)


# Existing feature regressions use this in-place reload simulation. The dedicated
# dashboard-auth suite remounts the document instead to exercise session restore.
IN_PLACE_RELOAD = """
window.__fixtureLocation.reload=()=>{
  window.MicroModal?.close('login-modal');
  document.getElementById('refreshHealth').click();
  document.getElementById('refreshView').click();
};
"""

def business_fixture_html(markup, mock_script='', storage=None, fragment=''):
    rendered = offline_html(markup, 'export const unused=true;', storage=storage, fragment=fragment)
    return rendered.replace('</script>', '</script><script>'+mock_script+'\n'+IN_PLACE_RELOAD+'</script>', 1)
