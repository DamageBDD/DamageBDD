"""Source contracts for task-focused navigation. No cloud or account writes.
Run: python3 apps/ecai/test/test_console_sidebar.py
"""
from html.parser import HTMLParser
from pathlib import Path
import re
import unittest

APP = Path(__file__).resolve().parents[1]

class Nodes(HTMLParser):
    def __init__(self):
        super().__init__(); self.nodes = []
    def handle_starttag(self, tag, attrs): self.nodes.append((tag, dict(attrs)))

class SidebarContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.html = (APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
        cls.js = (APP/'priv/static/js/ecai-console.js').read_text()
        cls.settings = (APP/'priv/static/js/ecai-console-settings.js').read_text()
        cls.css = (APP/'priv/static/css/ecai-sidebar-settings.css').read_text()
        cls.tree = Nodes(); cls.tree.feed(cls.html)

    def test_single_shell_status(self):
        self.assertNotIn('topbarRuntime', self.html)
        self.assertNotIn('topbarRuntime', self.js)
        sidebar = self.html.split('<aside',1)[1].split('</aside>',1)[0]
        self.assertEqual(sidebar.count('id="sidebarStatusDot"'),1)
        self.assertNotIn('e<span>·</span>', sidebar)
        self.assertIn('classList.toggle("online", online)', self.js)
        self.assertIn('id="sidebarNodeState" role="status"', sidebar)

    def test_settings_at_bottom_and_legacy_shortcuts_removed(self):
        footer = self.html.split('<div class="sidebar-bottom">',1)[1].split('</nav>',1)[0]
        views = re.findall(r'data-view="([^"]+)"',footer)
        self.assertEqual(views,['account','compute','keys','node-settings'])
        self.assertNotIn('EXISTING TOOLS', self.html)
        self.assertNotIn('Legacy chat', footer)
        # Tools are removed from navigation, not deleted from the application.
        self.assertIn('href="/indexer/advanced"', self.html)

    def test_task_order_and_advanced_disclosure(self):
        before_more = self.html.split('id="consoleNav"',1)[1].split('<details class="sidebar-tools"',1)[0]
        views = re.findall(r'data-view="([^"]+)"',before_more)
        self.assertEqual(views[:3],['overview','chat','search'])
        self.assertEqual(views[3:6],['indexing','knowledge','wikimedia'])
        self.assertIn('id="sidebarMoreTools"',self.html)
        self.assertIn('if (more) more.open = true',self.settings)
        for id_ in ['indexPoolNav','codeAdminNav']:
            node = next(a for t,a in self.tree.nodes if a.get('id')==id_)
            self.assertIn('hidden',node)

    def test_unique_ids_and_valid_routes(self):
        ids = [a['id'] for _,a in self.tree.nodes if 'id' in a]
        self.assertEqual(len(ids),len(set(ids)))
        for view in ['account','node-settings']:
            self.assertEqual(len([a for _,a in self.tree.nodes if a.get('data-panel')==view]),1)
            self.assertIn('"'+view+'"',self.js)
        self.assertIn('EcaiConsoleSettings?.navigated(view, previous)',self.js)
        self.assertIn('EcaiConsoleSettings?.refresh()',self.js)

    def test_no_new_privileged_transport_or_fake_profile_saves(self):
        for forbidden in ['fetch(', 'localStorage', 'sessionStorage', '.innerHTML', 'getToken(', 'location.reload(']:
            self.assertNotIn(forbidden,self.settings)
        self.assertIn("$('logoutBtn')?.click()",self.settings)
        self.assertIn('s.nodeAdmin === true',self.settings)
        self.assertIn("focusSection('code', 'codeSettingsPanel')",self.settings)
        self.assertIn('No settings are changed',self.settings.replace('no settings are changed','No settings are changed'))

    def test_asset_loading_and_mobile_accessibility(self):
        self.assertIn('ecai-sidebar-settings.css?v=sidebar-settings-v1',self.html)
        self.assertIn('ecai-console-settings.js?v=sidebar-settings-v1',self.js)
        self.assertIn('sidebar-settings-v1',re.search(r'src="([^"]*ecai-console.js[^"]*)"',self.html)[1])
        for token in ['drawer.inert', 'aria-expanded', "event.key === 'Escape'", 'first?.focus()', 'last?.focus()']:
            self.assertIn(token,self.settings)
        self.assertIn('@media (max-height: 600px)',self.css)
        self.assertIn('prefers-reduced-motion',self.css)

if __name__=='__main__': unittest.main(verbosity=2)
