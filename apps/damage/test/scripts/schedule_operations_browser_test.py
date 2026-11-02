#!/usr/bin/env python3
"""Production dashboard scripts in Chromium with isolated API/wallet fixtures.
No external requests, signing, chain calls or spending.
"""
import argparse
import asyncio
import json
import re
from pathlib import Path
from playwright.async_api import async_playwright
from schedule_templates_browser_test import APP, HTML, CATALOG

async def run(args):
    out=Path(args.out);out.mkdir(parents=True,exist_ok=True)
    calls=[];errors=[];checks=[]
    op_id='sop_'+('a'*64)
    state={'op':None,'schedules':[], 'lose_read':False}
    def check(name, condition):
        assert condition, name
        checks.append(name)
    async with async_playwright() as p:
        browser=await p.chromium.launch(executable_path=args.chromium,headless=True,args=['--no-sandbox'])
        page=await browser.new_page(viewport={'width':1280,'height':1000})
        page.on('pageerror',lambda e:errors.append(str(e)))
        async def api(req):
            path=req['url'].split('?',1)[0];method=req['method'];data=req['data']
            calls.append({'path':path,'method':method})
            assert req['headers'].get('authorization')=='Bearer fixture-token'
            def response(body,code=200):return {'body':body,'code':code}
            if path.endswith('/templates'):return response({'status':'ok','data':CATALOG})
            if path.endswith('/status'):return response({'status':'ok','custodial':True})
            if path.endswith('/analytics'):return response({'status':'ok','data':{'summary':{},'buckets':[]}})
            if path.endswith('/preview'):
                return response({'status':'ok','dry_run':{'cost_per_run':100},'window':{'occurrences':24},'budget':{'estimated':2400,'recommended_lock':3000,'max_cost_per_run':115,'safety_percent':15}})
            if path=='/api/schedules/v2' and method=='POST':
                state['op']={'operation_id':op_id,'kind':'create','status':'running','stage':'create_schedule','schedule_id':'sv2_fixture'}
                state['draft']=data
                return response(state['op'],202)
            if path=='/api/schedules/v2':return response({'status':'ok','data':state['schedules']})
            if path=='/api/schedules/v2/operations':return response({'status':'ok','data':[state['op']] if state['op'] else []})
            if path=='/api/schedules/v2/operations/'+op_id:
                if state['lose_read']:
                    state['lose_read']=False
                    raise RuntimeError('fixture: lost observation response')
                return response(state['op'],202 if state['op']['status']=='running' else 200)
            raise AssertionError('Unexpected fixture API '+path)
        await page.expose_function('__fixtureFetch',api)
        css=(APP/'priv/static/css/schedules-v2.css').read_text()
        sources=[]
        for name in ['schedule-templates.js','schedule-operations.js','schedules-v2.js']:
            source=(APP/'priv/static/js'/name).read_text()
            sources.append(re.sub(r'^import .*?;\n','',source,flags=re.M).replace('export ',''))
        bootstrap="""
window.ready=false;
window.fetch=async (url,options={})=>{
 const r=await window.__fixtureFetch({url:String(url),method:options.method||'GET',
 data:options.body?JSON.parse(options.body):null,headers:Object.fromEntries(new Headers(options.headers||{}))});
 return new Response(JSON.stringify(r.body),{status:r.code,headers:{'content-type':'application/json'}});
};
const wallet={signTransactionSmart:async()=>{throw new Error('No fixture wallet signing');}};
"""
        script=bootstrap+'\n'.join(sources)+'\nwindow.refreshSchedules=updateSchedulesTable; await updateSchedulesTable(); window.ready=true;'
        html=re.sub(r'<script type="module">.*?</script>',lambda _:'<script type="module">'+script+'</script>',HTML,flags=re.S)
        html=html.replace('</head>','<style>'+css+'</style><link href="/static/css/schedules-v2.css"></head>')
        await page.set_content(html);await page.wait_for_function('window.ready===true')
        check('mount performs no mutation',not any(c['method']=='POST' for c in calls))
        await page.locator('#sv2-new').click()
        await page.locator('#sv2-feature').fill('Feature: Fixture\nScenario: Fixture\nGiven no live traffic\n')
        await page.locator('#sv2-preview').click()
        await page.wait_for_function('!document.getElementById("sv2-create").disabled')
        state['lose_read']=True
        await page.locator('#sv2-create').evaluate('(b)=>{b.click();b.click();}')
        await page.wait_for_function('document.getElementById("sv2-create-error").textContent.includes("Processing create_schedule")')
        check('pending creation disables duplicate clicks',await page.locator('#sv2-create').is_disabled())
        check('202 acknowledgement is not activation',len(state['schedules'])==0 and 'success' not in await page.locator('#sv2-toast').get_attribute('class'))
        await page.wait_for_function('document.getElementById("sv2-modal").hidden',timeout=6000)
        await page.locator('[data-operation]').wait_for()
        check('lost response retains recoverable operation',op_id in await page.locator('#sv2-operations').inner_text())
        posts=lambda:sum(c['method']=='POST' and c['path']=='/api/schedules/v2' for c in calls)
        check('lost response never reposts creation',posts()==1)
        check('lost response reports pending, not success','Creation pending' in await page.locator('#sv2-toast').inner_text())
        state['op'].update(status='reconciliation_required',stage='fund_schedule',error='confirmation_timeout',tx_hash='th_N2BiyrJ5aKHpBY6vQt9MYY22iRv4FCNBqG8WUXoCWiFbL3xe3')
        await page.evaluate('window.refreshSchedules()')
        text=await page.locator('#sv2-operations').inner_text()
        check('reconciliation names phase and transaction','fund_schedule' in text and state['op']['tx_hash'] in text)
        check('reconciliation warns against replacement','Do not create or fund a replacement' in text)
        check('uncertain write has no continue-to-fund button',await page.locator('[data-operation]').count()==0)
        await page.screenshot(path=str(out/'schedule-reconciliation-desktop.png'),full_page=True)
        await page.set_viewport_size({'width':390,'height':844})
        check('long operation ids fit mobile viewport',await page.evaluate('document.documentElement.scrollWidth<=window.innerWidth+1'))
        await page.screenshot(path=str(out/'schedule-reconciliation-mobile.png'),full_page=True)
        # A new mount sees the same server journal without issuing any mutations.
        await page.set_content(html);await page.wait_for_function('window.ready===true')
        check('reload recovers server-side pending metadata',op_id in await page.locator('#sv2-operations').inner_text() and posts()==1)
        # This fixture changes the server outcome; it does NOT implement reconciliation.
        state['op'].update(status='running');state['op'].pop('error');state['op'].pop('tx_hash')
        await page.evaluate('window.refreshSchedules()')
        await page.locator('[data-operation]').click()
        d=state['draft'];schedule={'id':'sv2_fixture','status':'active','feature_title':'Feature: Fixture','feature_hash':'fixture_hash',
            'cron_spec':d['cron_spec'],'start_at':d['start_at'],'end_at':d['end_at'],'funded':d['lock_amount'],'remaining':d['lock_amount'],'max_cost_per_run':115}
        state['schedules']=[schedule];state['op'].update(status='complete',result=schedule)
        await page.locator('#sv2-list [data-id="sv2_fixture"]').wait_for(timeout=6000)
        check('observed completion unlocks success display','completed' in await page.locator('#sv2-toast').inner_text())
        check('continue uses reads, not a second creation',posts()==1)
        check('no JavaScript runtime errors',not errors)
        (out/'operation-browser-results.json').write_text(json.dumps({'result':'PASS','checks':checks,'count':len(checks),'errors':errors,'calls':calls},indent=2))
        print(f'PASS: {len(checks)} operation browser checks; simulated API only.')
        await browser.close()

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--out',default='/tmp/schedule-operation-ui');parser.add_argument('--chromium',default='/usr/bin/chromium')
    asyncio.run(run(parser.parse_args()))
