#!/usr/bin/env python3
"""Static/templated dashboard contract: one server-rendered admin section.

Does not replace live authentication tests; settings/context handlers enforce RBAC.
"""
import sys
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent))
from bdd_composer_browser_test import render_template

TPL = ROOT / 'priv/templates/ui/dashboard'


def fragment(name, admin):
    return render_template((TPL / name).read_text(), {'node_admin': admin, 'authenticated': True})


class NodeAdminNavigationTest(unittest.TestCase):
    def test_single_group_for_admin(self):
        sidebar = fragment('sidebar.mustache', True)
        self.assertEqual(sidebar.count('id="dashboard-group-node"'), 1)
        for marker in ('dashboard-link-node-settings', 'dashboard-link-node-context',
                       'dashboard-link-node-transactions', 'dashboard-link-node-channels',
                       'dashboard-link-node-cln-admin'):
            self.assertEqual(sidebar.count(f'id="{marker}"'), 1)
        self.assertIn('href="/dashboard/node/settings"', sidebar)
        self.assertIn('href="#node-context-tab"', sidebar)
        self.assertEqual(sidebar.count('Node administration</h2>'), 1)

    def test_no_admin_navigation_or_panel_for_regular_account(self):
        sidebar = fragment('sidebar.mustache', False)
        shell = fragment('page_shell.mustache', False)
        for marker in ('dashboard-group-node', 'dashboard-link-node-settings',
                       'dashboard-link-node-context', 'node-context-tab'):
            self.assertNotIn(marker, sidebar)
            self.assertNotIn(marker, shell)
        self.assertIn('dashboard-link-settings', sidebar)

    def test_node_context_moved_out_of_account_settings(self):
        account = fragment('settings_tab.mustache', True)
        node = fragment('node_context_tab.mustache', True)
        shell = fragment('page_shell.mustache', True)
        self.assertIn('Account settings', account)
        self.assertNotIn('node-context-settings', account)
        self.assertNotIn('NODE ADMINISTRATION', account)
        self.assertEqual(node.count('id="node-context-settings"'), 1)
        self.assertIn('id="node-context-editor"', node)
        self.assertIn('id="node-context-tab"', shell)
        self.assertIn('{{{node_context_tab}}}', (TPL / 'page_shell.mustache').read_text())
        self.assertNotIn('data-requires-capability="account_context"', node)

    def test_only_one_navigation_implementation(self):
        shell = (TPL / 'page_shell.mustache').read_text()
        self.assertNotIn('damage-node-settings-nav.js', shell)
        self.assertFalse((ROOT / 'priv/static/js/damage-node-settings-nav.js').exists())
        self.assertFalse((ROOT / 'priv/static/css/damage-node-settings-nav.css').exists())
        render = (ROOT / 'src/damage_dashboard.erl').read_text()
        self.assertIn('node_context_tab => NodeContextTab', render)
        self.assertIn('render_tpl(?TPL("node_context_tab.mustache"), Ctx)', render)

    def test_server_guards_preserved(self):
        settings = (ROOT / 'src/damage_settings_http.erl').read_text()
        ctx = (ROOT / 'src/damage_context.erl').read_text()
        self.assertIn('steps_utils:is_admin(PublicKey)', settings)
        self.assertIn('is_node_action(node_context) -> true;', ctx)
        self.assertIn('is_node_admin(Authenticated)', ctx)


if __name__ == '__main__':
    unittest.main()
