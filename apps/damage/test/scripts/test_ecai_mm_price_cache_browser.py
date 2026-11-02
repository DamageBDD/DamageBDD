"""Offline browser contracts for the ECAI price-cache dashboard.

All prices below are synthetic fixtures, never fetched or written to a node.
Backend authorization must also be exercised against Cowboy in integration tests.
"""
import json
import re
from types import SimpleNamespace
import shutil
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ASSETS = Path(__file__).resolve().parents[2] / 'priv' / 'ui' / 'ecai-market-maker'
ORIGIN = 'http://127.0.0.1:8765'


class PriceCacheBrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from playwright.sync_api import sync_playwright
        chromium = shutil.which('chromium') or shutil.which('chromium-browser')
        if not chromium:
            raise unittest.SkipTest('Chromium is not installed')
        cls.pw = sync_playwright().start()
        cls.browser = cls.pw.chromium.launch(
            executable_path=chromium, headless=True, args=['--no-sandbox'])

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, 'browser'):
            cls.browser.close()
            cls.pw.stop()

    def setUp(self):
        self.page = self.browser.new_page(viewport={'width': 1440, 'height': 1000})
        self.addCleanup(self.page.close)
        self.errors = []
        self.requests = []
        self.page.on('pageerror', lambda err: self.errors.append(str(err)))
        self.live_code = 503
        self.cached = True
        self.tick_history = []
        self.gap = False
        self.instrument = '''(() => {
          const p=CanvasRenderingContext2D.prototype;
          for(const method of ['beginPath','moveTo','lineTo','stroke']) {
            const original=p[method];
            p[method]=function(...args) {
              if(method==='beginPath')this.__trace=[];
              if(method==='moveTo'||method==='lineTo')(this.__trace||=[]).push([method,...args]);
              if(method==='stroke' && this.canvas.id==='market-chart' && this.strokeStyle==='#6be9ae')
                window.marketTrace=this.__trace.slice();
              return original.apply(this,args);
            };
          }
        })();'''
        self.page.expose_function('fixture_read', self.fixture_read)

    def fixture_read(self, url, method):
        # In-memory responses: no browser navigation, HTTP server or network.
        result = {}
        def fulfill(status=200, content_type='application/json', body=''):
            result.update(status=status, content_type=content_type, body=body)
        route = SimpleNamespace(request=SimpleNamespace(url=ORIGIN + url, method=method), fulfill=fulfill)
        self.route(route)
        return result

    def route(self, route):
        request = route.request
        parts = urlsplit(request.url)
        self.requests.append((request.method, parts.path))
        if parts.path == '/ecai/market-maker':
            route.fulfill(content_type='text/html', body=(ASSETS / 'index.html').read_text())
        elif parts.path.startswith('/ecai/market-maker/'):
            name = parts.path.rsplit('/', 1)[-1]
            content_type = 'text/javascript' if name.endswith('.js') else 'text/css'
            route.fulfill(content_type=content_type, body=(ASSETS / name).read_text())
        elif parts.path == '/api/ecai/mm/status':
            status = {'fresh': True, 'paused': False, 'quotes': [], 'events': 1,
                      'price': {'mid': 0.01, 'btc_usdt': 95000.0, 'fetched_ms': 1700000000000},
                      'performance': {'equity_usdt': 400.0, 'opening_equity_usdt': 400.0,
                                      'pnl_usdt': 0, 'pnl_pct': 0, 'max_drawdown_pct': 0,
                                      'balances': {'usdt': 300, 'damage': 10000}, 'fills': []}}
            self.send(route, status if self.live_code == 200 else {'error': 'disabled'}, self.live_code)
        elif parts.path == '/api/ecai/mm/history':
            self.send(route, self.tick_history)
        elif parts.path == '/api/ecai/mm/price-cache':
            self.send(route, {'available': self.cached, 'queued': 0, 'series': [
                {'symbol': 'DAMAGEUSDT', 'period': '60min', 'count': 3},
                {'symbol': 'BTCUSDT', 'period': '60min', 'count': 3}] if self.cached else []})
        elif parts.path == '/api/ecai/mm/prices':
            period = parse_qs(parts.query)['period'][0]
            step = 3600000 if period == '60min' else 86400000
            offsets = [0, 1, 6] if self.gap else [0, 1, 2]
            rows = [{'ts_ms': 1700000000000 + offset * step,
                     'damage_index': 100 + i * 5, 'btc_index': 100 + i,
                     'damage_usdt': 0.01, 'btc_usdt': 95000.0}
                    for i, offset in enumerate(offsets)] if self.cached else []
            self.send(route, {'kind': 'historical_prices', 'period': period,
                              'period_ms': step, 'rows': rows, 'missing_intervals': 4 if self.gap else 0})
        else:
            route.fulfill(status=404, body='not found')

    @staticmethod
    def send(route, value, status=200):
        route.fulfill(status=status, content_type='application/json', body=json.dumps(value))

    def load(self):
        html = (ASSETS / 'index.html').read_text()
        html = re.sub(r'<script[^>]*src="[^"]*"[^>]*></script>', '', html)
        html = re.sub(r'<link[^>]*rel="stylesheet"[^>]*>', '', html)
        self.page.set_content(html)
        self.page.add_style_tag(content=(ASSETS / 'styles.css').read_text())
        self.page.evaluate(self.instrument)
        self.page.evaluate("""window.fetch = async (url, opts={}) => {
          const data = await window.fixture_read(String(url), opts.method || 'GET');
          return new Response(data.body, {status:data.status, headers:{'Content-Type':data.content_type}});
        };""")
        self.page.add_script_tag(content=(ASSETS / 'app.js').read_text())
        self.page.wait_for_function("document.querySelector('#cache-state').textContent.includes('stored closed candles') || document.querySelector('#cache-state').textContent.includes('cache unavailable')")

    def test_history_renders_when_engine_disabled_without_fake_pnl(self):
        self.load()
        self.assertIn('hide', self.page.locator('#market-empty').get_attribute('class'))
        self.assertNotIn('hide', self.page.locator('#pnl-empty').get_attribute('class'))
        self.assertEqual('—', self.page.locator('#net-pnl').inner_text())
        self.assertEqual('—', self.page.locator('#equity').inner_text())
        self.assertEqual('—', self.page.locator('#damage-price').inner_text())
        self.assertEqual('FEED UNAVAILABLE', self.page.locator('#feed-state').inner_text())
        self.assertIn('60min closed candles', self.page.locator('#market-source').inner_text())
        self.assertEqual([], self.errors)

    def test_period_switch_uses_only_read_only_cache_endpoints(self):
        self.load()
        self.page.select_option('#history-period', '1day')
        self.page.wait_for_function("document.querySelector('#market-source').textContent.includes('1day closed candles')")
        self.assertTrue(all(method == 'GET' for method, _ in self.requests))
        self.assertEqual([], self.errors)

    def test_historical_gaps_are_not_interpolated_and_x_axis_is_time(self):
        self.gap = True
        self.load()
        trace = self.page.evaluate('window.marketTrace')
        self.assertEqual(['moveTo', 'lineTo', 'moveTo'], [point[0] for point in trace])
        self.assertAlmostEqual((trace[2][1] - trace[1][1]) / (trace[1][1] - trace[0][1]), 5.0)
        self.assertIn('4 missing intervals', self.page.locator('#market-source').inner_text())
        self.assertEqual([], self.errors)

    def test_live_api_failure_clears_previous_live_badge(self):
        self.live_code = 200
        self.load()
        self.assertEqual('FEED LIVE', self.page.locator('#feed-state').inner_text())
        self.live_code = 503
        self.page.select_option('#history-period', '1day')
        self.page.wait_for_function("document.querySelector('#feed-state').textContent==='FEED UNAVAILABLE'")
        self.assertIn('hide', self.page.locator('#market-empty').get_attribute('class'))
        self.assertEqual('—', self.page.locator('#equity').inner_text())
        self.assertEqual([], self.errors)

    def test_historical_candles_do_not_extend_equity_timeline(self):
        self.live_code = 200
        self.tick_history = [
            {'ts_ms': 1700050000000, 'damage_index': 100, 'btc_index': 100,
             'equity_usdt': 400, 'btc_benchmark_pnl_usdt': 0},
            {'ts_ms': 1700050010000, 'damage_index': 101, 'btc_index': 101,
             'equity_usdt': 401, 'btc_benchmark_pnl_usdt': 4}]
        self.load()
        self.assertIn('hide', self.page.locator('#pnl-empty').get_attribute('class'))
        self.assertIn('60min closed candles', self.page.locator('#market-source').inner_text())
        self.assertEqual('$400', self.page.locator('#equity').inner_text())
        self.assertEqual([], self.errors)

    def test_no_cache_or_live_data_keeps_empty_states(self):
        self.cached = False
        self.load()
        self.assertNotIn('hide', self.page.locator('#market-empty').get_attribute('class'))
        self.assertNotIn('hide', self.page.locator('#pnl-empty').get_attribute('class'))
        self.assertEqual('—', self.page.locator('#equity').inner_text())
        self.assertEqual([], self.errors)


if __name__ == '__main__':
    unittest.main()
