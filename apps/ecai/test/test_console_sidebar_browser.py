#!/usr/bin/env python3
"""DOM-only sidebar regressions with production markup, CSS and console routing.

Session, location/history, provider APIs, video/market/auth modules are mocked.
No real cookies, HTTP navigation, cloud or chain calls. Absolute ES imports are
resolved into data URLs; the console body and settings module are unchanged.
Run: python3 apps/ecai/test/test_console_sidebar_browser.py
Requires Playwright + Chromium (ECAI_CHROMIUM may override executable).
ECAI_SIDEBAR_SCREENSHOTS optionally writes PNG component previews.
"""
import base64
import json
import os
from pathlib import Path
import re
import shutil
import unittest
from urllib.parse import urlsplit
from playwright.sync_api import sync_playwright

APP = Path(__file__).resolve().parents[1]
SCREENSHOTS = os.environ.get('ECAI_SIDEBAR_SCREENSHOTS')
def data(source): return 'data:text/javascript;base64,' + base64.b64encode(source.encode()).decode()
def env(source): return 'const location=window.__navLocation;const history=window.__navHistory;\n'+source

THEME = '''
:root {--surface:#fff;--surface-2:#f5f7fb;--text:#14223d;--border:#e0e6ee;--accent:#465dec;--accent-soft:#e9edff;}
@media (prefers-color-scheme: dark) {
:root {color-scheme:dark;--canvas:#0d1521;--paper:#192636;--surface:#192636;--surface-2:#233141;--text:#e3eaf4;--ink:#e3eaf4;--muted:#a4b4ca;--line:#34475e;--border:#34475e;--navy:#192636;--accent:#a1d576;--accent-soft:#293d3c;}
.console-topbar {background:#192636;} .signed-in{color:#c1cce0;}
.console-sidebar .nav-link.is-active {background:#293d3c;box-shadow:inset 3px 0 0 #a1d576;}
.console-sidebar .nav-link:hover {background:#243445;}
.settings-workspace .button-primary{background:#a1d576;color:#122213;border-color:#a1d576;}
.console-topbar .button-outline {background:#192636;color:#e3eaf4;border-color:#34475e;}
}
'''
AUTH = '''
export const TokenManager={
 session:()=>window.__navSession,
 getToken:()=>window.__navSession?.token||'',
 getAddress:()=>window.__navSession?.address||'',
 refreshSession:async()=>window.__navSession,
 logout:()=>{window.__navSession=null;document.dispatchEvent(new Event('auth:changed'));}
};
export async function logoutActiveSession(){window.__navSession=null;window.__logoutCount++;}
'''
AUTH_UI = """export function initAuthUI(){window.DamageAuth={open:(mode)=>window.__authCalls.push(mode),status:(message)=>window.__authMessage=message};}"""
VIDEO = 'export function initVideoStudio(){return new Proxy({}, {get:()=>()=>{}});}'
MARKET = 'export function initMarketMaker(){return new Proxy({}, {get:()=>()=>{}});}'

BRIDGE = r'''
<script>
window.__navSession=SESSION;
window.__nodeAdmin=ADMIN;
window.__requests=[];window.__authCalls=[];window.__logoutCount=0;
window.__navLocation={origin:'https://ecai-fixture.invalid',hostname:'ecai-fixture.invalid',pathname:'/dashboard',hash:HASH,search:'',reload(){window.__reloadRequested=true;}};
window.__navHistory={replaceState(a,b,path){window.__navLocation.hash=new URL(path,window.__navLocation.origin).hash;}};
window.fetch=async(path,options={})=>{
 window.__requests.push({path,method:options.method||'GET',body:options.body||null});
 const route=String(path).split('?')[0];let body={ok:true};let status=200;
 if(route==='/ecai/chat') body={status:'ok'};
 else if(route==='/yelp/status') body={index_size:{docs:3}};
 else if(route==='/ecai/auth/session') body={authenticated:!!window.__navSession,public_key:window.__navSession?.address,node_admin:window.__nodeAdmin,code_admin_enabled:window.__nodeAdmin};
 else if(route==='/ecai/index-jobs/status') body={status:{running_jobs:0,queued_jobs:0,max_concurrency:2}};
 else if(route==='/ecai/index-jobs') body={ok:true,jobs:[]};
 else if(route==='/ecai/index-jobs/presets') body={ok:true,presets:[]};
 else if(route==='/ecai/compute/settings') body={ok:true,data:{budget:{monthly_cents:0,per_job_cents:0,remote_enabled:false,mint_monthly_cents:0},mint:{enabled:false,recipient:''},providers:{},reservations:[],mint_requests:[],provider_setup:{},connection_hints:{}}};
 else if(route==='/ecai/compute/eligible-sources') body={ok:true,data:[]};
 else if(route==='/ecai/admin/code/status') {if(window.__nodeAdmin) body={ok:true,status:{learning:{},reviews:{}}};else{status=403;body={error:'admin_role_required'};}}
 else if(route==='/ecai/admin/code/repairs') body={repairs:[]};
 else if(route==='/ecai/admin/code/reviews') body={reviews:[],queue:{}};
 else if(route==='/ecai/admin/code/learning/bundles') body={bundles:[]};
 else if(route==='/ecai/admin/code/settings') body={ok:true,settings:{learning:{},repository:{},review:{},sharing:{}}};
 return new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json'}});
};
window.confirm=()=>true;
if(!crypto.randomUUID)crypto.randomUUID=()=>Array.from(crypto.getRandomValues(new Uint8Array(16)),b=>b.toString(16).padStart(2,'0')).join('');
</script>
'''

def page_html(mode=None, admin=False, fragment='#account'):
    markup = (APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
    for name, file in [('compute_settings_panel','compute_settings.mustache'),('ollama_keys_panel','ollama_keys.mustache')]:
        markup = markup.replace('{{{'+name+'}}}',(APP/'priv/templates/ui/dashboard'/file).read_text())
    markup = re.sub(r'{{#has_brand_logo}}.*?{{/has_brand_logo}}','',markup,flags=re.S)
    markup = re.sub(r'{{#has_brand_favicon}}.*?{{/has_brand_favicon}}','',markup,flags=re.S)
    markup = markup.replace('{{^has_brand_logo}}','').replace('{{/has_brand_logo}}','')
    markup = markup.replace('{{brand_name}}','ECAI').replace('{{brand_tagline}}','INTELLIGENCE FABRIC').replace('{{node_version}}','v0.1')
    markup = re.sub(r'{{{[^}]+}}}', '', markup)
    def css(match):
        url = match[1]
        if url.startswith('/api/themes/css'): return '<style>'+THEME+'</style>'
        file = APP/'priv/static'/urlsplit(url).path.removeprefix('/static/')
        return '<style>'+file.read_text()+'</style>' if file.is_file() else ''
    markup = re.sub(r'<link[^>]*href="([^"]+)"[^>]*>',css,markup)
    auth_url = data(AUTH)
    dependencies = {
        '/ecai/auth-assets/js/wallet-switcher.js':auth_url,
        '/ecai/auth-assets/js/auth-ui.js':data(AUTH_UI),
        '/static/js/ecai-console-settings.js':data((APP/'priv/static/js/ecai-console-settings.js').read_text()),
        '/static/js/ecai-video.js':data(VIDEO), '/static/js/ecai-market-maker.js':data(MARKET),
    }
    def imports(source):
        def sub(match):
            url=match[2]; key=urlsplit(url).path
            if key not in dependencies: raise AssertionError('Unknown import in test fixture: '+url)
            return match[1]+json.dumps(dependencies[key])+match[3]
        return re.sub(r'(import\s+(?:[^;]*?\s+from\s+)?)["\'](/[^"\']+)["\'](;)',sub,source)
    def script(match):
        path=urlsplit(match[1]).path
        if path in ['/static/js/ecai-console.js','/static/js/ecai-compute-settings.js','/static/js/ecai-index-mint-settings.js']:
            source=(APP/'priv/static'/path.removeprefix('/static/')).read_text()
            return '<script type="module" src="'+data(env(imports(source)))+'"></script>'
        return ''
    markup = re.sub(r'<script[^>]*src="([^"]+)"[^>]*></script>',script,markup)
    session = {'mode':mode,'email':'operator@example.invalid','address':'ak_fixture_account','token':'fixture-token-0001'} if mode else None
    bridge = BRIDGE.replace('SESSION',json.dumps(session)).replace('ADMIN',json.dumps(admin)).replace('HASH',json.dumps(fragment))
    return markup.replace('<head>','<head>'+bridge,1)

class SidebarBrowser(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.p = sync_playwright().start()
        executable=os.environ.get('ECAI_CHROMIUM') or shutil.which('chromium') or shutil.which('chromium-browser')
        cls.browser=cls.p.chromium.launch(**({'executable_path':executable} if executable else {}),args=['--no-sandbox','--disable-dev-shm-usage'])
    @classmethod
    def tearDownClass(cls): cls.browser.close();cls.p.stop()
    def setUp(self): self.contexts=[];self.errors=[]
    def tearDown(self):
        for c in self.contexts:c.close()
        self.assertEqual(self.errors,[])
    def page(self,mode=None,admin=False,fragment='#account',width=1440,height=1050,scheme='dark'):
        context=self.browser.new_context(viewport={'width':width,'height':height},color_scheme=scheme)
        self.contexts.append(context)
        context.route('**/*',lambda route:route.abort())
        page=context.new_page();page.on('pageerror',lambda error:self.errors.append(str(error)))
        page.set_content(page_html(mode,admin,fragment))
        page.wait_for_function("window.EcaiConsoleSettings?.assetVersion === 'sidebar-settings-v1'")
        page.wait_for_function("document.querySelector('#sidebarNodeState').textContent !== 'Node not checked'")
        return page
    def nav(self,page,view):
        if page.viewport_size['width']<=800:page.locator('#openNav').click()
        page.locator('#consoleNav [data-view="'+view+'"]').click()
        page.wait_for_function("v=>window.__navLocation.hash==='#'+v",arg=view)
    def test_structure_footer_and_single_status(self):
        page=self.page()
        self.assertEqual(page.locator('#consoleSidebar .node-dot').count(),1)
        self.assertEqual(page.locator('#topbarRuntime').count(),0)
        self.assertEqual(page.locator('#consoleSidebar .brand-symbol span').count(),0)
        self.assertEqual(page.locator('#consoleSidebar a[href="/chat"]').count(),0)
        self.assertFalse(page.locator('#sidebarMoreTools').evaluate('el=>el.open'))
        self.assertTrue(page.locator('.sidebar-bottom [data-view="compute"]').is_visible())
        self.assertEqual(page.locator('#sidebarNodeState').text_content(),'ECAI responding')
        self.assertTrue(page.locator('#sidebarStatusDot').evaluate("el=>el.classList.contains('online')"))
    def test_account_guest_auth_actions_reuse_handlers(self):
        page=self.page()
        for id_,mode in [('accountSettingsLogin','login'),('accountSettingsCreate','signup'),('accountSettingsWallet','wallet')]:
            page.locator('#'+id_).click()
            self.assertEqual(page.evaluate('window.__authCalls.at(-1)'),mode)
        self.assertTrue(page.locator('[data-settings-go="keys"]').is_disabled())
        self.assertEqual(page.locator('#accountSettingsSwitch').is_visible(),False)
    def test_settings_routes_and_compute_are_not_lost(self):
        page=self.page(mode='custodial')
        self.nav(page,'compute')
        self.assertTrue(page.locator('#computePanel').is_visible())
        self.assertEqual(page.locator('#viewBreadcrumb').text_content(),'Compute')
        self.nav(page,'node-settings')
        self.assertTrue(page.locator('#nodeSettingsTitle').is_visible())
        page.locator('[data-settings-go="api"]').click()
        self.assertTrue(page.locator('#sidebarMoreTools').evaluate('el=>el.open'))
        self.assertEqual(page.locator('[data-view="api"]').get_attribute('aria-current'),'page')
        self.assertEqual(page.locator('#consoleNav [aria-current="page"]').count(),1)
    def test_deep_link_reveals_more_tools_and_retains_route(self):
        page=self.page(fragment='#api')
        self.assertTrue(page.locator('#sidebarMoreTools').evaluate('el=>el.open'))
        self.assertEqual(page.evaluate('window.__navLocation.hash'),'#api')
        self.assertTrue(page.locator('#apiTitle').is_visible())
    def test_wallet_and_guest_do_not_get_admin_controls(self):
        for mode in [None,'wallet','custodial']:
            page=self.page(mode=mode,fragment='#node-settings')
            self.assertTrue(page.locator('#nodeSettingsCode').is_hidden())
            self.assertTrue(page.locator('#nodeSettingsOperations').is_hidden())
            self.assertTrue(page.locator('#nodeSettingsRestricted').is_visible())
            self.assertFalse(page.evaluate("window.__requests.some(r=>r.path.startsWith('/ecai/admin/'))"))
            self.assertFalse(page.evaluate("window.__requests.some(r=>r.method!=='GET')"))
    def test_admin_launches_existing_settings_without_saving(self):
        page=self.page(mode='custodial',admin=True,fragment='#node-settings')
        page.wait_for_function("!document.querySelector('#nodeSettingsCode').hidden")
        page.locator('[data-settings-action="code-settings"]').click()
        self.assertEqual(page.evaluate('window.__navLocation.hash'),'#code')
        self.assertTrue(page.locator('#codeSettingsPanel').evaluate('el=>el.open'))
        self.assertFalse(page.evaluate("window.__requests.some(r=>r.method!=='GET')"))
    def test_account_switch_clears_previous_identity_and_admin(self):
        page=self.page(mode='custodial',admin=True,fragment='#account')
        page.wait_for_function("document.querySelector('#accountSettingsIdentity').textContent==='operator@example.invalid'")
        page.evaluate("window.__navSession={mode:'wallet',address:'ak_other',token:'fixture-wallet-0002'};window.__nodeAdmin=false;document.dispatchEvent(new Event('auth:changed'))")
        self.assertEqual(page.locator('#accountSettingsIdentity').text_content(),'ak_other')
        self.assertEqual(page.locator('#accountSettingsMode').text_content(),'Wallet session')
        self.assertTrue(page.locator('#nodeSettingsCode').is_hidden())
        page.evaluate("window.__navSession=null;document.dispatchEvent(new Event('auth:changed'))")
        self.assertEqual(page.locator('#accountSettingsIdentity').text_content(),'Guest access')
        self.assertNotIn('ak_other',page.locator('[data-panel="account"]').text_content())
    def test_mint_preferences_still_open_in_index_jobs(self):
        page=self.page(mode='custodial')
        page.locator('[data-settings-action="mint"]').click()
        self.assertEqual(page.evaluate('window.__navLocation.hash'),'#indexing')
        self.assertTrue(page.locator('#indexMintSettings').is_visible())
        self.assertTrue(page.locator('#indexMintSettings').evaluate('el=>el.open'))
        self.assertFalse(page.evaluate("window.__requests.some(r=>r.method!=='GET')"))
    def test_mobile_keyboard_drawer_and_escape(self):
        page=self.page(width=390,height=844)
        self.assertTrue(page.locator('#consoleSidebar').evaluate('el=>el.inert'))
        page.locator('#openNav').click()
        self.assertEqual(page.locator('#openNav').get_attribute('aria-expanded'),'true')
        self.assertTrue(page.locator('.console-body').evaluate('el=>el.inert'))
        page.locator('#closeNav').focus();page.keyboard.press('Shift+Tab')
        self.assertTrue(page.locator('.node-mark').evaluate('el=>el===document.activeElement'))
        page.keyboard.press('Tab')
        self.assertTrue(page.locator('#closeNav').evaluate('el=>el===document.activeElement'))
        page.keyboard.press('Escape')
        self.assertEqual(page.locator('#openNav').get_attribute('aria-expanded'),'false')
        self.assertFalse(page.locator('.console-body').evaluate('el=>el.inert'))
        self.nav(page,'node-settings')
        self.assertTrue(page.locator('#nodeSettingsTitle').is_visible())
    def test_footer_visible_desktop_and_short_landscape_reachable(self):
        page=self.page(height=768)
        footer=page.locator('.node-mark').bounding_box();self.assertLessEqual(footer['y']+footer['height'],768)
        page.locator('#sidebarMoreTools summary').click()
        page.locator('.sidebar-workspace').evaluate('el=>el.scrollTop=el.scrollHeight')
        footer2=page.locator('.node-mark').bounding_box();self.assertAlmostEqual(footer2['y'],footer['y'],delta=1)
        short=self.page(width=740,height=360)
        short.locator('#openNav').click()
        short.locator('#consoleNav').evaluate('el=>el.scrollTop=el.scrollHeight')
        self.assertTrue(short.locator('.node-mark').is_visible())
        footer=short.locator('.node-mark').bounding_box();self.assertLessEqual(footer['y']+footer['height'],360)
    def test_navigation_resets_scroll_and_focus_not_refresh(self):
        page=self.page(fragment='#compute')
        page.evaluate('window.scrollTo(0,600)')
        self.nav(page,'account')
        page.wait_for_function("document.activeElement.id==='accountSettingsTitle'")
        self.assertLessEqual(page.evaluate('window.scrollY'),2)
        page.locator('#refreshView').focus();page.locator('#refreshView').click()
        self.assertTrue(page.locator('#refreshView').evaluate('el=>el===document.activeElement'))
    def test_light_dark_responsive_and_screenshots(self):
        for scheme in ['dark','light']:
            for width in [1440,958,390,320]:
                page=self.page(mode='custodial',width=width,scheme=scheme,height=1000)
                self.assertLessEqual(page.evaluate('document.documentElement.scrollWidth'),width+1)
                if width<800:page.locator('#openNav').click()
                self.assertLessEqual(page.locator('.node-mark').bounding_box()['x']+page.locator('.node-mark').bounding_box()['width'],max(width,244))
                if SCREENSHOTS:
                    target=Path(SCREENSHOTS);target.mkdir(parents=True,exist_ok=True)
                    page.wait_for_timeout(350)  # settle the production drawer/view animation
                    page.screenshot(path=str(target/f'ecai-sidebar-{scheme}-{width}.png'))

if __name__=='__main__':unittest.main(verbosity=2)
