#!/usr/bin/env python3
"""Real Chromium, production JS/CSS, simulated authenticated APIs; no live probes.
Run: python3 apps/damage/test/scripts/schedule_templates_browser_test.py --out /tmp/schedule-ui
Requires Python playwright and Chromium (or --chromium path).
"""
import argparse
import asyncio
import json
import re
from pathlib import Path
from playwright.async_api import async_playwright

APP = Path(__file__).resolve().parents[2]
CATALOG = json.loads((APP / 'test/fixtures/schedule-templates/catalog.json').read_text())
HTML = '''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Schedule starter checks — fixture preview</title><style>body{margin:0;padding:24px;background:#0c111b;color:#eef3fa;font-family:system-ui,sans-serif}*{box-sizing:border-box}.fixture-banner{font-size:12px;color:#a7b6c9;margin-bottom:12px}#schedules-tab{max-width:1440px;margin:auto}button,input,textarea,select{font:inherit} [hidden]{display:none!important}</style></head>
<body class="damage-dashboard"><div class="fixture-banner">INTERACTIVE FIXTURE · API responses are simulated. No target requests or wallet transactions.</div>
<section id="schedules-tab"><div class="schedules-v2-root" data-schedules-v2-root></div></section>
<script>window.TokenManager={getToken:()=>"fixture-token"};</script>
<script type="module">import {updateSchedulesTable} from '/static/js/schedules-v2.js'; window.refreshSchedules=updateSchedulesTable; await updateSchedulesTable(); window.ready=true;</script></body></html>'''

async def run(args):
    out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
    state = dict(calls=[], schedules=[], delay=0, render_delay=0, catalog_error=False, create_error=False)
    errors=[]
    async with async_playwright() as p:
        browser = await p.chromium.launch(executable_path=args.chromium, headless=True, args=['--no-sandbox'])
        context = await browser.new_context(viewport=dict(width=1440,height=1100), timezone_id='Australia/Sydney')
        page = await context.new_page()
        page.on('pageerror', lambda e: (errors.append(str(e)), print('PAGE ERROR:', e, flush=True)))
        async def api_handler(request):
            path=request['url'].split('?',1)[0]
            def reply(body, code=200): return dict(body=body,code=code)
            data=request['data']
            state['calls'].append(dict(path=path,method=request['method'],data=data))
            assert request['headers'].get('authorization')=='Bearer fixture-token'
            if path=='/api/schedules/v2/templates':
                if state['catalog_error']: return reply(dict(status='notok',error='catalogue unavailable'),503)
                else: return reply(dict(status='ok',data=CATALOG))
            elif path=='/api/schedules/v2/templates/render':
                await asyncio.sleep(state['render_delay'])
                t=next(t for t in CATALOG if t['id']==data['template_id'])
                params=data['params']; assert params['authorized'] is True
                options={k:v for k,v in params.items() if k not in ['authorized','target_url']}
                feature=(f"Feature: {t['title']} - {params['target_url']}\n\n"
                    '  Scenario: Recurring verification of an authorized endpoint\n'
                    f'    Given I monitor the authorized URL "{params["target_url"]}"\n'
                    f'    When I run the "{t["id"]}" monitor with options\n'
                    f'      """\n      {json.dumps(options)}\n      """\n'
                    '    Then the monitor check must pass\n')
                return reply(dict(status='ok',template_id=t['id'],feature=feature,cron_spec=t['cron_spec'],window_days=7,
                    note='Draft only. Review the feature and calculate the budget before enabling. Ownership is rechecked at execution; preview does not contact the target.'))
            elif path=='/api/schedules/v2/operations': return reply(dict(status='ok',data=[]))
            elif path=='/api/schedules/v2/status': return reply(dict(status='ok',custodial=True))
            elif path=='/api/schedules/v2/analytics': return reply(dict(status='ok',data=dict(summary={},buckets=[])))
            elif path=='/api/schedules/v2/preview':
                await asyncio.sleep(state['delay'])
                return reply(dict(status='ok',dry_run=dict(cost_per_run=300000000),window=dict(occurrences=672),
                    budget=dict(estimated=201600000000,safety_percent=15,recommended_lock=231840000000,max_cost_per_run=345000000)))
            elif path=='/api/schedules/v2' and request['method']=='POST':
                await asyncio.sleep(.2)
                if state['create_error']:
                    return reply(dict(status='notok',error='schedule_execution_in_progress'),409)
                s=dict(id='fixture-schedule',status='active',feature_title=data['feature'].splitlines()[0],feature_hash='bafy_fixture',
                    cron_spec=data['cron_spec'],timezone=data['timezone'],start_at=data['start_at'],end_at=data['end_at'],
                    funded=data['lock_amount'],remaining=data['lock_amount'],max_cost_per_run=345000000)
                state['schedules']=[s]; return reply(dict(status='ok',schedule_id=s['id']))
            elif path=='/api/schedules/v2': return reply(dict(status='ok',data=state['schedules']))
            elif path.endswith('/pause') or path.endswith('/resume') or path.endswith('/cancel'):
                action=path.rsplit('/',1)[1]
                state['schedules'][0]['status']={'pause':'paused','resume':'active','cancel':'cancelled'}[action]
                return reply(dict(status='ok'))
            else:
                errors.append('Unexpected API '+path); return reply(dict(status='notok',error='unexpected'),404)
        # Inline the unchanged production functions, replacing only ES imports
        # and external transport. This works even in network-disabled Chromium.
        css=(APP/'priv/static/css/schedules-v2.css').read_text()
        helpers=(APP/'priv/static/js/schedule-templates.js').read_text().replace('export ', '')
        controller=re.sub(r'^import .*?;\n', '', (APP/'priv/static/js/schedules-v2.js').read_text(), flags=re.M).replace('export ', '')
        bootstrap = """
window.ready=false;
window.fetch=async (url,options={})=>{
  const response=await window.__fixtureFetch({url:String(url),method:options.method||'GET',
    data:options.body?JSON.parse(options.body):null,headers:Object.fromEntries(new Headers(options.headers||{}))});
  return new Response(JSON.stringify(response.body),{status:response.code,headers:{'content-type':'application/json'}});
};
const wallet={signTransactionSmart:async()=>{throw new Error('No real wallet transactions in fixtures');}};
"""
        operation_helpers=(APP/'priv/static/js/schedule-operations.js').read_text().replace('export ', '')
        script=bootstrap+helpers+'\n'+operation_helpers+'\n'+controller+"\nwindow.refreshSchedules=updateSchedulesTable; await updateSchedulesTable(); window.ready=true;"
        fixture_html=re.sub(r'<script type="module">.*?</script>', lambda _: '<script type="module">'+script+'</script>', HTML, flags=re.S)
        fixture_html=fixture_html.replace('</head>', '<style>'+css+'</style><link href="/static/css/schedules-v2.css"></head>')
        await page.expose_function('__fixtureFetch', api_handler)
        await page.set_content(fixture_html)
        await page.wait_for_function('window.ready === true', timeout=5000)
        assert await page.locator('[data-template-id]').count()==9
        assert not any(c['method']=='POST' for c in state['calls'])
        await page.screenshot(path=str(out/'starter-gallery-desktop.png'), full_page=True)
        await page.locator('[data-template-id="http-uptime"]').click()
        await page.locator('[name="target_url"]').fill('https://node.example.com/health')
        await page.get_by_role('button',name='Review schedule',exact=True).click()
        assert not any(c['path'].endswith('/render') for c in state['calls']), 'Missing consent must block submit'
        await page.locator('[name="authorized"]').check()
        await page.get_by_role('button',name='Review schedule',exact=True).click()
        await page.locator('#sv2-feature').wait_for()
        assert 'node.example.com/health' in await page.locator('#sv2-feature').input_value()
        assert await page.locator('#sv2-frequency').input_value()=='15m'
        span=await page.evaluate("(new Date(document.getElementById('sv2-end').value)-new Date(document.getElementById('sv2-start').value))/86400000")
        assert span==7
        assert await page.locator('#sv2-create').is_disabled()
        await page.locator('#sv2-preview').click()
        await page.wait_for_function('!document.getElementById("sv2-create").disabled')
        await page.screenshot(path=str(out/'starter-budget-desktop.png'),full_page=True)
        # Edit during an in-flight preview: the obsolete reply cannot unlock creation.
        state['delay']=.25
        await page.locator('#sv2-preview').click()
        feature=await page.locator('#sv2-feature').input_value()
        await page.locator('#sv2-feature').fill(feature+'\n# user-edited\n')
        await page.wait_for_function('!document.getElementById("sv2-preview").disabled')
        assert await page.locator('#sv2-create').is_disabled()
        assert 'Inputs changed' in await page.locator('#sv2-create-error').inner_text()
        state['delay']=0
        await page.locator('#sv2-preview').click()
        await page.wait_for_function('!document.getElementById("sv2-create").disabled')
        # A rejected create surfaces an error and preserves the retryable form.
        state['create_error']=True
        await page.locator('#sv2-create').click()
        await page.wait_for_function('!document.getElementById("sv2-create").disabled')
        assert 'execution in progress' in await page.locator('#sv2-create-error').inner_text()
        state['create_error']=False
        before=sum(c['path']=='/api/schedules/v2' and c['method']=='POST' for c in state['calls'])
        await page.locator('#sv2-create').evaluate('(button)=>{button.click();button.click();}')
        await page.locator('.sv2-schedule').wait_for()
        after=sum(c['path']=='/api/schedules/v2' and c['method']=='POST' for c in state['calls'])
        assert after-before==1, 'Duplicate clicks must not create two schedules'
        assert 'user-edited' in [c for c in state['calls'] if c['path']=='/api/schedules/v2' and c['method']=='POST'][-1]['data']['feature']
        await page.locator('[data-action="pause"]').click()
        await page.locator('.sv2-status.paused').wait_for()
        await page.locator('[data-action="resume"]').click()
        await page.locator('.sv2-status.active').wait_for()
        # Closing a template while render is pending must not reopen a create dialog.
        state['render_delay']=.3
        await page.locator('[data-template-id="node-exposure"]').click()
        await page.locator('[name="target_url"]').fill('https://node.example.com/')
        await page.locator('[name="authorized"]').check()
        await page.get_by_role('button',name='Review schedule',exact=True).click()
        await page.get_by_role('button',name='Close template dialog').click()
        await page.wait_for_timeout(400)
        assert await page.locator('#sv2-modal').is_hidden()
        state['render_delay']=0
        # A fresh mount has a retryable catalogue load failure, not a broken page.
        state['catalog_error']=True
        await page.set_content(fixture_html); await page.wait_for_function('window.ready === true', timeout=5000)
        await page.get_by_role('button',name='Retry starter checks').wait_for()
        state['catalog_error']=False
        await page.get_by_role('button',name='Retry starter checks').click()
        await page.locator('[data-template-id="node-exposure"]').wait_for()
        # Mobile gallery and security form use the same production controller.
        await page.set_viewport_size(dict(width=390,height=844))
        await page.screenshot(path=str(out/'starter-gallery-mobile.png'),full_page=True)
        assert await page.evaluate('document.documentElement.scrollWidth <= window.innerWidth + 1'), 'Page overflows mobile width'
        await page.locator('[data-template-id="node-exposure"]').click()
        await page.screenshot(path=str(out/'starter-security-mobile.png'),full_page=True)
        assert await page.get_by_role('dialog').count()==1
        assert await page.locator('[name="authorized"]').is_checked() is False
        await page.keyboard.press('Escape')
        assert await page.locator('#sv2-modal').is_hidden()
        assert await page.evaluate('document.activeElement.dataset.templateId')=='node-exposure'
        assert not errors, errors
        (out/'browser-results.json').write_text(json.dumps(dict(result='PASS',checks=14,errors=errors,calls=state['calls']),indent=2))
        print('PASS: 14 browser checks; API fixtures only; no live target requests or wallet transactions.')
        await browser.close()

if __name__=='__main__':
    ap=argparse.ArgumentParser(); ap.add_argument('--out',default='/tmp/schedule-template-ui'); ap.add_argument('--chromium',default='/usr/bin/chromium')
    asyncio.run(run(ap.parse_args()))
