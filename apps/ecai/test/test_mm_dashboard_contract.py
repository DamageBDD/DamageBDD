"""Static contract for Market Maker source bindings and fail-closed routes."""
import re
import unittest
from html.parser import HTMLParser
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
UI = APP/'priv/templates/ui/dashboard/ecai_market_maker.mustache'
SHELL = APP/'priv/templates/ui/dashboard/ecai_console.mustache'
JS = APP/'priv/static/js/ecai-market-maker.js'
API = APP/'src/ecai_mm_dashboard_http.erl'
WORKER = APP.parent/'damage/src/ecai_mm.erl'
CONFIG = APP.parent/'damage/src/ecai_mm_config.erl'

class Identifiers(HTMLParser):
    def __init__(self): super().__init__(); self.ids=[]; self.tabs=[]
    def handle_starttag(self, tag, attrs):
        a=dict(attrs)
        if 'id' in a: self.ids.append(a['id'])
        if 'data-mm-tab' in a: self.tabs.append(a['data-mm-tab'])

class MarketMakerContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fragment=UI.read_text(); cls.shell=SHELL.read_text()
        cls.js=JS.read_text(); cls.api=API.read_text()
        cls.doc=Identifiers(); cls.doc.feed(cls.fragment)

    def test_present_in_console_navigation_and_subtabs(self):
        self.assertIn('data-view="market-maker"',self.shell)
        self.assertIn('data-panel="market-maker"',self.fragment)
        self.assertIn('{{{market_maker_panel}}}',self.shell)
        self.assertEqual(self.doc.tabs,['monitor','configure','performance','audit'])
        self.assertIn('market_maker_panel => MarketMaker', (APP/'src/ecai_dashboard.erl').read_text())
        self.assertIn('ecai_mm_dashboard_http,',(APP/'src/ecai_app.erl').read_text())

    def test_all_script_bindings_exist_and_ids_are_unique(self):
        self.assertEqual(len(self.doc.ids),len(set(self.doc.ids)))
        ids=set(re.findall(r"\$\(['\"]([^'\"]+)['\"]\)",self.js))
        self.assertFalse(ids-set(self.doc.ids),ids-set(self.doc.ids))
        self.assertIn('/static/js/ecai-market-maker.js',
                      (APP/'priv/static/js/ecai-console.js').read_text())
        self.assertTrue((APP/'priv/static/css/ecai-market-maker.css').is_file())

    def test_post_requires_bearer_node_admin_and_no_live_mode(self):
        for check in ['market_maker_admin_enabled', 'market_maker_accounts',
                      'node_admins', 'resolve_oauth', 'authorization_policy',
                      'auth_mode := custodial', 'node_admin := true',
                      'market_maker_not_running', 'no-store']:
            self.assertIn(check,self.api)
        self.assertIn('expected_revision',self.api)
        self.assertIn('ecai_mm_config:from_json',self.api)
        self.assertIn('map_size(Body) =:= 2',self.api)
        self.assertNotIn('place_order',self.api)
        self.assertNotIn('cancel_batch',self.api)
        self.assertIn('execution_enabled => false',WORKER.read_text())
        self.assertNotIn('mode', re.search(r'editable\(\) ->(.*?)\.',CONFIG.read_text(), re.S).group(1))

    def test_actual_data_polling_no_inferred_fills(self):
        self.assertIn('/ecai/mm/status', self.js)
        self.assertIn('/ecai/mm/history?limit=800', self.js)
        self.assertIn('setInterval',self.js)
        self.assertIn('clearInterval',self.js)
        self.assertIn('window.confirm',self.js)
        self.assertIn('event.currentTarget.reportValidity()',self.js)
        self.assertNotIn('Math.random',self.js)
        self.assertNotIn('innerHTML',self.js)

if __name__=='__main__': unittest.main()
