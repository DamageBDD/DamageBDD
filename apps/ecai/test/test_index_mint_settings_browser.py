#!/usr/bin/env python3
"""Browser tests of the real Index mint settings markup/CSS/controller.

Uses a deterministic managed-session fixture and mocked fetch, never credentials,
Cowboy, or a chain. The module import is replaced with the test TokenManager only.
Run: python3 apps/ecai/test/test_index_mint_settings_browser.py
Requires Playwright Chromium; ECAI_CHROMIUM can override its executable.
"""
import json
import os
from pathlib import Path
import re
import shutil
import unittest
from playwright.sync_api import sync_playwright

APP = Path(__file__).resolve().parents[1]
SHELL = (APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
START = SHELL.index('          <details id="indexMintSettings"')
END = SHELL.index('          <details class="surface expandable"><summary>Enqueue custom',START)
MARKUP = SHELL[START:END]
SCRIPT = (APP/'priv/static/js/ecai-index-mint-settings.js').read_text()
SCRIPT = re.sub(r'^import .*wallet-switcher.js";\n', 'const TokenManager = window.TokenManager;\n', SCRIPT,flags=re.M)
SETTINGS = {'mint':{'enabled':True,'recipient':'ak_12345678901234567890123456789012345','chain':'aeternity'},
    'budget':{'remote_enabled':True,'monthly_cents':5025,'per_job_cents':500,'mint_monthly_cents':3000},
    'reserved_mint_cents':100,'period_utc':'2026-10','mint_requests':[
        {'job_id':'ijob-demo','copies':3,'requested_metadata':{'title':'<img onerror=alert(1)> demo'},
         'recipient':'ak_12345678901234567890123456789012345','fee_cap_cents':100,'status':'awaiting_wallet_signature'}]}

class IndexMintSettingsBrowser(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pw=sync_playwright().start()
        exe=os.environ.get('ECAI_CHROMIUM') or shutil.which('chromium') or shutil.which('chromium-browser')
        cls.browser=cls.pw.chromium.launch(**({'executable_path':exe} if exe else {}),args=['--no-sandbox'])
    @classmethod
    def tearDownClass(cls): cls.browser.close(); cls.pw.stop()
    def setUp(self): self.contexts=[]
    def tearDown(self):
        for ctx in self.contexts: ctx.close()
    def page(self, width=958, dark=True):
        ctx=self.browser.new_context(viewport={'width':width,'height':1000},color_scheme='dark' if dark else 'light')
        self.contexts.append(ctx);ctx.route('**/*', lambda route:route.abort())
        page=ctx.new_page();page.on('pageerror',lambda error:self.fail(str(error)))
        base=(APP/'priv/static/css/ecai-console.css').read_text()
        css=(APP/'priv/static/css/ecai-index-mint-settings.css').read_text()
        theme=':root {--text:#e6edf7;--ink:#e6edf7;--muted:#afc0dc;--surface-2:#243343;--panel:#172337;--border:#445570;--accent:#adc5ef} .surface {background:#172337;} body {background:#0d1521;}' if dark else ''
        page.set_content(f'<html><head><style>{base}\n{css}\n{theme}\nbody{{padding:16px}} .index-mint-settings{{max-width:1000px;margin:auto}}</style></head><body>{MARKUP}</body></html>')
        page.evaluate('''settings=>{
          window.__settings=settings; window.__posts=[]; window.__token='managed-demo'; window.__mode='custodial';
          window.__fail=false; window.__delay=false; window.__pending=[];
          window.TokenManager={getToken:()=>window.__token,session:()=>({mode:window.__mode})};
          window.fetch=async(path,opts={})=>{
            const snapshot=JSON.parse(JSON.stringify(window.__settings));
            if(opts.method==='POST'){
              window.__posts.push({path,headers:opts.headers,body:JSON.parse(opts.body)});
              if(window.__fail)return new Response(JSON.stringify({ok:false,error:'rejected'}),{status:409});
              const body=JSON.parse(opts.body);
              window.__settings.mint={enabled:body.enabled,recipient:body.recipient,chain:body.chain};
              window.__settings.budget.mint_monthly_cents=body.monthly_cents;
            }
            if(window.__delay)await new Promise(resolve=>window.__pending.push(resolve));
            return new Response(JSON.stringify({ok:true,data:snapshot}),{status:200});
          };
        }''', SETTINGS)
        page.add_script_tag(content=SCRIPT)
        return page
    def open(self,page):
        page.locator('#indexMintSettings > summary').click()
        page.wait_for_function('!document.getElementById("indexMintPolicyFields").disabled')
    def test_moved_fields_history_and_xss_are_plain_text(self):
        page=self.page(); self.open(page)
        self.assertEqual(page.locator('[name="monthly"]').input_value(),'30.00')
        self.assertIn('3 copies',page.locator('#indexMintRequestList').inner_text())
        self.assertEqual(page.locator('#indexMintRequestList img').count(),0)
        self.assertEqual(page.evaluate('window.__posts'),[])
        self.assertTrue(page.locator('#indexMintSettings').is_visible())
    def test_save_is_scoped_and_preserves_compute(self):
        page=self.page(); self.open(page)
        page.locator('[name="monthly"]').fill('40.01')
        page.locator('#indexMintPolicySave').click()
        page.wait_for_function('window.__posts.length===1 && !document.getElementById("indexMintPolicyFields").disabled')
        post=page.evaluate('window.__posts[0]')
        self.assertEqual(post['path'],'/ecai/compute/mint-policy')
        self.assertEqual(set(post['body']), {'enabled','recipient','chain','monthly_cents'})
        self.assertEqual(post['body']['monthly_cents'],4001)
        self.assertEqual(post['headers']['Authorization'],'Bearer managed-demo')
        self.assertEqual(page.evaluate('window.__settings.budget.monthly_cents'),5025)
    def test_refresh_keeps_unsaved_preferences_and_failed_save_keeps_draft(self):
        page=self.page(); self.open(page)
        page.locator('[name="monthly"]').fill('51.00')
        page.locator('#indexMintSettingsRefresh').click()
        page.wait_for_function('document.getElementById("indexMintSettingsStatus").textContent.includes("Unsaved preferences kept")')
        self.assertEqual(page.locator('[name="monthly"]').input_value(),'51.00')
        page.evaluate('window.__fail=true')
        page.locator('#indexMintPolicySave').click()
        page.wait_for_function('document.getElementById("indexMintSettingsStatus").textContent.includes("rejected")')
        self.assertEqual(page.locator('[name="monthly"]').input_value(),'51.00')
        self.assertTrue(page.locator('#indexMintPolicySave').is_enabled())
    def test_identity_change_discards_late_old_account_response(self):
        page=self.page();page.evaluate('window.__delay=true')
        page.locator('#indexMintSettings > summary').click()
        page.wait_for_function('window.__pending.length===1')
        page.evaluate('''()=>{window.__token='';window.__mode='anonymous';document.dispatchEvent(new CustomEvent('ecai:identity-changed'));window.__pending[0]();}''')
        page.wait_for_timeout(60)
        self.assertTrue(page.locator('#indexMintPolicySave').is_disabled())
        self.assertEqual(page.locator('[name="recipient"]').input_value(),'')
        self.assertEqual(page.locator('#indexMintRequestList').inner_text(),'')
    def test_wallet_mode_cannot_load_or_save(self):
        page=self.page();page.evaluate("window.__mode='wallet'")
        page.locator('#indexMintSettings > summary').click()
        self.assertTrue(page.locator('#indexMintPolicySave').is_disabled())
        self.assertEqual(page.evaluate('window.__posts'),[])
    def test_light_dark_mobile_layouts(self):
        for dark in [False,True]:
            for width in [320,390,958]:
                page=self.page(width,dark);self.open(page)
                self.assertLessEqual(page.evaluate('document.documentElement.scrollWidth'),width)
                if os.getenv('ECAI_MINT_SCREENSHOTS') and width in [390,958]:
                    path=Path(os.environ['ECAI_MINT_SCREENSHOTS']);path.mkdir(parents=True,exist_ok=True)
                    page.screenshot(path=str(path/f'mint-preferences-{"dark" if dark else "light"}-{width}.png'))
                page.close()

if __name__=='__main__': unittest.main(verbosity=2)
