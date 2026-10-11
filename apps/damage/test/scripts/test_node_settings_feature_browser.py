"""Browser contract for grouping and names-only node configuration discovery.

This uses local static fixtures; authorization is enforced by the Cowboy handler
and must be tested separately with an authenticated node-admin session.
"""
import json
import re
import shutil
import unittest
from pathlib import Path

DAMAGE = Path(__file__).resolve().parents[2]
PRIV = DAMAGE / 'priv' / 'static'
FIXTURE = {
    'app': 'bop', 'version': 'v-fixture', 'last_error': None, 'pending_restart': [],
    'config_file': '/var/lib/damage/.config/damage/damage.config',
    'groups': [
        {'id': 'runtime', 'label': 'HTTP & node services', 'description': 'BOP listener'},
        {'id': 'identity', 'label': 'Nostr & identity', 'description': 'Protected identity'},
    ],
    'fields': [
        {'name': 'port', 'group': 'runtime', 'label': 'BOP HTTP port',
         'type': 'integer', 'min': 1, 'max': 65535, 'apply': 'restart',
         'source': 'sys.config', 'value': 8090, 'overridden': False},
    ],
    'discovered': [
        {'name': 'pools', 'group': 'runtime', 'restriction': 'unmodeled'},
        {'name': 'keystore', 'group': 'identity', 'restriction': 'protected'},
    ],
}


class FeatureSettingsBrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            from playwright.sync_api import sync_playwright
        except ImportError:
            raise unittest.SkipTest('Playwright is not installed')
        chromium = shutil.which('chromium') or shutil.which('chromium-browser')
        if not chromium:
            raise unittest.SkipTest('Chromium is not installed')
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch(headless=True, executable_path=chromium, args=['--no-sandbox'])

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, 'browser'):
            cls.browser.close()
            cls.playwright.stop()

    def render(self, app='bop', fixture=None):
        # Each document needs its own JS realm because the editor uses top-level const.
        self.page = self.browser.new_page()
        self.addCleanup(self.page.close)
        html = (PRIV / 'settings' / 'index.html').read_text().replace('__APP__', app)
        html = re.sub(r'<script[^>]*src="[^"]*"[^>]*></script>', '', html)
        html = re.sub(r'<link[^>]*rel="stylesheet"[^>]*>', '', html)
        self.page.set_content(html)
        self.page.add_style_tag(content=(PRIV / 'css' / 'settings.css').read_text())
        payload = {**(fixture or FIXTURE), 'app': app}
        self.page.evaluate('(data) => { window.fetch = async () => ({ok:true, status:200, json: async () => data}); }', payload)
        self.page.add_script_tag(content=(PRIV / 'js' / 'damage-config-editor.js').read_text())
        label = 'DamageBDD' if app == 'damage' else 'BOP'
        self.page.locator('#settings-app-name').filter(has_text=label).wait_for()

    def test_tax_settings_group_and_restart_warning(self):
        fixture = {
            'version': 'tax-fixture', 'pending_restart': ['damage.tax_enabled'],
            'config_file': '/var/lib/damage/.config/damage/damage.config',
            'groups': [{'id': 'tax', 'label': 'Tax & provenance',
                        'description': 'Tax evidence'}],
            'fields': [
                {'name': 'tax_enabled', 'group': 'tax', 'label': 'Enable ATO tax reporting',
                 'type': 'boolean', 'apply': 'restart', 'source': 'default',
                 'value': False, 'overridden': False, 'help': 'Restart to enable.'},
                {'name': 'tax_cln_owner', 'group': 'tax', 'label': 'CLN tax owner',
                 'type': 'ae_account', 'apply': 'restart', 'source': 'unset',
                 'value': None, 'overridden': False, 'help': 'Legal owner of CLN history.'},
            ],
            'discovered': [{'name': 'tax_cryptocompare_key', 'group': 'tax',
                            'restriction': 'protected'}]
        }
        self.render('damage', fixture=fixture)
        self.assertTrue(self.page.locator('#settings-feature-tax').is_visible())
        self.assertEqual('Restart required', self.page.locator('#settings-runtime-status').inner_text())
        self.assertEqual('checkbox', self.page.locator('#setting-tax_enabled').get_attribute('type'))
        self.assertEqual('text', self.page.locator('#setting-tax_cln_owner').get_attribute('type'))
        self.assertEqual(0, self.page.locator('.settings-tax-reports-link').count())
        self.assertIn('Restart the node', self.page.locator('.settings-tax-not-ready').inner_text())
        self.page.locator('#setting-tax_enabled').check()
        self.page.locator('#setting-tax_cln_owner').fill('ak_22222222222222222222222222222222222222222222222222222')
        self.assertTrue(self.page.locator('#settings-save').is_enabled())
        self.page.locator('#settings-search').fill('tax_cryptocompare_key')
        self.assertEqual(0, self.page.locator('#setting-tax_cryptocompare_key').count())
        self.assertEqual('Protected', self.page.locator('.settings-discovered-status.protected').inner_text())

    def test_tax_group_visible_before_enablement(self):
        """A disabled service must remain discoverable and configurable."""
        fixture = {
            'version': 'tax-disabled', 'pending_restart': [],
            'groups': [{'id': 'tax', 'label': 'Tax & provenance',
                        'description': 'Australian FY evidence'}],
            'fields': [
                {'name': 'tax_enabled', 'group': 'tax', 'label': 'Enable ATO tax reporting',
                 'type': 'boolean', 'apply': 'restart', 'source': 'default',
                 'value': False, 'overridden': False},
                {'name': 'tax_cln_owner', 'group': 'tax', 'label': 'CLN tax owner',
                 'type': 'ae_account', 'apply': 'restart', 'source': 'unset',
                 'value': None, 'overridden': False},
            ],
            'discovered': []
        }
        self.render('damage', fixture=fixture)
        self.assertTrue(self.page.locator('a[data-feature="tax"]').is_visible())
        self.assertTrue(self.page.locator('#settings-feature-tax').is_visible())
        self.assertEqual(False, self.page.locator('#setting-tax_enabled').is_checked())
        self.assertIn('Enable tax reporting',
                      self.page.locator('.settings-tax-not-ready').inner_text())
        self.assertEqual(0, self.page.locator('.settings-tax-reports-link').count())

    def test_tax_reports_link_after_restart(self):
        fixture = {
            'version': 'tax-enabled', 'pending_restart': [],
            'groups': [{'id': 'tax', 'label': 'Tax & provenance',
                        'description': 'Australian FY evidence'}],
            'fields': [
                {'name': 'tax_enabled', 'group': 'tax', 'label': 'Enable ATO tax reporting',
                 'type': 'boolean', 'apply': 'restart', 'source': 'damage.config',
                 'value': True, 'overridden': True},
            ],
            'discovered': []
        }
        self.render('damage', fixture=fixture)
        self.assertTrue(self.page.locator('#setting-tax_enabled').is_checked())
        self.assertEqual('/node/admin/tax',
                         self.page.locator('.settings-tax-reports-link').get_attribute('href'))

    def test_sidebar_exposes_setup_and_reports_for_admins(self):
        sidebar = (DAMAGE / 'priv' / 'templates' / 'ui' / 'dashboard' /
                   'sidebar.mustache').read_text()
        self.assertIn('{{#node_admin}}', sidebar)
        enabled = re.search(r'\{\{#tax_enabled\}\}(.*?)\{\{/tax_enabled\}\}',
                            sidebar, re.S)
        disabled = re.search(r'\{\{\^tax_enabled\}\}(.*?)\{\{/tax_enabled\}\}',
                             sidebar, re.S)
        self.assertIsNotNone(enabled)
        self.assertIsNotNone(disabled)
        self.assertIn('id="dashboard-link-tax-evidence"', enabled.group(1))
        self.assertIn('href="/node/admin/tax"', enabled.group(1))
        self.assertIn('id="dashboard-link-tax-setup"', disabled.group(1))
        self.assertIn('href="/dashboard/node/settings/damage#settings-feature-tax"',
                      disabled.group(1))

    def test_groups_and_five_apps(self):
        self.render()
        self.page.locator('#settings-field-count').filter(has_text='1').wait_for()
        self.assertEqual('/var/lib/damage/.config/damage/damage.config',
                         self.page.locator('#settings-config-path').inner_text())
        self.assertEqual(5, self.page.locator('[data-app-tab]').count())
        self.assertEqual(2, self.page.locator('.settings-feature-section').count())
        self.assertEqual('BOP HTTP port', self.page.locator('.settings-field-title').inner_text())
        self.assertEqual('2 additional keys discovered', self.page.locator('#settings-discovered-count').inner_text())

    def test_protected_names_never_reveal_values(self):
        self.render()
        self.page.locator('input#settings-search').fill('keystore')
        self.assertTrue(self.page.locator('#settings-feature-identity').is_visible())
        self.assertFalse(self.page.locator('#settings-feature-runtime').is_visible())
        self.assertEqual('Protected', self.page.locator('.settings-discovered-status.protected').inner_text())
        self.assertEqual('keystore', self.page.locator('#settings-feature-identity .settings-discovered-key code').inner_text())
        self.assertEqual(0, self.page.locator('#setting-keystore').count())

    def test_feature_search_and_edit_controls(self):
        self.render()
        self.page.locator('#settings-search').fill('HTTP & node services')
        self.assertTrue(self.page.locator('#setting-port').is_visible())
        self.page.locator('#setting-port').fill('9000')
        self.assertTrue(self.page.locator('#settings-save').is_enabled())


if __name__ == '__main__':
    unittest.main()
