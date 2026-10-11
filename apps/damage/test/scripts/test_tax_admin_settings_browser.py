#!/usr/bin/env python3
"""Offline browser test of tax-only dashboard config and versioned POST wire format."""
from pathlib import Path
import json
import shutil
import unittest
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent))
from bdd_composer_browser_test import render_template

HTML = ROOT / 'priv/templates/ui/dashboard/node_tax_reports_tab.mustache'
JS = ROOT / 'priv/static/js/dashboard-tax-settings.js'
OWNER = 'ak_' + '2' * 52
FIELD_DATA = [
    {'name': 'tax_enabled', 'label': 'Enable ATO tax reporting', 'type': 'boolean',
     'apply': 'restart', 'help': 'Restart required', 'value': False},
    {'name': 'tax_cln_owner', 'label': 'CLN tax owner', 'type': 'ae_account',
     'apply': 'restart', 'help': '', 'value': None},
    {'name': 'tax_data_dir', 'label': 'Evidence storage', 'type': 'absolute_path',
     'apply': 'restart', 'help': '', 'value': '/var/lib/damage/tax'},
    {'name': 'tax_backfill_on_start', 'label': 'Backfill on startup', 'type': 'boolean',
     'apply': 'restart', 'help': '', 'value': False},
    {'name': 'tax_standard_utc_offset_minutes', 'label': 'Offset', 'type': 'integer',
     'min': 0, 'max': 840, 'apply': 'hot', 'value': 600},
    {'name': 'tax_max_prices_per_backfill', 'label': 'Price budget', 'type': 'integer',
     'min': 1, 'max': 500, 'apply': 'hot', 'value': 200},
    {'name': 'tax_price_pause_ms', 'label': 'Price request delay', 'type': 'integer',
     'min': 0, 'max': 5000, 'apply': 'hot', 'value': 250},
]


class TaxRoleBrowser(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            from playwright.sync_api import sync_playwright
        except ImportError:
            raise unittest.SkipTest('Playwright not installed')
        browser = shutil.which('chromium') or shutil.which('chromium-browser')
        if not browser:
            raise unittest.SkipTest('Chromium unavailable')
        cls.pw = sync_playwright().start()
        cls.browser = cls.pw.chromium.launch(headless=True, executable_path=browser,
                                             args=['--no-sandbox'])

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, 'browser'):
            cls.browser.close()
            cls.pw.stop()

    def setUp(self):
        self.page = self.browser.new_page()
        self.addCleanup(self.page.close)
        tpl = render_template(HTML.read_text(), {'tax_enabled': False})
        self.page.set_content('<div id="node-tax-reports-tab">' + tpl + '</div>')
        self.page.evaluate('''(fields) => {
          window.__calls = [];
          window.fetch = async (url, opts = {}) => {
            window.__calls.push({url: String(url), method: opts.method || 'GET',
              headers: opts.headers || {}, body: opts.body || null});
            const post = opts.method === 'POST';
            const config = {version: post ? 'v2' : 'v1',
              fields: fields.map(f => ({...f})),
              pending_restart: post ? ['damage.tax_enabled', 'damage.tax_cln_owner'] : [],
              restart_required: post, running: false};
            if (post) for (const [name, value] of Object.entries(JSON.parse(opts.body).changes)) {
              const target = config.fields.find(f => f.name === name);
              if (target) target.value = value;
            }
            return new Response(JSON.stringify(config), {status: 200,
              headers: {'content-type': 'application/json'}});
          };
        }''', FIELD_DATA)
        self.page.add_script_tag(content=JS.read_text(), type='module')
        self.page.locator('#tax-setting-tax_cln_owner').wait_for()

    def test_disabled_service_allows_tax_only_configuration(self):
        self.assertTrue(self.page.locator('#tax-configuration').is_visible())
        self.assertEqual(7, self.page.locator('#tax-settings-fields input').count())
        self.assertEqual(0, self.page.locator('#tax-reports-enabled').count())
        self.page.locator('#tax-setting-tax_cln_owner').fill(OWNER)
        self.page.locator('#tax-setting-tax_enabled').check()
        self.page.locator('#tax-settings-save').click()
        self.page.locator('#tax-settings-status').filter(has_text='Restart DamageBDD').wait_for(timeout=5000)
        calls = self.page.evaluate('window.__calls')
        mutation = [c for c in calls if c['method'] == 'POST'][0]
        self.assertEqual('/api/node/tax/settings', mutation['url'])
        self.assertEqual('1', mutation['headers']['X-Damage-Tax-Request'])
        self.assertEqual('application/json', mutation['headers']['Content-Type'])
        body = json.loads(mutation['body'])
        self.assertEqual('v1', body['version'])
        self.assertEqual({'tax_enabled': True, 'tax_cln_owner': OWNER}, body['changes'])
        self.assertTrue(self.page.locator('#tax-settings-restart').is_visible())

    def test_refuses_to_enable_without_owner(self):
        self.page.locator('#tax-setting-tax_enabled').check()
        self.page.locator('#tax-settings-save').click()
        self.assertIn('valid CLN tax owner', self.page.locator('#tax-settings-status').inner_text())
        self.assertFalse(any(c['method'] == 'POST' for c in self.page.evaluate('window.__calls')))


if __name__ == '__main__':
    unittest.main()
