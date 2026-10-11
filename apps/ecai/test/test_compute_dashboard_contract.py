"""Source-level contract checks for Compute & NFTs dashboard integration.

Run without Erlang or DamageBDD test environment:
    python3 -m unittest apps/ecai/test/test_compute_dashboard_contract.py
"""
from html.parser import HTMLParser
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

def source(rel):
    return (ROOT / rel).read_text()

class HtmlIds(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []
        self.panel = []
        self.nav = []
    def handle_starttag(self, name, attrs):
        props = dict(attrs)
        if 'id' in props:
            self.ids.append(props['id'])
        if 'data-panel' in props:
            self.panel.append(props['data-panel'])
        if 'data-view' in props:
            self.nav.append(props['data-view'])

class ComputeDashboardContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shell = source('priv/templates/ui/dashboard/ecai_console.mustache')
        cls.fragment = source('priv/templates/ui/dashboard/compute_settings.mustache')
        cls.console_js = source('priv/static/js/ecai-console.js')
        cls.js = source('priv/static/js/ecai-compute-settings.js')
        cls.server = source('src/ecai_compute_settings.erl')
        cls.http = source('src/ecai_compute_settings_http.erl')
        cls.console = HtmlIds()
        cls.console.feed(cls.shell)
        cls.compute = HtmlIds()
        cls.compute.feed(cls.fragment)

    def test_console_navigation_and_render_wiring(self):
        self.assertIn('compute', self.console.nav)
        self.assertIn('compute', self.compute.panel)
        self.assertIn('data-ecai-managed', self.fragment)
        self.assertIn('{{{compute_settings_panel}}}', self.shell)
        self.assertIn('compute_settings_panel => ComputeSettings', source('src/ecai_dashboard.erl'))
        self.assertIn('ecai_compute_settings_http,', source('src/ecai_app.erl'))
        self.assertIn('maybe_compute_specs()', source('src/ecai_sup.erl'))
        self.assertIn('window.EcaiComputeSettings?.init(', self.console_js)
        self.assertIn('window.EcaiComputeSettings?.clear()', self.console_js)
        self.assertIn('case "compute":', self.console_js)
        self.assertIn('"indexOpenCompute"', self.console_js)
        self.assertIn('setSourceJob(selected)', self.console_js)

    def test_css_and_scripts_are_linked_and_available(self):
        self.assertIn('/static/css/ecai-compute-settings.css', self.shell)
        self.assertIn('/static/js/ecai-compute-settings.js', self.shell)
        self.assertTrue((ROOT / 'priv/static/css/ecai-compute-settings.css').exists())
        self.assertEqual(len(self.compute.ids), len(set(self.compute.ids)),
                         'Compute form IDs must remain unique')
        all_ids = set(self.compute.ids + self.console.ids)
        literals = set(re.findall(r"\$\(['\"]([^'\"]+)['\"]\)", self.js))
        self.assertFalse(literals - all_ids, sorted(literals - all_ids))

    def test_routes_and_browser_contract(self):
        for path in ['/ecai/compute/settings','/ecai/compute/eligible-sources',
                     '/ecai/compute/mintable','/ecai/compute/policy',
                     '/ecai/compute/providers/:provider',
                     '/ecai/compute/reservations', '/ecai/compute/mint-requests']:
            self.assertIn(path, self.http)
        self.assertIn('resolve_oauth', self.http)
        self.assertIn('auth_mode := custodial', self.http)
        self.assertIn('explicit_bearer_required', self.http)
        self.assertIn('expected_reserve_cents', self.http)
        self.assertIn('expected_reserve_cents', self.js)
        self.assertIn('eligible_source(Job, Owner)', self.http)
        self.assertIn('maps:get(<<"owner">>, Spec, undefined) =:= Owner', self.http)
        self.assertIn('data-ecai-managed', self.fragment)

    def test_safe_state_and_no_implicit_billing_or_mint(self):
        for predicate in ['<<"remote_enabled">> => false',
                          '<<"monthly_cents">> => 0',
                          '<<"mint_monthly_cents">> => 0',
                          '<<"enabled">> => false',
                          '<<"awaiting_dispatch">>',
                          '<<"awaiting_wallet_signature">>',
                          '"compute_settings.dets"']:
            self.assertIn(predicate, self.server)
        self.assertIn('actual_billed_cents', self.server)
        self.assertIn('<<"status">> => <<"unverified">>', self.server)
        self.assertNotIn('ecai_nft:mint', self.http)
        self.assertNotIn('batch:SubmitJob', self.http)

if __name__ == '__main__':
    unittest.main()
