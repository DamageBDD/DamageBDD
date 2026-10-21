#!/usr/bin/env python3
"""Mocked browser workflow for the production AWS wizard and CSS.

python3 apps/ecai/test/test_aws_setup_browser.py [--dom-only]
ECAI_AWS_SCREENSHOTS=/tmp/previews saves optional preview captures.

No live AWS/Cowboy/auth operation occurs. --dom-only wraps the unchanged wizard
source with an HTTPS location fixture when browser URL navigation is blocked.
It does NOT test TLS, origin headers, browser HTTP caching or proxy deployment.
"""
import json
import os
from pathlib import Path
import re
import shutil
import sys
import unittest
from playwright.sync_api import sync_playwright

APP=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(APP/'priv/aws_setup'))
from template import make_plan
DOM_ONLY='--dom-only' in sys.argv
if DOM_ONLY:sys.argv.remove('--dom-only')
OP_ID='1'*32
CONFIG={'coordinator_role_arn':'arn:aws:iam::210987654321:role/EcaiCoordinator',
        'worker_image':'public.ecr.aws/example/ecai-worker@sha256:'+'a'*64,
        'worker_command':['/opt/ecai/run-index-worker'],'regions':['ap-southeast-2','us-east-1'],'probe_enabled':True}
PLAN=make_plan({'operation_id':OP_ID,'account_id':'123456789012','region':'ap-southeast-2','external_id':'a'*48,'config':CONFIG,'options':{}})
SCRIPT=(APP/'priv/static/js/ecai-aws-setup.js').read_text()
CSS='\n'.join((APP/'priv/static/css'/p).read_text() for p in ['ecai-console.css','ecai-compute-settings.css','ecai-aws-setup.css'])
FRAGMENT=(APP/'priv/templates/ui/dashboard/compute_settings.mustache').read_text()
FRAGMENT=FRAGMENT.replace('class="view" data-compute-ui-version=', 'class="view is-visible" data-compute-ui-version=',1)
FRAGMENT=FRAGMENT.replace('aria-labelledby="computeTitle" hidden>', 'aria-labelledby="computeTitle">',1)
BOOT='''
window.testToken='test-bearer-A'; window.apiCalls=[]; window.fakeSession=null; window.fixtureError=null; window.delayed=null;
window.fakeConfig={enabled:true,ready:true,blockers:[],regions:['ap-southeast-2','us-east-1'],probe_enabled:true};
window.fakeOperation=null;
window.fakePlan=PLAN_JSON;
window.fakeRequest=async(path,opts={})=>{
 window.apiCalls.push({path,opts:JSON.parse(JSON.stringify(opts))});
 if(window.delayed){const d=window.delayed;window.delayed=null;await d.promise;}
 if(window.fixtureError){const e=window.fixtureError;window.fixtureError=null;throw Object.assign(new Error(e),{body:{error:e}});}
 let data;
 if(path.endsWith('/connect')){
  data=window.fakeSession={session_id:'s'.repeat(32),region:opts.body.region,expires_at_ms:Date.now()+900000,identity:{account_id:'123456789012',caller_arn:'arn:aws:iam::123456789012:user/Setup'}};
 } else if(path.endsWith('/disconnect')) { window.fakeSession=null;data={credentials_discarded:true};
 } else if(path.endsWith('/plan')) {
  data=window.fakeOperation={id:'1'.repeat(32),account_id:'123456789012',region:'ap-southeast-2',status:'planned',busy:false,created_at_ms:Date.now(),runtime_status:'unchecked',credential_session_active:true,replaces_provider:false,plan:window.fakePlan,events:[],last_error:null};
 } else if(path.endsWith('/discard')) {window.fakeOperation.status='discarded';data=window.fakeOperation;
 } else if(path.endsWith('/deploy')) {
  window.fakeOperation.status='deploying';window.fakeOperation.intent='deploy';window.fakeOperation.busy=true;data=window.fakeOperation;
 } else if(path.endsWith('/verify')) {window.fakeOperation.runtime_status='verified';data=window.fakeOperation;
 } else if(path.endsWith('/probe-status')) {window.fakeOperation.probe={probe_id:'b'.repeat(32),job_id:'mock-batch-job',status:'VERIFIED'};data=window.fakeOperation;
 } else if(path.endsWith('/probe')) {window.fakeOperation.probe={probe_id:'b'.repeat(32),job_id:'mock-batch-job',status:'SUBMITTED'};data=window.fakeOperation;
 } else if(path.endsWith('/delete')) {window.fakeOperation.status='deleting';data=window.fakeOperation;
 } else if(path==='/ecai/compute/aws/setup') {data={config:window.fakeConfig,operations:window.fakeOperation?[window.fakeOperation]:[],session:window.fakeSession};
 } else if(path.endsWith('/'+'1'.repeat(32))) {data=window.fakeOperation;
 } else throw new Error('Unexpected fixture route '+path);
 return {ok:true,data:structuredClone(data)};
};
window.EcaiAwsSetup.init({request:window.fakeRequest,currentToken:()=>window.testToken,openLogin:()=>{},toast:()=>{}});
window.fixtureReady=window.EcaiAwsSetup.refresh();
'''.replace('PLAN_JSON',json.dumps(PLAN))

def html_page(dom_only=False):
    script=('if (!crypto.randomUUID) crypto.randomUUID=()=>\"00000000-0000-4000-8000-000000000001\";'+'((location)=>{'+SCRIPT+'})({protocol:"https:"});') if dom_only else SCRIPT
    return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+CSS+'</style></head><body><main class="console-main">'+FRAGMENT+'</main><script>'+script+'</script><script>'+BOOT+'</script></body></html>'

class WizardBrowser(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pw=sync_playwright().start()
        executable=os.environ.get('ECAI_CHROMIUM') or shutil.which('chromium') or shutil.which('chromium-browser')
        cls.browser=cls.pw.chromium.launch(headless=True,args=['--no-sandbox','--disable-dev-shm-usage'],**({'executable_path':executable} if executable else {}))
    @classmethod
    def tearDownClass(cls): cls.browser.close();cls.pw.stop()
    def setUp(self):self.contexts=[];self.errors=[]
    def tearDown(self):
        for c in self.contexts:c.close()
        self.assertEqual(self.errors,[])
    def page(self,width=1200,scheme='dark'):
        context=self.browser.new_context(viewport={'width':width,'height':1050},color_scheme=scheme)
        self.contexts.append(context);page=context.new_page();page.set_default_timeout(5000)
        page.on('pageerror',lambda e:self.errors.append(str(e)))
        page.on('dialog',lambda d:d.accept())
        if DOM_ONLY:
            page.route('**/*',lambda r:r.abort())
            page.set_content(html_page(True))
        else:
            page.route('https://ecai-setup.test/**',lambda r:r.fulfill(status=200,content_type='text/html',body=html_page()))
            page.goto('https://ecai-setup.test/dashboard')
        page.evaluate('window.fixtureReady')
        return page
    def connect(self,page):
        page.locator('#awsSetupAccessKey').fill('AKIA'+'A'*16)
        page.locator('#awsSetupSecretKey').fill('S'*40)
        page.locator('#awsSetupConnect').click()
        page.wait_for_function('!document.getElementById("awsSetupPlanFields").disabled')
    def plan(self,page):
        self.connect(page);page.locator('#awsSetupPlan').click()
        page.wait_for_function('!document.getElementById("awsSetupOperation").hidden')
    def test_initial_page_does_not_send_credentials_or_create_resources(self):
        page=self.page()
        self.assertEqual(page.evaluate('apiCalls.map(c=>c.opts.method||"GET")'),['GET'])
        self.assertTrue(page.locator('#awsSetupPlanFields').evaluate('(el)=>el.disabled'))
        self.assertTrue(page.locator('#computeAwsManual').is_visible())
        self.assertFalse(page.locator('#computeAwsManual').get_attribute('open'))
    def test_connect_clears_inputs_and_plan_requires_explicit_approval(self):
        page=self.page();self.plan(page)
        self.assertEqual(page.locator('#awsSetupAccessKey').input_value(),'')
        self.assertEqual(page.locator('#awsSetupSecretKey').input_value(),'')
        self.assertEqual(page.locator('#awsSetupSessionToken').input_value(),'')
        self.assertTrue(page.locator('#awsSetupDeploy').is_disabled())
        self.assertEqual(page.evaluate('apiCalls.filter(c=>c.path.endsWith("/deploy")).length'),0)
        page.locator('#awsSetupAcknowledge').check();page.locator('#awsSetupDeploy').click()
        page.wait_for_function('fakeOperation.status==="deploying"')
        self.assertTrue(page.locator('#awsSetupDeploy').is_disabled())
        body=page.evaluate('apiCalls.find(c=>c.path.endsWith("/deploy")).opts.body')
        self.assertEqual(body['plan_sha256'],PLAN['plan_sha256'])
        self.assertTrue(body['acknowledge_costs_and_iam'])
        self.assertNotIn('credentials',body)
    def test_unused_plan_can_be_discarded_without_aws_authorization(self):
        page=self.page();self.plan(page)
        page.locator('#awsSetupDiscard').click()
        page.wait_for_function('fakeOperation.status==="discarded"')
        self.assertTrue(page.locator('#awsSetupDeploy').is_disabled())
        self.assertEqual(page.evaluate('apiCalls.find(c=>c.path.endsWith("/discard")).opts.body'),{})
        self.assertEqual(page.evaluate('apiCalls.filter(c=>c.path.endsWith("/deploy")).length'),0)
    def test_failure_clears_credentials_and_surfaces_safe_error(self):
        page=self.page();page.evaluate('window.fixtureError="AccessDenied"')
        page.locator('#awsSetupAccessKey').fill('AKIA'+'A'*16);page.locator('#awsSetupSecretKey').fill('S'*40)
        page.locator('#awsSetupConnect').click()
        page.wait_for_function('document.getElementById("awsSetupNotice").dataset.error==="true"')
        self.assertIn('AWS denied',page.locator('#awsSetupNotice').inner_text())
        self.assertEqual(page.locator('#awsSetupSecretKey').input_value(),'')
        self.assertTrue(page.locator('#awsSetupPlanFields').evaluate('(el)=>el.disabled'))
    def test_temporary_key_requires_token_before_request(self):
        page=self.page();page.locator('#awsSetupAccessKey').fill('ASIA'+'A'*16);page.locator('#awsSetupSecretKey').fill('S'*40)
        page.locator('#awsSetupConnect').click()
        self.assertIn('session token',page.locator('#awsSetupNotice').inner_text())
        self.assertEqual(page.evaluate('apiCalls.filter(c=>c.opts.method==="POST").length'),0)
    def test_pending_response_cannot_refill_another_account(self):
        page=self.page()
        page.evaluate('window.delayed={};delayed.promise=new Promise(r=>window.releaseCall=r);void 0')
        page.locator('#awsSetupAccessKey').fill('AKIA'+'A'*16);page.locator('#awsSetupSecretKey').fill('S'*40);page.locator('#awsSetupConnect').click()
        page.evaluate('window.testToken="test-bearer-B";EcaiAwsSetup.clear();window.releaseCall()')
        page.wait_for_timeout(100)
        self.assertEqual(page.locator('#awsSetupSecretKey').input_value(),'')
        self.assertTrue(page.locator('#awsSetupPlanFields').evaluate('(el)=>el.disabled'))
        self.assertNotIn('123456789012',page.locator('#awsSetupIdentity').inner_text())
    def test_disconnect_resumes_without_persisting_secrets_in_browser(self):
        page=self.page();self.connect(page);page.locator('#awsSetupDisconnect').click()
        page.wait_for_function('!document.getElementById("awsSetupCredentialFields").disabled')
        self.assertIn('not been revoked',page.locator('#awsSetupNotice').inner_text())
        self.assertTrue(page.locator('#awsSetupPlanFields').evaluate('(el)=>el.disabled'))
    def test_probe_and_delete_are_separately_gated(self):
        page=self.page();self.plan(page)
        page.evaluate('fakeOperation.status="deployed";fakeOperation.runtime_status="verified"')
        page.evaluate('EcaiAwsSetup.refresh()')
        self.assertTrue(page.locator('#awsSetupProbe').is_disabled())
        page.locator('summary',has_text='Optional paid verification job').click()
        page.locator('#awsSetupProbeConsent').check();page.locator('#awsSetupProbe').click()
        page.wait_for_function('fakeOperation.probe?.status==="SUBMITTED"')
        self.assertTrue(page.locator('#awsSetupProbe').is_disabled())
        page.locator('summary',has_text='Remove environment').click()
        page.locator('#awsSetupDeleteName').fill(PLAN['stack_name']);page.locator('#awsSetupRetain').check()
        self.assertTrue(page.locator('#awsSetupDelete').is_disabled())
        page.locator('#awsSetupProbeStatus').click();page.wait_for_function('fakeOperation.probe?.status==="VERIFIED"')
        self.assertTrue(page.locator('#awsSetupDelete').is_enabled())
        page.locator('#awsSetupDelete').click();page.wait_for_function('fakeOperation.status==="deleting"')
    def test_layout_light_dark_and_narrow_viewports(self):
        folder=os.environ.get('ECAI_AWS_SCREENSHOTS')
        for scheme in ['light','dark']:
            for width in [1200,945,390,320]:
                with self.subTest(scheme=scheme,width=width):
                    page=self.page(width,scheme)
                    self.assertLessEqual(page.evaluate('document.documentElement.scrollWidth'),width+1)
                    self.assertTrue(page.locator('#awsSetupConnect').is_visible())
                    if folder and width in (1200,390):
                        dest=Path(folder);dest.mkdir(parents=True,exist_ok=True)
                        page.locator('#awsSetupPanel').screenshot(path=str(dest/f'ecai-automatic-aws-{scheme}-{width}.png'))
                    page.close()

if __name__=='__main__':unittest.main(verbosity=2)
