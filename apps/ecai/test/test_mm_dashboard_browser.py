#!/usr/bin/env python3
"""Browser contract: real ECAI MM markup/module, test-only synthetic API fixtures.
Run: python apps/ecai/test/test_mm_dashboard_browser.py
No live Coinstore connection or real trade is made.
"""
import asyncio
import base64
from pathlib import Path
from playwright.async_api import async_playwright

APP = Path(__file__).resolve().parents[1]

FAKE_API = r"""
window.__admin = false;
window.confirm = () => true;
window.__requests = [];
const ts = Date.now();
const fakeConfig = {
  poll_interval_ms:10000, levels:4, base_half_spread_bps:30, level_step_bps:20,
  volatility_weight:0.75, target_inventory_ratio:0.5, max_inventory_ratio:0.85,
  max_skew_bps:60, maker_fee_bps:10, fee_buffer_bps:4, max_order_notional:35,
  max_side_notional:150, max_price_jump_pct:25, max_drawdown_pct:10,
  max_feed_age_ms:20000
};
window.__fixture = {
  status:{mode:'paper',source:'coinstore',symbol:'DAMAGEUSDT',fresh:true,paused:false,
    halt_reason:'none',feed_error:null,feed_age_ms:3500,failures:0,
    price:{bid:0.0141,ask:0.0143,mid:0.0142,btc_usdt:80000,fetched_ms:ts,volatility_bps:3.2},
    quotes:[{side:'buy',price:0.0140,remaining_qty:200},{side:'sell',price:0.0144,remaining_qty:150}],
    performance:{opening_equity_usdt:700,equity_usdt:703,pnl_usdt:3,pnl_pct:0.4,
      max_drawdown_pct:1.2,fees_usdt:0.05,turnover_usdt:45,fill_count:1,
      balances:{damage:20000,usdt:419},fills:[{ts_ms:ts,side:'buy',qty:100,price:0.0140,notional_usdt:1.4,fee_usdt:0.0014}]},
    events:3, config_revision:0, audit:{digest_hex:'a'.repeat(64),state_point_hex:'02'+'b'.repeat(64)}},
  config:{mode:'paper',execution_enabled:false,revision:0,values:fakeConfig},
  history:[1,2,3].map((i)=>({ts_ms:ts - (3-i)*10000,damage_usdt:0.014*i/3,btc_usdt:70000+i*3000,
      damage_index:95+i*3,btc_index:96+i*2,equity_usdt:697+i*2,
      btc_benchmark_pnl_usdt:(i-1)*1.7,audit_hash:'a'.repeat(64)}))
};
window.__request = async (path, options = {}) => {
  window.__requests.push([path,options.method||'GET',options.body || null]);
  if (!window.__admin) { const e = Error('Forbidden'); e.status=403; throw e; }
  const f=window.__fixture;
  if (path === '/ecai/mm/status') return {ok:true,status:structuredClone(f.status)};
  if (path.startsWith('/ecai/mm/history')) return {ok:true,history:structuredClone(f.history)};
  if (path === '/ecai/mm/config' && !options.method) return {ok:true,config:structuredClone(f.config)};
  if (path === '/ecai/mm/config' && options.method === 'POST') {
    if (options.body.expected_revision !== f.config.revision) { const e=Error('Conflict'); e.status=409; throw e; }
    Object.assign(f.config.values, options.body.changes); f.config.revision++;
    f.status.config_revision = f.config.revision;
    return {ok:true,config:structuredClone(f.config)};
  }
  if (path === '/ecai/mm/control') {
    if (options.body.action === 'pause') f.status.paused = true;
    if (options.body.action === 'resume') f.status.paused = false;
    return {ok:true,status:structuredClone(f.status)};
  }
  if (path === '/ecai/mm/audit') return {ok:true,verified:true};
  throw Error('Unknown endpoint: '+path);
};
"""

async def main():
    fragment = (APP/'priv/templates/ui/dashboard/ecai_market_maker.mustache').read_text()
    css = (APP/'priv/static/css/ecai-market-maker.css').read_text()
    script = (APP/'priv/static/js/ecai-market-maker.js').read_bytes()
    code_url = 'data:text/javascript;base64,' + base64.b64encode(script).decode()
    async with async_playwright() as browser_api:
        browser = await browser_api.chromium.launch(
            executable_path='/usr/bin/chromium', headless=True,
            args=['--no-sandbox','--disable-dev-shm-usage'])
        page = await browser.new_page()
        errors=[]
        page.on('pageerror', lambda e: errors.append(str(e)))
        await page.goto('about:blank')
        await page.set_content('<style>:root{--line:#e1e6f1;--ink:#14223d;--muted:#7b8ca7}</style><style>'+css+'</style>'+fragment)
        await page.evaluate("document.querySelector('[data-panel=\"market-maker\"]').hidden = false")
        await page.evaluate('() => {' + FAKE_API + '\n return true; }')
        await page.evaluate("""async (url) => {
          const {initMarketMaker} = await import(url);
          window.__mm = initMarketMaker({request:window.__request,canManage:()=>window.__admin,
            openLogin:()=>{window.__loginPrompt=true;}});
          window.__mm.setVisible(true);
        }""", code_url)
        assert await page.locator('#mmSaveConfig').is_disabled(), 'controls must default to denied'
        assert 'node-admin' in (await page.locator('#mmNotice').inner_text())
        await page.evaluate('window.__admin=true;window.__mm.accessChanged();window.__mm.refresh(true)')
        await page.wait_for_function("document.querySelector('#mmDamagePrice').textContent.includes('0.0142')")
        await page.wait_for_function("document.querySelector('#mmConfigRevision').textContent.includes('0')")
        assert await page.locator('#mmPriceChart svg path').count() == 2
        assert '703' in (await page.locator('#mmEquity').inner_text())
        assert await page.locator('#mmBids tr').count() == 1
        assert await page.locator('#mmAsks tr').count() == 1
        await page.locator('#mmTabConfigure').click()
        assert await page.locator('#mmPanelConfigure').is_visible()
        assert await page.locator('#mmSaveConfig').is_enabled()
        await page.locator('#mmLevels').fill('7')
        await page.locator('#mmSaveConfig').click()
        await page.wait_for_function("window.__fixture.config.revision === 1")
        writes = await page.evaluate("window.__requests.filter(r=>r[1]==='POST')")
        assert writes[-1][2] == {'expected_revision':0,'changes':{'levels':7}}, writes
        await page.locator('#mmPause').click()
        await page.wait_for_function('window.__fixture.status.paused === true')
        await page.locator('#mmResume').click()
        await page.wait_for_function('window.__fixture.status.paused === false')
        await page.locator('#mmTabAudit').click()
        await page.locator('#mmVerify').click()
        await page.wait_for_function("document.querySelector('#mmVerifyResult').textContent.includes('verified')")
        await page.locator('#mmTabPerformance').click()
        assert await page.locator('#mmPerformanceChart svg path').count() == 2
        await page.evaluate('window.__admin=false;window.__mm.reset()')
        assert await page.locator('#mmVerify').is_disabled()
        assert await page.locator('#mmLevels').is_disabled()
        assert not errors, errors
        await page.evaluate('window.__mm.dispose()')
        await browser.close()
    print('PASS: market maker tabs, live metrics, persisted config revision, pause/resume, audit, account gating')

if __name__ == '__main__':
    asyncio.run(main())
