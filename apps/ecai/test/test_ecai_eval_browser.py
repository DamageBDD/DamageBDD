#!/usr/bin/env python3
"""Real Chromium component tests with synthetic, in-browser API responses.

These execute the shipped templates/CSS/JavaScript logic in an in-memory DOM,
NOT Cowboy, OAuth, DETS, Erlang graders, ES-module loading, or model endpoints.
The exported function declaration is loaded into the fixture scope; Node checks
the actual ES-module syntax separately. No browser network access is needed. Install playwright and its Chromium browser,
or set ECAI_EVAL_CHROMIUM to an installed Chromium executable.
Run from the umbrella root: python3 apps/ecai/test/test_ecai_eval_browser.py
Optional screenshots: ECAI_EVAL_SCREENSHOTS=/path/to/output
"""
from __future__ import annotations
import json
import os
from pathlib import Path
import re
import unittest
from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[3]
ECAI = ROOT / "apps/ecai/priv"
DAMAGE = ROOT / "apps/damage/priv"

FIXTURE_JS = r'''
const preferences={enabled:true,remote_consent:false,target_ids:['local'],repetitions:1,max_output_tokens:256,daily_calls:50,pass_bps:9500,knowledge_mode:'none',retrieval_k:4};
const node_policy={enabled:true,allow_remote:false,target_ids:['local'],max_parallel:2,max_parallel_per_account:1,max_queued_runs:64,max_account_runs:100,max_account_suites:50,max_cases:100,max_repetitions:5,max_run_calls:500,daily_calls:1000,node_daily_calls:10000,max_output_tokens:2048,max_prompt_bytes:32768,max_response_bytes:131072,timeout_ms:120000,min_pass_bps:9500,min_reviewers:1,retention_days:30};
const s={version:7,preferences,node_policy,effective:{...preferences},daily_reserved_calls:3,targets:[{id:'local',model:'fixture-model',remote:false}],target_error:null};
const suite={id:'suite-001',name:'Synthetic dialogue <img src=x onerror="window.XSS=1">',version:'1',cases:2,approvals:['alice'],coverage:{'dialogue / grounding / test':2}};
const target={planned:2,counts:{pass:1,fail:1},pass_bps:5000,critical_failures:1,release_gate:false,p95_latency_ms:180};
const report={...target,complete:true,run_id:'run-001',suite_id:suite.id,targets:{local:target},
 cases:[{id:'task-1',case_id:'policy-window',target_id:'local',repetition:1,domain:'dialogue',dimension:'grounding',status:'pass',failed_checks:[]},
 {id:'task-2',case_id:'unauthorized-tool',target_id:'local',repetition:1,domain:'dialogue',dimension:'tool policy',status:'fail',failed_checks:[{id:'tools',type:'tool_allowlist',reason:'assertion_mismatch'}]}],
 slices:{'local / dialogue / grounding':target},recommendations:[{failure_type:'tool_allowlist',recommendation:'Enforce permissions outside the model.'}],human_review:{disagreement_trials:1},cost:{amount:null,reason:'No authoritative billing data.'}};
const run={id:'run-001',suite_id:suite.id,created_at_ms:1792281600000,cancelled:false,split:'test',...target};
window.fixture={managed:true,admin:true,token:'fixture-alice',calls:[],delaySettings:0,failRun:false,settings:s,runs:[run],suite,reviewed:false};
window.XSS=0;
async function fixtureRequest(path,options={}) {
 const f=window.fixture, body=typeof options.body==='string'?JSON.parse(options.body):options.body;
 f.calls.push({path,body,token:f.token});
 const out=x=>({ok:true,data:structuredClone(x)});
 if(path==='/ecai/eval/settings'){
   const copy=structuredClone(f.settings);
   if(body){if(body.version!==f.settings.version){const e=new Error('version_conflict');e.status=409;e.body={error:'version_conflict'};throw e;}
     f.settings.preferences={...f.settings.preferences,...body.changes};f.settings.effective={...f.settings.preferences};f.settings.version++;return out(f.settings);}
   if(f.delaySettings)await new Promise(r=>setTimeout(r,f.delaySettings));return out(copy);
 }
 if(path==='/ecai/eval/admin/settings'){
   if(body)Object.entries(body.changes).forEach(([k,v])=>f.settings.node_policy[k.replace(/^eval_/,'')]=v);
   return out({version:11,fields:Object.entries(f.settings.node_policy).map(([name,value])=>({name:'eval_'+name,label:name.replaceAll('_',' '),value,type:Array.isArray(value)?'string_list':typeof value==='number'?'integer':typeof value,default:value}))});
 }
 if(path==='/ecai/eval/suites')return body?out({id:'new-suite',name:body.name}):out([f.suite]);
 if(path==='/ecai/eval/suites/suite-001')return out({source:{name:f.suite.name},spec:{description:'SECRET_FIXTURE_SOURCE'}});
 if(path.endsWith('/approve'))return out({recorded:true});
 if(path==='/ecai/eval/runs'){
   if(body){if(f.failRun){f.failRun=false;const e=new Error('Submission result unknown');e.status=503;e.body={error:'result_unknown_do_not_retry_with_new_key'};throw e;}return out(run);}
   return out(f.runs);
 }
 if(path==='/ecai/eval/runs/run-001')return out({run,report});
 if(path.includes('/attempts/'))return out({state:'done',response:'<img src=x onerror="window.XSS=1"> SECRET_FIXTURE_TRIAL',grade:{status:'fail'}});
 if(path.endsWith('/cancel'))return out({cancelled:true});
 if(path.endsWith('/evidence'))return out({manifest_bytes:'{}',sha256:'fixture-not-a-real-receipt',signed:false});
 if(path==='/ecai/eval/review-queue')return out({items:f.reviewed?[]:[{kind:'attempt',owner:'alice',id:'run-001',task_id:'task-2'}],total:f.reviewed?0:1});
 if(path==='/ecai/eval/review-detail')return out({case:{rubric:{instruction:'Use the anchored rubric'}},attempt:{response:'Synthetic review response'}});
 if(path==='/ecai/eval/review'){f.reviewed=true;return out({recorded:true});}
 if(path==='/ecai/eval/compare')return out({pairs:2,counts:{both_pass:1,candidate_regression:1}});
 throw new Error('Unhandled fixture route '+path);
}
'''

def fixture_parts(damage: bool = False):
    if damage:
        template = (DAMAGE / 'templates/ui/dashboard/settings_tab.mustache').read_text()
        template = re.search(r'<section class="workspace-card account-settings-card" aria-labelledby="account-evaluation-title">.*?</section>', template, re.S).group()
        logic = (DAMAGE / 'static/js/evaluation-account-settings.js').read_text().replace('export function ', 'function ', 1)
        boot = """window.workspace=initEvaluationAccountSettings({api:fixtureRequest,getToken:()=>fixture.token,session:()=>({mode:fixture.managed?'custodial':'non_custodial'})});
await workspace.refresh();window.ready=true;"""
    else:
        template = (ECAI / 'templates/ui/dashboard/ecai_eval.mustache').read_text()
        logic = (ECAI / 'static/js/ecai-eval.js').read_text().replace('export function ', 'function ', 1)
        boot = """const root=document.querySelector('[data-panel="evaluation"]');root.hidden=false;root.classList.add('is-visible');
window.workspace=initEvaluation({request:fixtureRequest,currentToken:()=>fixture.token,managedSession:()=>fixture.managed,isAdmin:()=>fixture.admin,openLogin:()=>{fixture.loginOpened=true}});
await workspace.refresh();window.ready=true;"""
    css = (ECAI / 'static/css/ecai-console.css').read_text() + (ECAI / 'static/css/ecai-eval.css').read_text()
    html = f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>{css}</style><style>main{{max-width:1200px;margin:auto;padding:24px;min-width:0}}@media(max-width:560px){{main{{padding:12px}}}}</style>
<title>ECAI evaluation component fixture — synthetic data</title></head><body><main><p class="context-hint">COMPONENT PREVIEW · SYNTHETIC FIXTURE DATA · NOT MEASURED MODEL PERFORMANCE</p>{template}</main></body></html>'''
    samples = {f'/static/eval/{name}.json':json.loads((ECAI / f'static/eval/{name}.json').read_text()) for name in ('dialogue','paper-trading')}
    mock_fetch = 'const samples='+json.dumps(samples)+';window.fetch=async(url)=>new Response(JSON.stringify(samples[url]),{status:samples[url]?200:404});'
    return html, 'async()=>{'+FIXTURE_JS+'\n'+mock_fetch+'\n'+logic+'\n'+boot+'}'

class EvaluationBrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pw = sync_playwright().start()
        executable = os.environ.get('ECAI_EVAL_CHROMIUM')
        cls.browser = cls.pw.chromium.launch(headless=True, args=['--no-sandbox'], **({'executable_path': executable} if executable else {}))
    @classmethod
    def tearDownClass(cls):
        cls.browser.close(); cls.pw.stop()
    def setUp(self):
        self.page = self.browser.new_page(viewport={'width':1360, 'height':1000})
        self.errors=[]; self.page.on('pageerror', lambda e: self.errors.append(str(e)))
        self.load()
    def load(self, damage=False):
        html, logic = fixture_parts(damage)
        self.page.evaluate('window.workspace?.dispose?.()')
        self.page.set_content(html)
        self.page.evaluate(logic)
        self.page.wait_for_function('window.ready===true')
    def tearDown(self):
        self.page.close(); self.assertEqual([], self.errors, 'Uncaught browser errors')
    def tab(self, name):
        self.page.locator(f'[data-eval-tab="{name}"]').click()
    def calls(self, path):
        return self.page.evaluate('(path)=>fixture.calls.filter(c=>c.path===path&&c.body)', path)
    def open_run(self):
        self.page.locator('#evalRunList button').click(); expect(self.page.locator('#evalReportPanel')).to_be_visible()
    def test_managed_workspace_and_operator_policy(self):
        expect(self.page.locator('#evalWorkspace')).to_be_visible()
        expect(self.page.locator('#evalNodeTab')).to_be_visible()
        self.tab('node'); expect(self.page.locator('#evalNodeFields label')).to_have_count(20)
        self.page.locator('#eval-field-node-eval_max_parallel').fill('3')
        self.page.locator('#evalNodeForm button[type=submit]').click()
        expect(self.page.locator('#evalStatus')).to_contain_text('Node policy saved')
        c=self.calls('/ecai/eval/admin/settings')[-1]
        self.assertEqual(11,c['body']['version']); self.assertEqual(3,c['body']['changes']['eval_max_parallel'])
        self.assertNotIn('owner',c['body'])
    def test_account_preference_types_and_version(self):
        self.tab('account'); self.page.locator('#eval-field-daily_calls').fill('7')
        self.page.locator('#eval-field-remote_consent').check()
        self.page.locator('#evalAccountForm button').click()
        expect(self.page.locator('#evalStatus')).to_contain_text('Account settings saved')
        c=self.calls('/ecai/eval/settings')[-1]
        self.assertEqual(7,c['body']['version']); self.assertEqual(7,c['body']['changes']['daily_calls'])
        self.assertIs(c['body']['changes']['remote_consent'],True)
        self.assertEqual(['local'],c['body']['changes']['target_ids'])
    def test_unknown_submit_reuses_idempotency_key(self):
        key=self.page.locator('#evalRunKey').input_value()
        self.page.evaluate('fixture.failRun=true')
        self.page.locator('#evalRunSubmit').click()
        expect(self.page.locator('#evalStatus')).to_contain_text('result_unknown')
        self.assertEqual(key,self.page.locator('#evalRunKey').input_value())
        self.page.locator('#evalRunSubmit').click()
        expect(self.page.locator('#evalStatus')).to_contain_text('admitted')
        self.assertEqual([key,key],[c['body']['idempotency_key'] for c in self.calls('/ecai/eval/runs')])
        self.assertNotEqual(key,self.page.locator('#evalRunKey').input_value())
    def test_report_filters_and_untrusted_text(self):
        self.open_run()
        expect(self.page.locator('#evalGate')).to_have_text('Gate blocked')
        expect(self.page.locator('#evalCases tbody tr')).to_have_count(2)
        self.page.locator('#evalOutcomeFilter').select_option('not_pass')
        expect(self.page.locator('#evalCases tbody tr')).to_have_count(1)
        self.page.locator('#evalCases button').click()
        expect(self.page.locator('#evalTrial')).to_contain_text('SECRET_FIXTURE_TRIAL')
        self.assertEqual(0,self.page.locator('#evalTrial img').count())
        self.assertEqual(0,self.page.evaluate('window.XSS'))
    def test_synthetic_dataset_import_does_not_auto_approve(self):
        self.tab('datasets'); self.page.locator('#evalLoadDialogue').click()
        expect(self.page.locator('#evalStatus')).to_contain_text('Synthetic example loaded')
        obj=json.loads(self.page.locator('#evalDatasetInput').input_value()); self.assertEqual(6,len(obj['cases']))
        self.page.locator('#evalImportForm button').click()
        expect(self.page.locator('#evalStatus')).to_contain_text('Annotation approval is required')
        self.assertEqual([],self.calls('/ecai/eval/suites/new-suite/approve'))
        self.assertEqual(0,self.page.locator('#evalSuiteList img').count())
    def test_independent_review_submission(self):
        self.tab('reviews'); self.page.locator('#evalReviewList button').click()
        expect(self.page.locator('#evalReviewDetail')).to_contain_text('anchored rubric')
        self.page.locator('#evalReviewVerdict').select_option('indeterminate')
        self.page.locator('#evalReviewNote').fill('The rubric does not settle this ambiguity.')
        self.page.locator('#evalReviewForm button').click()
        expect(self.page.locator('#evalStatus')).to_contain_text('Review recorded')
        c=self.calls('/ecai/eval/review')[-1]['body']
        self.assertEqual('indeterminate',c['verdict']);self.assertEqual('alice',c['owner'])
        self.assertNotIn('reviewer',c)
    def test_auth_change_clears_data_and_late_responses(self):
        self.open_run(); self.page.locator('#evalCases button').first.click()
        expect(self.page.locator('#evalTrial')).to_contain_text('SECRET_FIXTURE_TRIAL')
        self.page.evaluate('fixture.delaySettings=180; window.pending=workspace.refresh().catch(()=>{}); fixture.managed=false;fixture.admin=false;fixture.token=null;workspace.reset();')
        self.page.evaluate('window.pending')
        expect(self.page.locator('#evalAccess')).to_be_visible()
        self.assertNotIn('SECRET_FIXTURE_TRIAL',self.page.locator('body').inner_text())
        expect(self.page.locator('#evalRunList')).to_be_empty();expect(self.page.locator('#evalAccountFields')).to_be_empty()
    def test_nonadmin_cannot_see_node_controls(self):
        self.tab('node'); expect(self.page.locator('#evalNodeFields label')).to_have_count(20)
        self.page.evaluate('fixture.admin=false;fixture.token="fixture-bob";workspace.reset();')
        self.page.evaluate('workspace.refresh()')
        expect(self.page.locator('#evalNodeTab')).to_be_hidden();expect(self.page.locator('#evalNodeFields')).to_be_empty()
    def test_version_conflict_is_visible(self):
        self.tab('account');self.page.evaluate('fixture.settings.version=99')
        self.page.locator('#evalAccountForm button').click()
        expect(self.page.locator('#evalStatus')).to_contain_text('version_conflict')
    def test_mobile_layout_and_screenshots(self):
        self.page.evaluate('fixture.suite.name="Synthetic dialogue acceptance"')
        self.page.evaluate('workspace.refresh()')
        self.open_run()
        out=os.environ.get('ECAI_EVAL_SCREENSHOTS')
        if out:
            Path(out).mkdir(parents=True,exist_ok=True)
            self.page.screenshot(path=str(Path(out)/'evaluation-desktop.png'), full_page=True)
        self.page.set_viewport_size({'width':390,'height':844})
        overflow=self.page.evaluate('document.documentElement.scrollWidth>window.innerWidth')
        self.assertFalse(overflow,'Page-level horizontal overflow at 390px')
        if out:self.page.screenshot(path=str(Path(out)/'evaluation-mobile.png'),full_page=True)
    def test_damage_account_settings_and_logout(self):
        self.load(damage=True)
        expect(self.page.locator('#account-evaluation-save')).to_be_enabled()
        self.page.locator('#account-evaluation-fields [name=daily_calls]').fill('9')
        self.page.locator('#account-evaluation-save').click()
        expect(self.page.locator('#account-evaluation-status')).to_contain_text('preferences saved')
        self.assertEqual(9,self.calls('/ecai/eval/settings')[-1]['body']['changes']['daily_calls'])
        self.page.evaluate('fixture.managed=false;fixture.token=null;document.dispatchEvent(new Event("auth:changed"))')
        expect(self.page.locator('#account-evaluation-fields')).to_be_empty()
        expect(self.page.locator('#account-evaluation-save')).to_be_disabled()

if __name__=='__main__':unittest.main(verbosity=2)
