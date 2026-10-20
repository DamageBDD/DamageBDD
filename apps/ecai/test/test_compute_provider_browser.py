#!/usr/bin/env python3
"""HTTP-loaded compute UI regressions, with no live cloud/account operations.

Uses the production console shell, all bundled dashboard styles and the actual
compute controller loaded from the URLs in the shell (not inlined preview CSS).
A loopback server mocks compute JSON APIs. Other dashboard controllers and the
external DamageBDD auth assets are stubbed; this is NOT a Cowboy/auth/cloud test.

Run: python3 apps/ecai/test/test_compute_provider_browser.py
Requires Playwright and Chromium. ECAI_CHROMIUM may select the browser executable.
ECAI_COMPUTE_SCREENSHOTS optionally saves light/dark desktop/mobile screenshots.

--dom-only uses a URL-aware offline adapter where browser network navigation is
unavailable: Python resolves each unchanged source URL against the same fixture
server, then embeds the response as a data URL. APIs use a Python binding. This
still exercises asset selection, real CSS/controller bytes and failure modes,
but does not validate browser HTTP caching, response headers or module transport.
"""
from __future__ import annotations

import base64
import json
import mimetypes
import os
import re
import shutil
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, urlopen
from urllib.error import HTTPError

from playwright.sync_api import sync_playwright

APP = Path(__file__).resolve().parents[1]
SHELL = (APP / 'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
FRAGMENT = (APP / 'priv/templates/ui/dashboard/compute_settings.mustache').read_text()
VERSION = re.search(r'data-compute-ui-version="([^"]+)"', FRAGMENT)[1]
DOM_ONLY = '--dom-only' in sys.argv
if DOM_ONLY:
    sys.argv.remove('--dom-only')
EXTERNAL_ID = 'a' * 48
PRINCIPAL = 'arn:aws:iam::210987654321:role/EcaiCoordinator'

# Simulate an old static deployment. Unversioned requests ALWAYS receive these;
# tests must fetch the versioned production assets instead. Fault modes also
# return these bytes for versioned requests to simulate a stale build/proxy.
LEGACY_CSS = '.compute-tabs button {border:1px solid #dae2eb;color:inherit}'
LEGACY_JS = """window.EcaiComputeSettings={init(){},async refresh(){
 document.getElementById('computeAwsExternalId').textContent='Generated when connection is saved';
}};"""
BOOTSTRAP = """// Test-only hooks: no real authentication or provider operations.
const panel=document.querySelector('[data-panel="compute"]');
for(const view of document.querySelectorAll('[data-panel]')){
 view.hidden=view!==panel; view.classList.toggle('is-visible', view===panel);
}
for(const item of document.querySelectorAll('#consoleNav [data-view]')){
 const selected=item.dataset.view==='compute';
 item.classList.toggle('is-active',selected);
 if(selected)item.setAttribute('aria-current','page');else item.removeAttribute('aria-current');
}
const crumb=document.querySelector('.breadcrumb strong');if(crumb)crumb.textContent='Compute & NFTs';
window.__signedIn=true;window.__loginRequests=0;window.__toasts=[];
if(window.EcaiComputeSettings){
 window.EcaiComputeSettings.init({
  request:async(path,opts={})=>{
   const response=await fetch(path,{method:opts.method||'GET',
    headers:{'Content-Type':'application/json','Authorization':'Bearer browser-test-token'},
    body:opts.body===undefined?undefined:JSON.stringify(opts.body)});
   const body=await response.json();
   if(!response.ok)throw Object.assign(new Error('Mock API failure'),{status:response.status,body});
   return body;
  },toast:(message,error)=>window.__toasts.push({message,error}),
  openLogin:()=>window.__loginRequests++,currentToken:()=>window.__signedIn?'test-token':''
 });
 await window.EcaiComputeSettings.refresh();
}
window.__computeFixtureReady=true;
"""


def fixture_html() -> str:
    """Leave stylesheet and script URLs intact, including their query versions."""
    markup = SHELL.replace('{{{compute_settings_panel}}}', FRAGMENT)
    markup = re.sub(r'{{{\s*\w+\s*}}}|{{\s*[^{}]+\s*}}', '', markup)
    return markup.replace('</body>', '<script type="module" src="/__test_bootstrap.js"></script></body>')


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, body, content_type='text/plain', status=200):
        if isinstance(body, str):
            body = body.encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        # Persistent stale assets mimic what an unversioned URL could encounter.
        cache = 'public, max-age=86400' if self.path.startswith('/static/') else 'no-store'
        self.send_header('Cache-Control', cache)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlsplit(self.path)
        path = url.path
        self.server.requests.append(('GET', self.path))
        if path == '/dashboard':
            return self.reply(fixture_html(), 'text/html; charset=utf-8')
        if path == '/__test_bootstrap.js':
            return self.reply(BOOTSTRAP, 'text/javascript')
        if path.startswith('/ecai/compute/'):
            if path == '/ecai/compute/settings':
                data = self.server.settings
            elif path in ('/ecai/compute/mintable', '/ecai/compute/eligible-sources'):
                data = []
            else:
                return self.reply('{"error":"unexpected_test_route"}', 'application/json', 404)
            return self.reply(json.dumps({'ok': True, 'data': data}), 'application/json')
        if path.startswith('/ecai/auth-assets/'):
            # Shared auth lives in apps/damage, not in this source archive.
            return self.reply('/* Shared auth stub; test-only. */',
                              'text/css' if path.endswith('.css') else 'text/javascript')
        if path.startswith('/static/'):
            file = (APP / 'priv/static' / path.removeprefix('/static/')).resolve()
            if not file.is_relative_to((APP / 'priv/static').resolve()) or not file.is_file():
                return self.reply('Not found', status=404)
            if file.name.startswith('ecai-compute-settings.'):
                ext = file.suffix.removeprefix('.')
                versioned = parse_qs(url.query).get('v') == [VERSION]
                mode = self.server.asset_mode
                if mode == 'missing_' + ext:
                    return self.reply('Simulated missing asset', status=404)
                if not versioned or mode == 'stale_' + ext:
                    return self.reply(LEGACY_CSS if ext == 'css' else LEGACY_JS,
                                      'text/css' if ext == 'css' else 'text/javascript')
            elif file.suffix == '.js':
                # The production compute controller is real; unrelated features
                # do not boot or contact their backends in this fixture.
                return self.reply('// Unrelated controller stub.', 'text/javascript')
            return self.reply(file.read_bytes(), mimetypes.guess_type(file)[0] or 'application/octet-stream')
        return self.reply('Not found', status=404)

    def do_POST(self):
        path = urlsplit(self.path).path
        self.server.requests.append(('POST', path))
        if self.headers.get('Authorization') != 'Bearer browser-test-token':
            return self.reply('{"error":"unauthorized"}', 'application/json', 401)
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        self.server.posts.append((path, body))
        if self.server.fail_next_post:
            self.server.fail_next_post = False
            return self.reply('{"error":"simulated_provider_failure"}', 'application/json', 503)
        settings = self.server.settings
        if path == '/ecai/compute/providers/aws_batch/prepare':
            settings['provider_setup']['aws_batch_external_id'] = EXTERNAL_ID
            result = {'external_id': EXTERNAL_ID}
        elif path in ('/ecai/compute/providers/aws_batch', '/ecai/compute/providers/cloud_run'):
            provider = path.rsplit('/', 1)[-1]
            result = {**body, 'status': 'unverified'}
            if provider == 'aws_batch':
                result['external_id'] = EXTERNAL_ID
            settings['providers'][provider] = result
        elif path in ('/ecai/compute/providers/aws_batch/verify', '/ecai/compute/providers/cloud_run/verify'):
            provider = path.split('/')[-2]
            result = settings['providers'][provider]
            result['status'] = 'identity_verified'
        else:
            return self.reply('{"error":"unexpected_test_write"}', 'application/json', 400)
        return self.reply(json.dumps({'ok': True, 'data': result}), 'application/json')


# Effective ancestor background is needed for transparent spans, labels/code.
CONTRAST = """selector=>{
 const el=document.querySelector(selector),s=getComputedStyle(el);
 const rgb=str=>str.match(/[\\d.]+/g).map(Number);
 let node=el,bg=[255,255,255];
 while(node){const c=rgb(getComputedStyle(node).backgroundColor);
  if(c.length===3 || c[3]===1){bg=c;break;} node=node.parentElement;}
 const luminance=c=>c.slice(0,3).map(x=>x/255).map(x=>x<=.04045?x/12.92:((x+.055)/1.055)**2.4)
  .reduce((a,x,i)=>a+x*[.2126,.7152,.0722][i],0);
 const a=luminance(rgb(s.color)),b=luminance(bg);
 return {ratio:(Math.max(a,b)+.05)/(Math.min(a,b)+.05),color:s.color,background:bg};
}"""


class ComputeBrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.origin = f'http://127.0.0.1:{cls.server.server_port}'
        cls.playwright = sync_playwright().start()
        executable = os.environ.get('ECAI_CHROMIUM') or shutil.which('chromium') or shutil.which('chromium-browser')
        cls.browser = cls.playwright.chromium.launch(
            **({'executable_path': executable} if executable else {}),
            args=['--no-sandbox', '--disable-dev-shm-usage'])

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def setUp(self):
        self.server.asset_mode = 'current'
        self.server.requests = []
        self.server.posts = []
        self.server.fail_next_post = False
        self.server.settings = {
            'providers': {}, 'provider_setup': {}, 'connection_hints': {},
            'budget': {'monthly_cents': 0, 'per_job_cents': 0, 'mint_monthly_cents': 0, 'remote_enabled': False},
            'mint': {'enabled': False, 'recipient': ''}, 'reservations': [], 'mint_requests': [],
        }
        self.contexts = []
        self.errors = []

    def tearDown(self):
        for context in self.contexts:
            context.close()
        self.assertEqual(self.errors, [], 'Unexpected JavaScript exceptions')

    def mock_request(self, path, options=None):
        options = options or {}
        if not path.startswith('/') or path.startswith('//'):
            raise ValueError('Only same-origin fixture paths are permitted')
        request = Request(self.origin + path,
                          data=options.get('body', '').encode() if options.get('body') else None,
                          headers=options.get('headers', {}), method=options.get('method', 'GET'))
        try:
            response = urlopen(request, timeout=5)
        except HTTPError as error:
            response = error
        with response:
            return {'status': response.status, 'body': response.read().decode('utf-8'),
                    'headers': {'content-type': response.headers.get_content_type()}}

    def offline_html(self):
        markup = self.mock_request('/dashboard')['body']
        def resource(match):
            attribute, url = match[1], match[2]
            # External console links are ordinary anchors and are not rewritten.
            result = self.mock_request(url)
            body = result['body'] if result['status'] == 200 else '/* Missing asset fixture */'
            mime = result['headers']['content-type'] if result['status'] == 200 else (
                'text/css' if urlsplit(url).path.endswith('.css') else 'text/javascript')
            encoded = base64.b64encode(body.encode()).decode()
            return attribute + '="data:' + mime + ';base64,' + encoded + '"'
        markup = re.sub(r'(href|src)="(/(?:static|ecai/auth-assets)/[^"]+|/__test_bootstrap.js)"', resource, markup)
        bridge = """<script>
        window.fetch=async(path,opts={})=>{
          const result=await window.__computeRequest(String(path),opts);
          return new Response(result.body,{status:result.status,headers:result.headers});
        };
        </script>"""
        return markup.replace('<head>', '<head>' + bridge, 1)

    def page(self, scheme='light', width=1440, height=1100):
        context = self.browser.new_context(color_scheme=scheme, viewport={'width': width, 'height': height})
        self.contexts.append(context)
        # Abort every non-loopback request. These tests must never contact clouds.
        context.route('**/*', lambda route: route.continue_() if route.request.url.startswith(self.origin + '/') else route.abort())
        page = context.new_page()
        page.on('pageerror', lambda error: self.errors.append(str(error)))
        if DOM_ONLY:
            page.expose_function('__computeRequest', self.mock_request)
            markup = self.offline_html()
            page.set_content(markup)
        else:
            page.goto(self.origin + '/dashboard#compute')
        page.wait_for_function('window.__computeFixtureReady === true')
        return page

    def assert_readable(self, page):
        selectors = ['#computeTitle', '#computeProvidersTitle', '#computeChooseAws strong',
                     '#computeChooseGcp .compute-choice-desc', '#computeAwsStatus',
                     '#computeAwsTitle', '#computeAwsGuideStatus', '#computeAwsPanel h4',
                     '#computeAwsExternalId', '#computeAwsPrincipal', '#computeAwsPolicyHelp',
                     '#computeAwsResources summary', '#computePrepareAws', '#computeRefresh',
                     '#computeNextBudget', '.compute-tabs button', '#computeBudgetTitle',
                     '#computeBudgetLimit', '#computeBudgetReserved + span', '#computeQuoteStatus']
        for selector in selectors:
            result = page.evaluate(CONTRAST, selector)
            self.assertGreaterEqual(result['ratio'], 4.5, f'{selector}: {result}')
        page.locator('#computeAwsResources').evaluate('(el)=>el.open=true')
        for selector in ('#computeAwsForm label', '#computeAwsForm input', '#computeVerifyAws'):
            self.assertGreaterEqual(page.evaluate(CONTRAST, selector)['ratio'], 4.5, selector)
        page.locator('#computeAwsResources').evaluate('(el)=>el.open=false')

    def test_versioned_http_assets_and_ready_marker(self):
        page = self.page()
        self.assertEqual(page.locator('#computePanel').get_attribute('data-compute-assets'), 'ready')
        self.assertTrue(page.locator('#computeAssetNotice').is_hidden())
        self.assertEqual(page.locator('#computeAwsExternalId').inner_text(), 'Generate setup ID to continue')
        self.assertEqual(page.evaluate('window.EcaiComputeSettings.assetVersion'), VERSION)
        for ext, folder in [('css', 'css'), ('js', 'js')]:
            url = f'/static/{folder}/ecai-compute-settings.{ext}?v={VERSION}'
            self.assertIn(('GET', url), self.server.requests)
            self.assertNotIn(('GET', url.split('?')[0]), self.server.requests)
        self.assertEqual(page.locator('#computeChooseAws').evaluate('(el)=>getComputedStyle(el).display'), 'grid')
        self.assertEqual(page.locator('#computePanel').evaluate('(el)=>getComputedStyle(el).display'), 'grid')

    def test_light_dark_responsive_layout_and_contrast(self):
        for scheme in ('light', 'dark'):
            for width in (1440, 958, 390, 320):
                with self.subTest(scheme=scheme, width=width):
                    page = self.page(scheme, width)
                    # Reproduce mismatched inherited globals from a shared theme.
                    page.add_style_tag(content='''
                        :root {--ink:#e2ebfb;--paper:#fff;--muted:#a1b4d2;--line:#ddd}
                        body {background:#0d1521;color:#e2ebfb}
                        .surface {background:#fff} p {color:#a1b4d2}
                    ''')
                    self.assert_readable(page)
                    columns = page.locator('.compute-provider-choices').evaluate(
                        '(el)=>getComputedStyle(el).gridTemplateColumns.split(" ").length')
                    self.assertEqual(columns, 1 if width <= 720 else 2)
                    sizes = page.evaluate('({width:innerWidth,scroll:document.documentElement.scrollWidth})')
                    self.assertLessEqual(sizes['scroll'], sizes['width'] + 1, sizes)
                    page.locator('#computeChooseGcp').click()
                    self.assertTrue(page.locator('#computeGcpPanel').is_visible())
                    self.assertTrue(page.locator('#computeAwsPanel').is_hidden())
                    self.assertGreaterEqual(page.evaluate(CONTRAST, '#computeGcpTitle')['ratio'], 4.5)
                    page.locator('#computeChooseAws').click()
                    folder = os.environ.get('ECAI_COMPUTE_SCREENSHOTS')
                    if folder and width in (1440, 390):
                        path = Path(folder); path.mkdir(parents=True, exist_ok=True)
                        page.locator('#computeProviders').scroll_into_view_if_needed()
                        page.screenshot(path=str(path / f'ecai-compute-fixed-{scheme}-{width}.png'))
                        page.locator('#computeProviders').screenshot(path=str(path / f'ecai-provider-panel-{scheme}-{width}.png'))
                    page.close()

    def test_explicit_theme_overrides_system_preference(self):
        for system, override, expected in [('dark', 'light', 'light'), ('light', 'dark', 'dark')]:
            for attribute in ('class', 'data-theme'):
                with self.subTest(system=system, attribute=attribute):
                    page = self.page(system)
                    page.evaluate('([attr,value])=>document.body.setAttribute(attr,value)',
                                  [attribute, f'theme-{override}' if attribute == 'class' else override])
                    self.assertEqual(page.locator('#computePanel').evaluate('(el)=>getComputedStyle(el).colorScheme'), expected)
                    self.assert_readable(page)
                    page.close()

    def test_provider_keyboard_selection_prepare_save_verify(self):
        page = self.page('dark')
        self.assertTrue(page.locator('#computeNextBudget').is_disabled())
        page.locator('#computeChooseGcp').focus()
        page.keyboard.press('Enter')
        self.assertEqual(page.locator('#computeChooseGcp').get_attribute('aria-pressed'), 'true')
        self.assertTrue(page.locator('#computeAwsPanel').is_hidden())
        page.locator('#computeChooseAws').focus()
        page.keyboard.press('Space')
        self.assertTrue(page.locator('#computeGcpPanel').is_hidden())
        page.locator('#computePrepareAws').click()
        page.wait_for_function('document.getElementById("computeAwsExternalId").textContent.length===48')
        self.assertTrue(page.locator('#computePrepareAws').is_disabled())
        self.assertTrue(page.locator('#computeCopyTrustPolicy').is_disabled())
        self.server.settings['connection_hints']['aws_coordinator_role_arn'] = PRINCIPAL
        page.evaluate('window.EcaiComputeSettings.refresh()')
        self.assertTrue(page.locator('#computeCopyTrustPolicy').is_enabled())
        page.locator('#computeAwsResources summary').click()
        for name, value in dict(role_arn='arn:aws:iam::123456789012:role/EcaiIndexer',
                                region='ap-southeast-2', job_queue='ecai-index-spot',
                                job_definition='ecai-index-job', bucket='ecai-index-artifacts').items():
            page.locator(f'#computeAwsForm [name="{name}"]').fill(value)
        page.locator('#computeAwsForm [type="submit"]').click()
        page.wait_for_function('!document.getElementById("computeVerifyAws").disabled')
        self.assertTrue(page.locator('#computeNextBudget').is_disabled())
        page.locator('#computeVerifyAws').click()
        page.wait_for_function('!document.getElementById("computeNextBudget").disabled')
        self.assertEqual(page.locator('#computeAwsStatus').inner_text(), 'Identity verified')
        page.locator('#computeChooseGcp').click()
        page.locator('input[form="computeGcpForm"]').fill('ecai-demo-123')
        self.assertEqual(page.locator('#computeGcpConsoleLink').get_attribute('href'),
                         'https://console.cloud.google.com/run/jobs?project=ecai-demo-123')
        page.locator('#computeGcpResources summary').click()
        for name, value in dict(region='australia-southeast1', job='ecai-shard',
                                bucket='ecai-index-artifacts',
                                service_account='worker@ecai-demo-123.iam.gserviceaccount.com').items():
            page.locator(f'#computeGcpForm [name="{name}"]').fill(value)
        page.locator('#computeGcpForm [type="submit"]').click()
        page.wait_for_function('!document.getElementById("computeVerifyGcp").disabled')
        page.locator('#computeVerifyGcp').click()
        page.wait_for_function('document.getElementById("computeGcpStatus").textContent==="Identity verified"')
        self.assertEqual([path for path, _ in self.server.posts], [
            '/ecai/compute/providers/aws_batch/prepare', '/ecai/compute/providers/aws_batch',
            '/ecai/compute/providers/aws_batch/verify', '/ecai/compute/providers/cloud_run',
            '/ecai/compute/providers/cloud_run/verify'])
        # Selecting a provider or initializing never writes budget or mint state.
        self.assertEqual(self.server.posts[0][1], {})
        self.assertFalse(self.server.settings['budget']['remote_enabled'])

    def test_failed_prepare_recovers_and_signed_out_write_is_blocked(self):
        page = self.page()
        self.server.fail_next_post = True
        page.locator('#computePrepareAws').click()
        page.wait_for_function('document.getElementById("computeNotice").textContent.includes("simulated_provider_failure")')
        self.assertTrue(page.locator('#computePrepareAws').is_enabled())
        page.evaluate('window.__signedIn=false')
        page.locator('#computePrepareAws').click()
        page.wait_for_function('window.__loginRequests===1')
        self.assertEqual(len(self.server.posts), 1, 'Signed-out request must not reach the API')
        self.assertTrue(page.locator('#computeCopyExternalId').is_disabled())

    def test_missing_or_stale_css_is_reported_not_silently_hidden(self):
        for mode in ('missing_css', 'stale_css'):
            with self.subTest(mode=mode):
                self.server.asset_mode = mode
                page = self.page()
                self.assertTrue(page.locator('#computeAssetNotice').is_visible())
                self.assertIn('assets are missing or out of date', page.locator('#computeAssetNotice').inner_text())
                self.assertEqual(page.locator('#computePanel').get_attribute('data-compute-assets'), 'mismatch')
                page.close()

    def test_missing_or_stale_js_leaves_initial_loading_warning(self):
        for mode in ('missing_js', 'stale_js'):
            with self.subTest(mode=mode):
                self.server.asset_mode = mode
                page = self.page()
                self.assertTrue(page.locator('#computeAssetNotice').is_visible())
                self.assertIn('reload the dashboard', page.locator('#computeAssetNotice').inner_text())
                self.assertNotEqual(page.locator('#computePanel').get_attribute('data-compute-assets'), 'ready')
                page.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
