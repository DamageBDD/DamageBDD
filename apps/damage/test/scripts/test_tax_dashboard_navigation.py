#!/usr/bin/env python3
"""Contract tests for SSR admin tax reports panel; not a substitute for live RBAC tests."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent))
from bdd_composer_browser_test import render_template

TEMPLATE_DIR = ROOT / 'priv/templates/ui/dashboard'


def render(name, **context):
    return render_template((TEMPLATE_DIR / name).read_text(), context)


class AdminTaxDashboardTest(unittest.TestCase):
    def test_admin_navigation_visible_when_service_disabled(self):
        sidebar = render('sidebar.mustache', node_admin=True, tax_enabled=False)
        self.assertIn('href="#node-tax-reports-tab"', sidebar)
        self.assertEqual(sidebar.count('dashboard-link-node-tax-reports'), 1)
        self.assertNotIn('dashboard-link-tax-setup', sidebar)
        self.assertIn('dashboard-link-node-settings', sidebar)
        tab = render('node_tax_reports_tab.mustache', tax_enabled=False)
        self.assertIn('Tax reporting is disabled', tab)
        self.assertIn('#tax-settings-heading', tab)
        self.assertIn('id="tax-settings-form"', tab)
        self.assertNotIn('id="tax-reports-enabled"', tab)

    def test_enabled_admin_panel_filters_exports_and_backfill(self):
        tab = render('node_tax_reports_tab.mustache', tax_enabled=True)
        for marker in ['tax-reports-enabled', 'tax-filter-year', 'tax-filter-status',
                       'tax-filter-revisions', 'tax-filter-search', 'tax-export-csv',
                       'tax-export-json', 'tax-backfill-form', 'tax-reports-rows']:
            self.assertIn('id="' + marker + '"', tab)
        self.assertNotIn('Tax reporting is disabled', tab)
        self.assertIn('tax-settings-save', tab)
        self.assertIn('not lodged ATO returns', tab)

    def test_non_admin_cannot_navigate_or_receive_embedded_panel(self):
        sidebar = render('sidebar.mustache', node_admin=False, tax_enabled=True)
        shell = render('page_shell.mustache', authenticated=True, node_admin=False, tax_admin=False)
        self.assertNotIn('dashboard-link-node-tax-reports', sidebar)
        self.assertNotIn('id="node-tax-reports-tab"', shell)
        self.assertNotIn('dashboard-tax-reports.js', shell)

    def test_tax_only_admin_sees_tax_nav_without_node_administration(self):
        sidebar = render('sidebar.mustache', node_admin=False, tax_admin=True,
                         tax_only_admin=True, tax_enabled=False)
        self.assertIn('Tax administration', sidebar)
        self.assertIn('dashboard-link-node-tax-reports', sidebar)
        self.assertNotIn('dashboard-link-node-settings', sidebar)
        self.assertNotIn('dashboard-link-node-cln-admin', sidebar)
        shell = render('page_shell.mustache', authenticated=True, node_admin=False,
                       tax_admin=True)
        self.assertIn('id="node-tax-reports-tab"', shell)
        self.assertNotIn('id="node-cln-admin-tab"', shell)
        self.assertIn('/static/js/dashboard-tax-settings.js', shell)

    def test_admin_panel_registered_with_primary_dashboard_navigation(self):
        shell = render('page_shell.mustache', authenticated=True, node_admin=True, tax_admin=True)
        self.assertIn('id="node-tax-reports-tab"', shell)
        self.assertIn('aria-labelledby="dashboard-link-node-tax-reports"', shell)
        self.assertIn('/static/js/dashboard-tax-reports.js', shell)
        self.assertIn('/static/js/dashboard-tax-settings.js', shell)
        erl = (ROOT / 'src/damage_dashboard.erl').read_text()
        self.assertIn('node_tax_reports_tab => NodeTaxReportsTab', erl)
        self.assertIn('render_component(node_tax_reports_tab, #{tax_admin := true}', erl)
        self.assertIn('render_component(node_tax_reports_tab, _Ctx) ->', erl)

    def test_tax_data_endpoints_keep_existing_node_admin_gate(self):
        handler = (ROOT / 'src/damage_tax_http.erl').read_text()
        self.assertIn('damage_tax_access:allowed(State)', handler)
        self.assertIn('"/api/node/tax/settings"', handler)
        self.assertIn('damage_tax_catalog:download', handler)
        self.assertIn('<<"cache-control">> => <<"no-store, private">>', handler)


if __name__ == '__main__':
    unittest.main()
