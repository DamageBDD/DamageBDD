#!/usr/bin/env python3
"""Loopback auth UI fixture: production templates/CSS/JS; FAKE wallet and API.

No wallet extension, chain connection, email or credential service is used.
This is not installed in priv/ or on the production HTTP router. Standard-library
server shared by managed ChromeDriver, Selenium Grid, Appium and DOM cross-checks.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
import argparse
from bdd_composer_browser_test import render_template
APP = Path(__file__).resolve().parents[2]
STATIC = APP / 'priv/static'

FAKE = r'''
// EXPLICIT TEST-ONLY SERVICE AND WALLET. Never copied into production assets.
window.__authFixture = {mode:'ok', counts:{login:0,signup:0,recovery:0,connect:0,sign:0,verify:0,challenge:0,tx:0}, waits:[],
  release(){this.mode='ok';this.waits.splice(0).forEach(resolve => resolve());},
  async wait(){if (this.mode === 'hold') await new Promise(resolve => this.waits.push(resolve));},
  count(key){this.counts[key]++;sessionStorage.setItem('auth_fixture_counts',JSON.stringify(this.counts)); const el=document.getElementById('fixture-count-'+key);if(el){el.textContent=String(this.counts[key]);el.fixtureCount=this.counts[key];}}};
document.addEventListener('submit',event=>{if(event.target.id==='fixture-transfer'){event.preventDefault();window.__authFixture.count('tx');}});
document.addEventListener('auth:changed',event=>{const el=document.getElementById('auth-fixture-dashboard');if(el){el.hidden=!event.detail?.authenticated;const label=document.getElementById('fixture-session-kind');label.textContent=event.detail?.mode||'';}});
document.addEventListener('DOMContentLoaded',()=>{for(const[k,v]of Object.entries(window.__authFixture.counts)){const el=document.getElementById('fixture-count-'+k);if(el){el.textContent=String(v);el.fixtureCount=v;}}});
const F = window.__authFixture;
try{Object.assign(F.counts,JSON.parse(sessionStorage.getItem('auth_fixture_counts')||'{}'));}catch(_){}
const ADDRESS='ak_2a9NeTAfBwLn87TT77raYc6MKmwsZApa3PBLMTwkvcCHkaGpHE';
const TOKEN='ds1.'+'a'.repeat(64);
const capabilities = mode => ({author_features:true,generate_bdd:true,validate_bdd:true,read_balances:true,receive_tokens:true,
  execute:mode==='custodial',transfer:mode==='custodial',schedules:mode==='custodial',account_context:mode==='custodial',nwc:mode==='custodial',billing:mode==='custodial',
  reason:'Wallet-only payments and managed signing are unavailable. No private key is loaded.'});
const session = mode => ({authenticated:true,status:'ok',mode,address:ADDRESS,access_token:TOKEN,expires_at:Math.floor(Date.now()/1000)+3600,capabilities:capabilities(mode)});
const save = mode => {const s=session(mode); sessionStorage.setItem('auth_fixture_session',JSON.stringify(s));return s;};
window.__fixtureAddress=ADDRESS;
window.__fixtureSession=session;
window.fetch=async(url,opts={})=>{
  const path=new URL(url,location.origin).pathname, data=JSON.parse(opts.body||'{}');
  const response=(value,status=200)=>new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json'}});
  const run = async kind => {F.count(kind);await F.wait();if(opts.signal?.aborted)throw new DOMException('Aborted','AbortError');};
  if(path==='/accounts/auth/options')return response({origin:location.origin,network_id:'ae_mainnet'});
  if(path==='/accounts/session'){const saved=JSON.parse(sessionStorage.getItem('auth_fixture_session')||'null');return response(saved||{authenticated:false},saved?200:401);}
  if(path==='/accounts/login'){
    await run('login');
    if(F.mode==='invalid'||data.username.endsWith('@example.invalid'))return response({message:'Email or password is incorrect.'},401);
    if(F.mode==='unavailable')return response({message:'Authentication is unavailable.'},503);
    if(F.mode==='html-error')return response({message:'<img src=x onerror=window.pwned=true>'},400);
    if(F.mode==='malformed')return response({address:ADDRESS});
    return response(save('custodial'));
  }
  if(path==='/accounts/signup'){await run('signup');return response({status:'ok',message:'Confirmation requested. Check your inbox.'},201);}
  if(path==='/accounts/recovery'){await run('recovery');return response({status:'ok',message:'Reset link requested.'});}
  if(path==='/accounts/wallet/challenge'){
    await run('challenge');return response({status:'ok',address:ADDRESS,network_id:'ae_mainnet',challenge_id:'b'.repeat(64),expires_at:Math.floor(Date.now()/1000)+180,
      message:'Sign in to DamageBDD\n\nOrigin: '+location.origin+'\nAccount: '+ADDRESS+'\nNetwork: ae_mainnet\nNonce: FIXTURE\n\nThis proves wallet ownership for a browser session only.\nIt does not authorise payments, token transfers, channels, or custody of your keys.'});
  }
  if(path==='/accounts/wallet/verify'){await run('verify');if(F.mode==='verify-error')return response({message:'This sign-in request expired or was already used. Connect again.'},401);return response(save('wallet'));}
  if(path==='/accounts/session/logout'){if(F.mode==='logout-error')return response({error:'unavailable'},503);sessionStorage.removeItem('auth_fixture_session');return response({status:'ok'});}
  if(path==='/accounts/confirm'||path==='/accounts/reset_password'){
    await run('verify');if(F.mode==='invalid')return response({message:'This confirmation link is invalid or expired.'},400);return response({status:'ok'});
  }
  if(path==='/accounts/balance')return response({damage_display:'20',ae_display:'0.2',sats_available:false});
  F.count('tx');throw Error('Unexpected network request to '+path);
};
'''
WALLET = r'''
// Test Sidekick transport only; production wallet.js and auth-ui.js remain unchanged.
export const TIMEOUT_DEF_CONNECT_MS=30000;
export async function detect(){return {ok:true,result:{networkId:'ae_mainnet'}};}
export async function connect(){window.__authFixture.count('connect');await window.__authFixture.wait();
 if(window.__authFixture.mode==='connect-reject')return {ok:false};
 return {ok:true,result:{networkId:window.__authFixture.mode==='wrong-network'?'ae_uat':'ae_mainnet'}};}
export async function address(){return {ok:true,result:{address:{current:{[window.__authFixture.mode==='account-changed'?'ak_wrong':window.__fixtureAddress]:{}}}}};}
export async function msg_sign(_id,_address,_message){window.__authFixture.count('sign');await window.__authFixture.wait();
 if(window.__authFixture.mode==='sign-reject')return {ok:false};return {ok:true,result:{signature:'a'.repeat(128)}};}
'''

def fixture_html(password=False):
    if password:
        page = render_template((APP/'priv/templates/reset_password.mustache').read_text(),
            {'action':'confirm','action_label':'Set','token':'fixture-not-a-real-token'})
        return page.replace('</head>', '<script>'+FAKE+'</script></head>')
    modal = render_template((APP/'priv/templates/ui/dashboard/auth_modal.mustache').read_text(),
        {'logo_image':'/static/img/logo.png'})
    return '''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>DamageBDD auth — simulated wallet and services</title><link rel="stylesheet" href="/static/css/main.css">
    <link rel="stylesheet" href="/static/css/auth.css"><style>body{background:#0c1015;margin:0}.fixture-label{position:fixed;z-index:100000;top:4px;left:12px;color:#aaa;font:10px system-ui;pointer-events:none}
    #fixture-controls{position:fixed;bottom:0;left:0;z-index:99999;background:#eee;padding:5px;font:10px system-ui;display:none}</style>
    <script src="/static/js/micromodal.min.js"></script><script>'''+FAKE+'''</script>
    <script type="module" src="/static/js/auth-ui.js"></script></head><body class="damage-dashboard">
    <div class="fixture-label">UI FIXTURE · Simulated wallet, authentication and email</div>'''+modal+'''
    <section id="auth-fixture-dashboard" hidden><h1>Authenticated UI fixture</h1><p id="fixture-session-kind"></p><p data-session-feedback role="status"></p><p data-session-kind></p><p data-session-address></p><p data-wallet-only-note hidden></p><button id="fixture-switch" data-switch-account>Switch account</button><button id="fixture-disconnect" data-disconnect-wallet>Disconnect and sign out</button><form id="fixture-transfer" data-requires-capability="transfer"><button id="fixture-pay" data-requires-capability="transfer">Transfer</button></form></section>
    <div id="fixture-controls" hidden>'''+''.join(f'<span id="fixture-count-{k}">0</span>' for k in ['login','signup','recovery','connect','sign','verify','challenge','tx'])+'''</div>
    </body></html>'''

def server(bind='127.0.0.1',port=8766):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path=urlsplit(self.path).path
            if path in ('/','/password'):
                body=fixture_html(path=='/password').encode();typ='text/html; charset=utf-8'
            elif path=='/health':body=b'{"fixture":true,"ready":true}';typ='application/json'
            elif path=='/static/js/sidekick.js':body=WALLET.encode();typ='text/javascript'
            elif path.startswith('/static/'):
                local=(STATIC/path.removeprefix('/static/')).resolve()
                if not local.is_relative_to(STATIC.resolve()) or not local.is_file():self.send_error(404);return
                if local.suffix not in ('.css','.js','.png','.ico'):self.send_error(404);return
                body=local.read_bytes();typ={'.css':'text/css','.js':'text/javascript','.png':'image/png','.ico':'image/x-icon'}[local.suffix]
            else:self.send_error(404);return
            self.send_response(200);self.send_header('Content-Type',typ);self.send_header('Content-Length',str(len(body)))
            self.send_header('Cache-Control','no-store');self.send_header('Referrer-Policy','no-referrer');self.end_headers();self.wfile.write(body)
        def log_message(self,*_):pass
    return ThreadingHTTPServer((bind,port),Handler)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--bind',default='127.0.0.1');p.add_argument('--port',type=int,default=8766)
    args=p.parse_args();s=server(args.bind,args.port)
    print(f'Auth fixture on {args.bind}:{s.server_address[1]} — NO real wallet or API',flush=True)
    try:s.serve_forever()
    except KeyboardInterrupt:pass
    finally:s.server_close()
