#!/usr/bin/env python3
"""Browser smoke tests: public history autoload, session fallback and flat panel.
Uses about:blank fixtures because no live server, wallet or chain is necessary.
Requires Playwright and Chromium: python apps/damage/test/scripts/run_history_browser_test.py
"""
import base64
import json
import os
from pathlib import Path
from playwright.sync_api import sync_playwright

APP = Path(__file__).resolve().parents[2]
JS = APP / 'priv/static/js'
CSS = APP / 'priv/static/css'
TPL = (APP / 'priv/templates/ui/dashboard/activity_tab.mustache').read_text()
MODEL = (JS / 'run-history-model.js').read_bytes()
REPORTS = (JS / 'reports.js').read_text()
ACCOUNT = 'ak_' + 'A' * 40
NODE = 'ak_' + 'B' * 40
CID_FEATURE = 'Qm' + 'a' * 44
CID_REPORT = 'Qm' + 'b' * 44
CONTRACT = 'ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk'

def data_module(src):
    if isinstance(src, str):
        src = src.encode()
    return 'data:text/javascript;base64,' + base64.b64encode(src).decode()

def test_script(session=ACCOUNT):
    wallet = f'''export const TokenManager = {{ready:Promise.resolve(),getAddress:()=>{json.dumps(session)}}};'''
    return REPORTS.replace("from './run-history-model.js'", f"from '{data_module(MODEL)}'") \
                  .replace("from './wallet-switcher.js'", f"from '{data_module(wallet)}'")

def markup(node='', hidden=False):
    body = TPL.replace('{{run_history_account}}', '').replace('{{run_history_node}}', node)
    css = '\n'.join((CSS / name).read_text() for name in [
        'main.css', 'dashboard-workspace.css', 'dashboard-shell.css', 'reports.css'
    ])
    return f'''<!doctype html><html><head><meta charset="utf-8"><style>{css}</style></head>
       <body class="damage-dashboard"><main id="content" class="dashboard-panels">
       <div id="activity-tab" class="dashboard-panel" {'hidden' if hidden else ''}>{body}</div>
       </main></body></html>'''

def init(page, node='', hidden=False, session=ACCOUNT):
    page.set_content(markup(node, hidden))
    page.evaluate('''([account, node, feature, report, contract]) => {
        window.__mock = {proxy:0, remote:0};
        window.fetch = async (path) => {
          path = String(path);
          if (path.startsWith('https://mainnet.aeternity.io/')) {
            window.__mock.remote++;
            throw new Error('CORS blocked in test');
          }
          if (path.startsWith('/api/run-history/activities')) {
            window.__mock.proxy++;
            return new Response(JSON.stringify({data:[{
              hash:'th_'+'C'.repeat(40),micro_time:Date.now()*1000,
              payload:{tx:{contract_id:contract,function:'spend',caller_id:account,
                arguments:[{type:'address',value:node},{type:'int',value:'100000000'},
                  {type:'string',value:feature},{type:'string',value:report}]}}
            }],next:null}),{status:200,headers:{'content-type':'application/json'}});
          }
          if (path.startsWith('/api/run-history/nodes')) return new Response('{"nodes":[]}',{status:200});
          if (path.includes('/run.meta')) return new Response(JSON.stringify({
            feature_title:'Example checkout', status:'passed',tags:['@smoke','@api'],
            start_time_hires:Date.now()/1000,run_id:'fixture-run'}),{status:200});
          return new Response('{}',{status:404});
        };
    }''', [ACCOUNT, NODE, CID_FEATURE, CID_REPORT, CONTRACT])
    page.add_script_tag(type='module', content=test_script(session))


def run():
    with sync_playwright() as pw:
        browser = pw.chromium.launch(executable_path=os.environ.get('CHROMIUM', '/usr/bin/chromium'),
                                      headless=True, args=['--no-sandbox'])
        errors = []
        page = browser.new_page(viewport={'width': 1320, 'height': 900})
        page.on('pageerror', lambda e: errors.append(str(e)))
        init(page)
        page.locator('.activity-item').first.wait_for(timeout=14000)
        assert page.locator('[data-history-scope="account"]').get_attribute('aria-pressed') == 'true'
        assert page.locator('.activity-title').first.inner_text() == 'Example checkout'
        assert page.locator('#activity-directory').evaluate('(el) => !el.open')
        assert page.evaluate('window.__mock.proxy') > 0
        assert page.locator('#activity-tab').evaluate('(el) => getComputedStyle(el).borderTopWidth') == '0px'
        assert page.locator('#activity-tab').evaluate('(el) => getComputedStyle(el).backgroundColor') in (
            'rgba(0, 0, 0, 0)', 'transparent')
        print('PASS wallet public account restored and fetched on initial view; CORS proxy fallback used')
        print('PASS flat dashboard, no inherited purple panel and no nested registry card')
        page.locator('#activity-tags').fill('@missing')
        page.locator('.history-empty').first.wait_for(timeout=8000)
        assert page.locator('.activity-item').count() == 0
        print('PASS tags filter updates fetched results')
        page.close()

        page = browser.new_page()
        page.on('pageerror', lambda e: errors.append(str(e)))
        init(page, node=NODE)
        page.locator('.activity-item').first.wait_for(timeout=10000)
        assert page.locator('[data-history-scope="node"]').get_attribute('aria-pressed') == 'true'
        print('PASS configured node fetches on initial view without wallet overwriting node identity')
        page.close()

        page = browser.new_page()
        page.on('pageerror', lambda e: errors.append(str(e)))
        init(page, hidden=True)
        page.wait_for_timeout(250)
        assert page.evaluate('window.__mock.proxy') == 0
        page.evaluate('''() => {
          document.getElementById('activity-tab').hidden = false;
          document.dispatchEvent(new CustomEvent('damage:panelchange',{detail:{id:'activity-tab'}}));
        }''')
        page.locator('.activity-item').first.wait_for(timeout=10000)
        print('PASS entering previously hidden history panel fetches immediately')
        page.close()
        assert not errors, f'Browser errors: {errors}'
        print('PASS no JavaScript page errors')
        browser.close()

if __name__ == '__main__':
    run()
