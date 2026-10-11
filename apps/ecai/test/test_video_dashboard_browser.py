#!/usr/bin/env python3
"""Standalone Chromium smoke test for the Video Studio dashboard.

Exercises actual shipped ECAI HTML/CSS/JS, mocked DamageBDD login and Fastpath
API. Complements the separate Fastpath HTTP integration tests; does NOT claim
that Cowboy or Erlang compiled in this environment.
Run: python apps/ecai/test/test_video_dashboard_browser.py
"""
from __future__ import annotations

import asyncio
import json
from pathlib import Path
from urllib.parse import urlsplit

from playwright.async_api import async_playwright

ROOT = Path(__file__).resolve().parents[1]
ORIGIN = 'http://127.0.0.1:18881'
PROJECT = 'a' * 32
VERSION = 'b' * 32
NEXT = 'c' * 32
JOB = 'd' * 32
ACCOUNT = 'ak_test_managed_account'

SESSION = '''export const TokenManager = {
  session:() => window.__session,
  getToken:() => window.__session?.token || '',
  getAddress:() => window.__session?.address || '',
  refreshSession: async()=>window.__session,
  logout:()=>{window.__session = null;},
};
export async function logoutActiveSession(){ window.__session=null; }
'''
AUTH = 'export function initAuthUI(){window.DamageAuth = {open:(mode)=>window.__lastLogin=mode,status:()=>{}};}\n'
POOL = 'window.EcaiIndexPool={init(){},setVisible(){},refresh:async()=>{}};\n'


def template() -> str:
    shell = (ROOT/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
    video = (ROOT/'priv/templates/ui/dashboard/ecai_video.mustache').read_text()
    # Render the *actual* dashboard shell, without help from the Erlang
    # video_studio context variable. That dependency caused the reported crash.
    compact = lambda s: "\n".join(line.strip() for line in s.strip().splitlines())
    assert compact(video) in compact(shell), "Video fragment missing from dashboard shell"
    return (shell.replace('{{{browser_auth_modal}}}', '')
             .replace('{{node_version}}', 'video-fixture'))


class FakeServer:
    def __init__(self):
        self.projects = []
        self.versions = []
        self.calls = []
        self.job = None
        self.submissions = 0

    def version(self, ident=VERSION, operation='import', parent=None, reused=True):
        return {'id':ident, 'project_id':PROJECT,'operation':operation,'parent_version_id':parent,
                'source_sha256':'e'*64,'output_sha256':'e'*64,
                'sealed_manifest':{'manifest':{'processing':{'reused_exact_video_bytes':reused,'provider_generation_skipped':True}}}}

    async def route(self, route):
        req = route.request
        path = urlsplit(req.url).path
        if path in ('/dashboard', '/'):
            return await route.fulfill(body=template(),content_type='text/html')
        if path.startswith('/ecai/auth-assets/js/'):
            name = path.rsplit('/',1)[-1]
            body = SESSION if name == 'wallet-switcher.js' else AUTH if name == 'auth-ui.js' else ''
            return await route.fulfill(body=body,content_type='text/javascript')
        if path.startswith('/static/'):
            if path == '/static/js/ecai-index-pool.js':
                return await route.fulfill(body=POOL,content_type='text/javascript')
            file = ROOT/'priv'/path.lstrip('/')
            if not file.is_file(): return await route.fulfill(status=404,body='Missing '+path)
            mime = 'text/javascript' if file.suffix=='.js' else 'text/css' if file.suffix=='.css' else 'image/svg+xml'
            return await route.fulfill(body=file.read_bytes(),content_type=mime)
        if path.endswith('.css') or path.endswith('micromodal.min.js'):
            return await route.fulfill(body='',content_type='text/css' if path.endswith('css') else 'text/javascript')
        self.calls.append((req.method,path,dict(req.headers)))
        session = 'authorization' in req.headers and req.headers['authorization'].startswith('Bearer ds1.')
        post = json.loads(req.post_data) if req.post_data and req.headers.get('content-type','').startswith('application/json') else {}
        status, data = 200, {}
        if path == '/ecai/video/status':
            data = {'enabled': True, 'status':'ready'}
        elif path == '/ecai/auth/session':
            data = {'authenticated':session,'public_key':ACCOUNT,'auth_mode':'custodial','node_admin':False}
        elif path == '/ecai/chat': data = {'status':'ok'}
        elif path == '/yelp/status': data={'index_size':{'docs':0}}
        elif path == '/ecai/index-jobs/status': data = {'status':{'running_jobs':0,'queued_jobs':0}}
        elif path == '/ecai/index-jobs/presets': data={'presets':[]}
        elif path == '/ecai/index-jobs': data={'jobs':[]}
        elif path.startswith('/ecai/video/') and not session:
            status, data = 403, {'error':'managed_session_required'}
        elif path == '/ecai/video/projects':
            if req.method == 'POST':
                assert post['title']=='Customer campaign'
                self.projects.append({'id':PROJECT,'title':post['title'], 'license':post['license'], 'tags':post['tags']})
                status, data=201, self.projects[0]
            else: data=self.projects
        elif path == '/ecai/video/backends':
            data=[{'id':'demo','label':'Demo','is_demo':True,'kind':'demo'}]
        elif path == '/ecai/video/backend-connection-policy':
            data={'enabled':False,'approved_hosts':[]}
        elif path == f'/ecai/video/projects/{PROJECT}/versions':
            if req.method=='POST':
                assert post['operation']=='metadata' and post['parent_version_id']==VERSION
                v=self.version(NEXT,'metadata',VERSION)
                self.versions.append(v)
                data=v;status=201
            else:data=self.versions
        elif path == f'/ecai/video/projects/{PROJECT}/value':
            data={'revisions':len(self.versions),'external_provider_submissions':self.submissions,
                  'avoided_provider_regenerations':sum(v['operation']=='metadata' for v in self.versions)}
        elif path == f'/ecai/video/projects/{PROJECT}/jobs':
            data=[self.job] if self.job else []
        elif path == f'/ecai/video/projects/{PROJECT}/generations':
            assert post['backend_id']=='demo'
            self.job={'id':JOB,'backend':'demo','state':'queued','attempts':0}
            status,data=202,self.job
        elif path == f'/ecai/video/jobs/{JOB}':
            self.job={'id':JOB,'backend':'demo','state':'completed','attempts':1, 'version_id':VERSION}
            self.versions=[self.version()]
            data=self.job
        elif path == f'/ecai/video/versions/{NEXT}/verify':
            data={'verified':True,'signature_valid':True,'bytes_match_sha256':True,'lineage_valid':True,'video_sha256':'e'*64}
        elif path == f'/ecai/video/versions/{NEXT}/nft-draft':
            data={'minted':False,'publication_verified':False,'metadata':{'animation_url':'ipfs://'+post['video_cid']}}
        elif path == f'/ecai/video/versions/{NEXT}/manifest':
            data={'manifest':{'video_sha256':'e'*64},'proof':{'signature':'mock'}}
        elif path == f'/ecai/video/projects/{PROJECT}/graph':
            data={'edges':[{'from':VERSION,'to':NEXT,'relation':'derived_from'}]}
        else:
            status,data=404,{'error':'not_mapped','path':path}
        await route.fulfill(status=status, body=json.dumps(data), headers={'content-type':'application/json','cache-control':'no-store'})


async def run():
    # This runner may ship with locked-down enterprise Chromium (URLBlocklist=*).
    # Do not count policy-blocked navigations as a product/browser test failure.
    policies = Path('/etc/chromium/policies/managed')
    if any('"URLBlocklist"' in p.read_text(errors='replace') and
           '"*"' in p.read_text(errors='replace') for p in policies.glob('*.json')) if policies.is_dir() else False:
        print('SKIP: this machine blocks all Chromium URLs by administrator policy')
        return
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(executable_path='/usr/bin/chromium',headless=True,
                                                   args=['--no-sandbox','--disable-dev-shm-usage'])
        backend=FakeServer()
        page=await browser.new_page()
        console_errors=[]
        page.on('pageerror',lambda err:console_errors.append(str(err)))
        await page.add_init_script('window.__session=null;')
        await page.route('**/*',backend.route)
        await page.goto(ORIGIN+'/dashboard#video',wait_until='networkidle')
        await page.locator('[data-view="video"]').wait_for()
        assert await page.locator('[data-view="video"]').is_visible()
        assert await page.locator('[data-panel="video"]').is_visible()
        assert 'Sign in' in (await page.locator('#videoNotice').inner_text())
        await page.evaluate("window.__session={mode:'custodial',token:'ds1.fake-verified',address:'%s',email:'customer@example.test'};document.dispatchEvent(new Event('auth:changed'))" % ACCOUNT)
        await page.locator('#videoRefresh').click()
        await page.wait_for_function("document.querySelector('#videoServiceState').textContent.includes('connected')")
        await page.locator('#videoProjectTitle').fill('Customer campaign')
        await page.locator('#videoProjectForm button[type="submit"]').click()
        await page.wait_for_function("document.querySelector('#videoProjectSelect').value === '%s'" % PROJECT)
        await page.locator('#videoPrompt').fill('Slow reveal of a product')
        await page.locator('#videoGenerateForm button[type="submit"]').click()
        await page.wait_for_function("document.querySelector('#videoJobArea').textContent.includes('queued')")
        await page.wait_for_function("document.querySelector('#videoJobArea').textContent.includes('completed')", timeout=12000)
        await page.locator('#videoReloadVersions').click()
        await page.wait_for_function("document.querySelectorAll('.video-version').length >= 1")
        await page.locator('#videoOperation').select_option('metadata')
        await page.locator('#videoRevisionText').fill('Localized AUD offer')
        await page.locator('#videoRevisionForm button[type="submit"]').click()
        await page.wait_for_function("document.querySelector('#videoSelected').textContent.includes('%s')" % NEXT)
        await page.locator('#videoVerifyBtn').click()
        await page.wait_for_function("document.querySelector('#videoVerifyResult').textContent.includes('VERIFIED')")
        await page.locator('#videoManifestBtn').click()
        await page.wait_for_function("document.querySelector('#videoProofOutput').textContent.includes('video_sha256')")
        await page.locator('#videoCid').fill('bafy1234567890abcde')
        await page.locator('#videoNftForm button[type="submit"]').click()
        await page.wait_for_function("document.querySelector('#videoProofOutput').textContent.includes('minted')")
        await page.evaluate("window.__session={mode:'wallet',token:'ds1.wallet-test',address:'%s'};document.dispatchEvent(new Event('auth:changed'))" % ACCOUNT)
        assert await page.locator('#videoGenerateBtn').is_disabled()
        assert 'Sign in' in (await page.locator('#videoNotice').inner_text())
        assert not console_errors, console_errors
        assert any(path=='/ecai/video/projects' and method=='POST' and headers.get('authorization')=='Bearer ds1.fake-verified'
                   for method,path,headers in backend.calls)
        print('PASS: video visible, managed session, project, generation, durable completion, revision, proof, NFT draft, wallet restriction')
        await browser.close()

if __name__=='__main__': asyncio.run(run())
