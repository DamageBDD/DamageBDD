#!/usr/bin/env python3
"""UI acceptance with a mocked API; does NOT verify AWS/CLN or run the Erlang engine.
Run: python apps/damage/test/scripts/verification_browser_test.py
Requires Playwright for Python and Chromium (CHROMIUM defaults to /usr/bin/chromium).
The test fixture is derived from the .feature files, not a second product catalog.
"""
from __future__ import annotations
import hashlib
import json
import os
import re
import time
import unittest
from pathlib import Path
from playwright.sync_api import sync_playwright

APP = Path(__file__).resolve().parents[2]
OUT = Path(os.environ.get('VERIFICATION_TEST_OUTPUT', '/tmp/damage-verification-ui'))


def fixture(path: Path) -> dict:
    """Read simple test fixture content. Production always uses egherkin."""
    source = path.read_text()
    f = dict(id=hashlib.sha256(path.name.encode()).hexdigest(),
             sha256=hashlib.sha256(source.encode()).hexdigest(), source=source,
             available=True, runnable=True, validation={'valid': True},
             scenarios=[], background=[], tags=[], fields=[])
    desc = []
    for line_no, raw in enumerate(source.splitlines(), 1):
        line = raw.strip()
        if line.startswith('@') and 'title' not in f:
            f['tags'] += [x[1:] for x in line.split()]
        elif line.startswith('Feature:'):
            f['title'] = line.partition(':')[2].strip()
        elif line.startswith('Scenario:'):
            f['scenarios'].append(dict(line=line_no, title=line.partition(':')[2].strip(), tags=[], steps=[]))
        elif re.match(r'^(Given|When|Then|And|But) ', line):
            keyword, _, body = line.partition(' ')
            f['scenarios'][-1]['steps'].append(dict(line=line_no, keyword=keyword, text=body))
        elif line and not line.startswith('@') and not f['scenarios']:
            desc.append(line)
    f['description'] = '\n'.join(desc)
    for key in sorted(set(re.findall(r'\{\{([a-z_]+)\}\}', source))):
        f['fields'].append(dict(key=key, label=key.replace('_', ' '), editable=True,
                                configured=False, sensitive=False, value=''))
    return f


# Run in an in-memory browser page so tests do not require network access or a
# permissive browser URL policy. Only fetch is mocked; the production renderer,
# template and CSS execute unchanged (ES export declarations are removed).
MOCK = r"""
window.currentToken='first-session';
window.TokenManager={getToken:()=>window.currentToken};
window.fixture={calls:[],features:FEATURES,jobs:{},polls:{},approvals:{},error:0,hold:null,held:[]};
window.fetch=async(path,options={})=>{
 const f=window.fixture,method=options.method||'GET';
 const body=options.body?JSON.parse(options.body):null;
 f.calls.push({path,method,body,auth:options.headers?.Authorization});
 const response=(data,status=200)=>({ok:status<400,status,json:async()=>structuredClone(data)});
 if(method==='POST'){
  if(options.headers['X-Damage-Verification']!=='1'||options.headers['Content-Type']!=='application/json')throw Error('Missing action headers');
  if(path.endsWith('/preview')){
   const id='preview-'+Object.keys(f.jobs).length,now=Math.floor(Date.now()/1000);
   const j={id,mode:'preview',state:'ready',feature_id:body.feature_id,sha256:body.sha256,
    cost:400000000,cost_damage:4,created_at:now,completed_at:now,approval_expires_at:now+300,
    input_values:body.inputs,context_fingerprint:'a'.repeat(64),code_revision:'b'.repeat(64),progress:[]};
   f.jobs[id]=j;return response(j);
  }
  if(path.endsWith('/run')){
   if(f.approvals[body.preview_id])return response(f.jobs[f.approvals[body.preview_id]]);
   const q=f.jobs[body.preview_id],id='run-'+Object.keys(f.jobs).length;
   const j={...q,id,mode:'execute',state:'running',preview_id:q.id,approval_expires_at:null};
   f.approvals[q.id]=id;f.jobs[id]=j;q.approved_job=id;return response(j);
  }
 }
 if(path.endsWith('/catalog'))return response({features:f.features.map(({source,fields,...r})=>r)});
 if(path.endsWith('/history'))return response({jobs:Object.values(f.jobs).reverse()});
 if(path.includes('/features/')){
  const id=path.split('/').pop();
  if(f.hold===id)await new Promise(resolve=>f.held.push(resolve));
  return response(f.features.find(x=>x.id===id));
 }
 if(path.includes('/jobs/')){
  if(f.error)return response({error:'forbidden'},f.error);
  const id=path.split('/').pop(),j=f.jobs[id],n=(f.polls[id]||0)+1;f.polls[id]=n;
  if(j.mode==='execute'&&n>=2){
   j.state='passed';j.completed_at=Math.floor(Date.now()/1000);j.report_hash='Qm'+'1'.repeat(44);
   const feature=f.features.find(x=>x.id===j.feature_id);
   j.progress=feature.scenarios.flatMap(sc=>sc.steps.map(s=>({line:s.line,state:'passed'})));
  }
  return response(j);
 }
 return response({error:'not_found'},404);
};
// Observe receipt bytes without depending on the browser's download policy.
const oldClick=HTMLAnchorElement.prototype.click;
HTMLAnchorElement.prototype.click=function(){if(!this.download)oldClick.call(this);};
URL.createObjectURL=blob=>{window.receiptBlob=blob;return 'blob:fixture';};
URL.revokeObjectURL=()=>{};
document.getElementById('open').onclick=()=>{document.getElementById('verification-tab').hidden=false;
 document.dispatchEvent(new CustomEvent('damage:panelchange',{detail:{id:'verification-tab'}}));};
document.getElementById('away').onclick=()=>{document.getElementById('verification-tab').hidden=true;
 document.dispatchEvent(new CustomEvent('damage:panelchange',{detail:{id:'execution-tab'}}));};
"""


class UI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        OUT.mkdir(parents=True,exist_ok=True)
        cls.pw=sync_playwright().start()
        cls.browser=cls.pw.chromium.launch(headless=True,
            executable_path=os.environ.get('CHROMIUM','/usr/bin/chromium'),
            args=['--no-sandbox','--disable-dev-shm-usage'])
    @classmethod
    def tearDownClass(cls):
        cls.browser.close();cls.pw.stop()
    def setUp(self):
        self.features=[fixture(p) for p in sorted((APP/'priv/features/verification').glob('*.feature'))]
        self.context=self.browser.new_context(viewport={'width':1360,'height':1100})
        self.page=self.context.new_page();self.errors=[]
        self.page.on('pageerror',lambda e:self.errors.append(str(e)))
        css=(APP/'priv/static/css/dashboard-workspace.css').read_text()+'\n'+(APP/'priv/static/css/verification.css').read_text()
        template=(APP/'priv/templates/ui/dashboard/verification_tab.mustache').read_text()
        self.page.set_content('''<!doctype html><html lang="en"><head><meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1"><style>'''+css+'''
          main{max-width:1350px;margin:auto;padding:24px}nav{display:flex;gap:12px;flex-wrap:wrap;padding:12px 24px;border-bottom:1px solid #2d3b4e}
          .fixture{color:#a7b6c9;font-size:12px}@media(max-width:600px){main{padding:14px}}
          </style></head><body class="damage-dashboard"><nav><strong>DAMAGE</strong><button id="open">Verify</button>
          <button id="away">Other workspace</button><span class="fixture">UI TEST FIXTURE · No live checks</span></nav>
          <main><div id="verification-tab" data-dashboard-view hidden>'''+template+'''</div></main></body></html>''')
        self.page.add_script_tag(content=MOCK.replace('FEATURES',json.dumps(self.features)))
        script=(APP/'priv/static/js/verification.js').read_text()
        self.page.add_script_tag(content=re.sub(r'^export ', '',script,flags=re.M))
        self.page.wait_for_function("document.querySelector('[data-v-message]').textContent.includes('Open this workspace')")
    def tearDown(self):
        self.context.close();self.assertEqual([],self.errors)
    def calls(self):return self.page.evaluate('window.fixture.calls')
    def open(self):
        self.page.locator('#open').click();self.page.locator('[data-v-card]').first.wait_for()
    def choose(self,name):
        f=next(f for f in self.features if name.lower() in f['title'].lower())
        self.page.locator(f'[data-v-card="{f["id"]}"]').click();self.page.locator('[data-v-form]').wait_for();return f
    def estimate(self):
        for key,value in [('verification_single_msat','100000'),('verification_total_msat','500000')]:
            field=self.page.locator(f'[data-v-input="{key}"]')
            if field.count():field.fill(value)
        self.page.locator('[data-v-estimate]').click();self.page.locator('[data-v-approval]').wait_for()
    def test_01_end_to_end_preview_approval_progress_report_mobile(self):
        self.assertEqual([],self.calls())
        self.open();f=self.choose('Lightning')
        self.assertFalse(self.page.locator('.verification-source pre').is_visible())
        self.assertEqual([], [c for c in self.calls() if c['method']=='POST'])
        self.estimate()
        self.assertTrue(self.page.locator('[data-v-run]').is_disabled())
        self.assertIn('4 DAMAGE',self.page.locator('.verification-cost').inner_text())
        self.assertIn('100000',self.page.locator('.verification-quoted-inputs').inner_text())
        self.page.locator('[data-v-approval]').check()
        self.page.locator('[data-v-run]').evaluate('(n)=>{n.click();n.click()}')
        self.page.wait_for_function("document.querySelector('[data-v-job]').dataset.state==='passed'")
        self.assertEqual(1,len([c for c in self.calls() if c['path'].endswith('/run') and c['method']=='POST']))
        self.assertEqual(2,self.page.locator('[data-v-scenario][data-state="passed"]').count())
        self.assertTrue(self.page.get_by_role('link',name='Open native DamageBDD report').get_attribute('href').startswith('/reports/Qm'))
        self.page.get_by_role('button',name='Download workspace receipt').click()
        receipt=self.page.evaluate('async()=>JSON.parse(await window.receiptBlob.text())')
        self.assertEqual('passed',receipt['state']);self.assertNotIn('spec',receipt);self.assertNotIn('private_key',receipt)
        self.page.screenshot(path=str(OUT/'verification-desktop.png'),full_page=True)
        self.page.set_viewport_size({'width':390,'height':844})
        self.assertTrue(self.page.evaluate('document.documentElement.scrollWidth<=document.documentElement.clientWidth'))
        self.page.screenshot(path=str(OUT/'verification-mobile.png'),full_page=True)
        self.page.locator('.verification-source summary').click()
        self.assertEqual(f['source'],self.page.locator('.verification-source pre').text_content())
    def test_02_text_escaping_and_sensitive_context(self):
        self.page.evaluate('''()=>{const f=fixture.features[0];f.title='<img src=x onerror="window.pwned=true"> Safe text';
          f.fields.push({key:'server_secret',label:'Signing credential',editable:false,configured:true,
          sensitive:true,value:'MUST_NOT_APPEAR'});}''')
        self.open();self.choose('credential')
        self.assertIsNone(self.page.evaluate('window.pwned'))
        self.assertEqual(0,self.page.locator('[data-verification-root] img').count())
        self.assertNotIn('MUST_NOT_APPEAR',self.page.locator('[data-v-detail]').inner_text())
        self.assertIn('Provided securely',self.page.locator('[data-v-detail]').inner_text())
        self.estimate()
        payload=next(c['body'] for c in self.calls() if c['method']=='POST')
        self.assertNotIn('server_secret',payload['inputs'])
    def test_03_late_response_after_identity_change_is_discarded(self):
        self.open();f=self.features[0];self.page.evaluate('(id)=>fixture.hold=id',f['id'])
        self.page.locator(f'[data-v-card="{f["id"]}"]').click()
        self.page.wait_for_function('fixture.held.length===1')
        self.page.locator('#away').click()
        self.page.evaluate("window.currentToken='second-session';document.dispatchEvent(new Event('auth:changed'));fixture.hold=null;fixture.held.splice(0).forEach(f=>f())")
        self.page.wait_for_timeout(100)
        self.assertEqual(0,self.page.locator('[data-v-detail] h2').count())
        before=len(self.calls());self.page.wait_for_timeout(100);self.assertEqual(before,len(self.calls()))
        self.open();self.choose('credential')
        self.assertEqual('Bearer second-session',self.calls()[-1]['auth'])
    def test_04_no_automatic_poll_or_post_retry_on_forbidden(self):
        self.open();self.choose('credential');self.estimate();self.page.evaluate('fixture.error=403')
        self.page.locator('[data-v-approval]').check();self.page.locator('[data-v-run]').click()
        self.page.wait_for_function("document.querySelector('[data-v-message]').textContent.includes('not authorised')")
        count=len([c for c in self.calls() if '/jobs/' in c['path']]);self.page.wait_for_timeout(1250)
        self.assertEqual(count,len([c for c in self.calls() if '/jobs/' in c['path']]))
        self.assertEqual(1,len([c for c in self.calls() if c['path'].endswith('/run') and c['method']=='POST']))
        self.page.evaluate('fixture.error=0');self.page.get_by_role('button',name='Refresh status',exact=True).click()
        self.page.wait_for_function("document.querySelector('[data-v-job]').dataset.state==='passed'")
    def test_05_editing_inputs_invalidates_ready_approval(self):
        self.open();self.choose('Lightning');self.estimate();self.page.locator('[data-v-approval]').check()
        self.page.locator('[data-v-input="verification_single_msat"]').fill('200000')
        self.assertEqual(0,self.page.locator('[data-v-run]').count())
        self.assertEqual(0,len([c for c in self.calls() if c['path'].endswith('/run') and c['method']=='POST']))


if __name__=='__main__':unittest.main(verbosity=2)
