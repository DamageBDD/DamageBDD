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
OTHER_NODE = 'ak_' + 'C' * 40
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
    body = TPL.replace('{{run_history_account}}', '').replace('{{run_history_node}}', node).replace('{{run_history_registry}}', '')
    css = '\n'.join((CSS / name).read_text() for name in [
        'main.css', 'dashboard-workspace.css', 'dashboard-shell.css', 'reports.css'
    ])
    return f'''<!doctype html><html><head><meta charset="utf-8"><style>{css}</style></head>
       <body class="damage-dashboard"><main id="content" class="dashboard-panels">
       <div id="activity-tab" class="dashboard-panel" {'hidden' if hidden else ''}>{body}</div>
       </main></body></html>'''

def init(page, node='', hidden=False, session=ACCOUNT, legacy=False, scenario='default'):
    page.set_content(markup(node, hidden))
    page.evaluate('''([account, node, feature, report, contract, otherNode, legacy, scenario]) => {
        // Simulate a legacy dashboard configuration. Run history must ignore
        // this cross-origin IPFS gateway even when the local manifest is 404.
        window.DamageActivity = {ipfsGateway:'https://ipfs.io/ipfs/'};
        window.__mock = {proxy:0, remote:0, missingNodes:0, tokenCalls:0, nodePayerCalls:0, legacy,
                         registryCalls:0, accountCalls:0, nodeIpfs:0, externalIpfs:0, scenario, down:scenario === 'retry'};
        const json = (data, status=200) => new Response(JSON.stringify(data),
          {status, headers:{'content-type':'application/json'}});
        const now = Date.now();
        window.fetch = async (path) => {
          path = String(path);
          if (path.startsWith('/api/run-history/nodes')) {
            window.__mock.missingNodes++;
            return json({error:'not found'}, 404);
          }
          if (path.startsWith('/api/run-history/')) {
            window.__mock.proxy++;
            return json({error:'unavailable'}, 404);
          }
          if (path.startsWith('https://mainnet.aeternity.io/mdw/')) {
            window.__mock.remote++;
            if (path.includes('/v3/transactions?') && path.includes('contract='+contract)) {
                window.__mock.tokenCalls++;
                if (scenario === 'retry' && window.__mock.down)
                  return json({error:'temporary middleware failure'}, 503);
                if (scenario === 'duplicate') return json({data:[{
                  hash:'th_'+'H'.repeat(40),micro_time:now,
                  // A flattened token-index record wrongly names the outer
                  // node as caller; prefer the fully decoded nested sponsor.
                  tx:{type:'ContractCallTx',contract_id:contract, caller_id:node,
                    function:'spend',arguments:[{type:'address',value:node},
                      {type:'int',value:'100000000'},{type:'string',value:feature},
                      {type:'string',value:report}]}
                }],next:null});
                if (['payer','sponsored','sponsored-meta-only'].includes(scenario)) return json({data:[], next:null});
                // A middleware page may have no matching transactions but still
                // advertise an older cursor. Follow it without manual clicking.
                if (scenario === 'sparse' && !path.includes('cursor=older'))
                  return json({data:[], next:'/v3/transactions?contract='+contract+
                    '&type=contract_call&type=paying_for&direction=backward&cursor=older&limit=50'});
                if (scenario === 'encoded') return json({data:[{
                  hash:'th_'+'F'.repeat(40), micro_time:now,
                  tx:{type:'ContractCallTx', contract_id:contract, caller_id:account,
                    call_data:'cb_'+btoa('X'+feature+'\x00'+report+'Y')}
                }], next:null});
                return json({data:[{
                  call_tx_hash:'th_'+'C'.repeat(40), contract_id:contract,
                  function:'DamageToken.spend', caller_id:account,
                  micro_time:now,
                  arguments:[{type:'address',value:node},{type:'int',value:'100000000'},
                    {type:'string',value:feature},{type:'string',value:report}]
                }, {
                  call_tx_hash:'th_'+'E'.repeat(40), contract_id:contract,
                  function:'DamageToken.spend', caller_id:account,
                  micro_time:now - 1000,
                  arguments:[{type:'address',value:otherNode},{type:'int',value:'250000000'},
                    {type:'string',value:feature},{type:'string',value:report}]
                }], next:null});
            }
            if (path.includes('/v3/transactions?') && path.includes('contract=ct_KxoBnfb')) {
              window.__mock.registryCalls++;
              return json({data:[{
                call_tx_hash:'th_'+'D'.repeat(40),
                contract_id:'ct_KxoBnfbSvhy3c2384VMS2j99YKuqtUihAMSsk6TekjqnZeNEQ',
                function:'NodeRegistry.register_node', arguments:[
                  {type:'address',value:account},{type:'address',value:node},
                  {type:'record',value:{}},{type:'record',value:{}}]
              }],next:null});
            }
            if (path.includes('/activities')) {
              window.__mock.accountCalls++;
              if (['payer','duplicate','sponsored','sponsored-meta-only'].includes(scenario) && path.includes('/accounts/'+node+'/activities')) {
                window.__mock.nodePayerCalls++;
                return json({data:[{
                  type:'PayingForTxEvent', sender_id:node, payload:{
                    hash:'th_'+(scenario === 'duplicate'?'H':'G').repeat(40), micro_time:now,
                    tx:{type:'PayingForTx', payer_id:node, sender_id:node, tx:{type:'SignedTx', tx:{
                      type:'ContractCallTx', contract_id:contract, function:'spend',
                      ...(scenario === 'sponsored-meta-only' ? {} : {caller_id:account}),
                      arguments:[{type:'address',value:node},{type:'int',value:'100000000'},
                        {type:'string',value:feature},{type:'string',value:report}]
                    }}}
                  }
                }], next:null});
              }
              return json({data:[],next:null});
            }
            if (path.includes('/v3/transactions/')) return json({tx:{caller_id:account},micro_time:now});
          }
          if (path.includes('ipfs.io/ipfs/')) {
            window.__mock.externalIpfs++;
            return json({error:'cross-origin IPFS blocked'}, 403);
          }
          if (path.endsWith('/reports/' + report + '/run.meta')) {
            window.__mock.nodeIpfs++;
            if (window.__mock.legacy) return json({}, 404);
            return json({feature_title:'Example checkout',status:'passed',
              tags:['@smoke','@api'],start_time_hires:now/1000,run_id:'fixture-run',
              node_public_key:node, public_key:account});
          }
          if (path.endsWith('/reports/' + report + '/')) {
            window.__mock.nodeIpfs++;
            return json([{Name:'10.plain.txt'}, {Name:'10.html'}]);
          }
          if (path.includes('/reports/' + report + '/10.plain.txt'))
            return new Response('Then a check line:2 fail\\nFailure: test\\n', {status:200});
          if (path.includes('ipfs.io/ipfs/') && path.includes(feature))
            return new Response('@smoke @api\\nFeature: Example checkout\\n  Scenario: smoke\\n', {status:200});
          return json({}, 404);
        };
    }''', [ACCOUNT, NODE, CID_FEATURE, CID_REPORT, CONTRACT, OTHER_NODE, legacy, scenario])
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
        assert page.evaluate('window.__mock.remote') > 0
        assert page.evaluate('window.__mock.tokenCalls') > 0
        assert page.evaluate('window.__mock.accountCalls') > 0
        assert page.evaluate('window.__mock.missingNodes') == 0
        assert page.evaluate('window.__mock.proxy') == 0
        assert page.evaluate('window.__mock.nodeIpfs') > 0
        assert page.evaluate('window.__mock.externalIpfs') == 0
        assert page.locator('#activity-tab').evaluate('(el) => getComputedStyle(el).borderTopWidth') == '0px'
        assert page.locator('#activity-tab').evaluate('(el) => getComputedStyle(el).backgroundColor') in (
            'rgba(0, 0, 0, 0)', 'transparent')
        print('PASS account restored; token transactions and account activity fetched, node IPFS used without external gateway')
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
        assert page.evaluate('window.__mock.tokenCalls') > 0
        assert page.evaluate('window.__mock.missingNodes') == 0
        page.locator('#activity-directory').evaluate('(el) => {el.open=true}')
        page.locator('[data-history-scope="discover"]').click()
        page.locator('.history-node').first.wait_for(timeout=10000)
        page.wait_for_function("document.querySelectorAll('.activity-item').length === 2", timeout=10000)
        assert page.evaluate('window.__mock.registryCalls') > 0
        assert page.locator('.history-node').first.inner_text()
        assert page.evaluate('window.__mock.missingNodes') == 0
        print('PASS node, network-wide discovery and registry history fetched from chain without application history APIs')
        page.close()

        page = browser.new_page()
        page.on('pageerror', lambda e: errors.append(str(e)))
        init(page, hidden=True)
        page.wait_for_timeout(250)
        assert page.evaluate('window.__mock.remote') == 0
        page.evaluate('''() => {
          document.getElementById('activity-tab').hidden = false;
          document.dispatchEvent(new CustomEvent('damage:panelchange',{detail:{id:'activity-tab'}}));
        }''')
        page.locator('.activity-item').first.wait_for(timeout=10000)
        print('PASS entering previously hidden history panel fetches immediately')
        page.close()

        page = browser.new_page()
        page.on('pageerror', lambda e: errors.append(str(e)))
        init(page, legacy=True)
        page.locator('.activity-item').first.wait_for(timeout=10000)
        page.locator('#activity-status-filter').select_option('failed')
        page.locator('.history-status.failed').first.wait_for(timeout=10000)
        assert page.evaluate('window.__mock.missingNodes') == 0
        print('PASS legacy report status inferred from reports/:cid listing and plain text evidence')
        page.close()

        page = browser.new_page()
        page.on('pageerror', lambda e: errors.append(str(e)))
        init(page, scenario='sparse')
        page.locator('.activity-item').first.wait_for(timeout=13000)
        assert page.evaluate('window.__mock.tokenCalls') >= 2
        assert page.evaluate('window.__mock.externalIpfs') == 0
        print('PASS automatically follows an empty first token-transaction page to an older cursor')
        page.close()

        page = browser.new_page()
        page.on('pageerror', lambda e: errors.append(str(e)))
        init(page, node=NODE, scenario='payer')
        page.locator('.activity-item').first.wait_for(timeout=14000)
        assert page.locator('.activity-item').count() == 1
        assert page.evaluate('window.__mock.accountCalls') > 0
        assert page.evaluate('window.__mock.tokenCalls') > 0
        print('PASS legacy nested PayingForTx from node-payer account activity when contract index is empty')
        page.close()

        for sponsored_scenario in ('sponsored', 'sponsored-meta-only'):
            page = browser.new_page()
            page.on('pageerror', lambda e: errors.append(str(e)))
            init(page, node=NODE, scenario=sponsored_scenario)
            page.locator('.activity-item').first.wait_for(timeout=14000)
            assert page.locator('.activity-item').count() == 1
            page.locator('[data-history-scope="account"]').click()
            page.wait_for_function('''() => document.querySelector('[data-history-scope="account"]').getAttribute('aria-pressed') === 'true'
                && document.querySelector('#activity-status').textContent.includes('run(s)')''', timeout=15000)
            page.locator('.activity-item').first.wait_for(timeout=14000)
            assert page.locator('.activity-item').count() == 1, sponsored_scenario
            assert page.evaluate('window.__mock.tokenCalls') >= 2
            assert page.evaluate('window.__mock.nodePayerCalls') >= 2
            page.locator('.activity-details summary').first.click()
            detail = page.locator('.history-run-details').first.inner_text()
            assert ACCOUNT in detail and NODE in detail
            assert 'Transaction fee payer' in detail
            assert 'Run account (inner spend caller)' in detail
            if sponsored_scenario.endswith('meta-only'):
                assert 'Claimed by IPFS run.meta' in detail
                assert page.locator('.activity-meta a').filter(has_text='Reported account').count() == 1
            else:
                assert 'Inner on-chain contract caller' in detail
            print('PASS hosted account runs appear in My account via node-sponsored PayingForTx (' + sponsored_scenario + ')')
            page.close()

        page = browser.new_page()
        page.on('pageerror', lambda e: errors.append(str(e)))
        init(page, scenario='encoded')
        page.locator('.activity-item').first.wait_for(timeout=14000)
        assert page.locator('.activity-title').first.inner_text() == 'Example checkout'
        assert page.locator('.activity-item').count() == 1
        assert page.evaluate('window.__mock.nodeIpfs') > 0
        assert page.evaluate('window.__mock.externalIpfs') == 0
        page.locator('.activity-details summary').first.click()
        assert 'Claimed by IPFS run.meta' in page.locator('.history-run-details').first.inner_text()
        print('PASS encoded token calldata CIDs enriched by same-origin run.meta (node identity labeled unverified)')
        page.close()

        page = browser.new_page()
        page.on('pageerror', lambda e: errors.append(str(e)))
        init(page, node=NODE, scenario='duplicate')
        page.locator('.activity-item').first.wait_for(timeout=14000)
        assert page.locator('.activity-item').count() == 1
        page.locator('.activity-details summary').first.click()
        detail = page.locator('.history-run-details').first.inner_text()
        assert 'On-chain decoded arguments' in detail
        assert 'Run account (inner spend caller)' in detail
        assert 'Transaction fee payer' in detail
        assert ACCOUNT in detail and NODE in detail
        page.locator('[data-history-scope="account"]').click()
        page.locator('.activity-item').first.wait_for(timeout=14000)
        assert page.locator('.activity-item').count() == 1
        print('PASS duplicate flattened payer identity does not override the nested signed run account')
        page.close()

        page = browser.new_page()
        page.on('pageerror', lambda e: errors.append(str(e)))
        init(page, scenario='retry')
        page.wait_for_function("window.__mock.tokenCalls >= 1 && document.getElementById('activity-status').textContent.includes('failed')",
                               timeout=15000)
        assert page.locator('.activity-item').count() == 0
        page.evaluate('window.__mock.down = false')
        page.locator('#run-reports-next').click()
        page.locator('.activity-item').first.wait_for(timeout=14000)
        assert page.evaluate('window.__mock.tokenCalls') >= 2
        print('PASS failed middleware cursor remains retryable; next scan loads the recovered run')
        page.close()
        assert not errors, f'Browser errors: {errors}'
        print('PASS no JavaScript page errors')
        browser.close()

if __name__ == '__main__':
    run()
