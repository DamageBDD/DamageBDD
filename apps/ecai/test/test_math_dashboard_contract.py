"""Static integration contract; no source text is executed as Erlang."""
import re, unittest
from pathlib import Path
from html.parser import HTMLParser
APP=Path(__file__).resolve().parents[1]
def src(p):return (APP/p).read_text()
class IDs(HTMLParser):
    def __init__(self):super().__init__();self.ids=[]
    def handle_starttag(self,tag,attrs):
        d=dict(attrs)
        if 'id' in d:self.ids.append(d['id'])
class MathDashboardContract(unittest.TestCase):
    def test_navigation_and_template(self):
        self.assertIn('data-view="math"',src('priv/templates/ui/dashboard/ecai_console.mustache'))
        self.assertIn('{{{math_paths_panel}}}',src('priv/templates/ui/dashboard/ecai_console.mustache'))
        self.assertIn('math_paths_panel => MathPaths',src('src/ecai_dashboard.erl'))
    def test_router_and_supervisor(self):
        self.assertIn('ecai_math_dashboard_http,',src('src/ecai_app.erl'))
        self.assertIn('ecai_math_dashboard_srv:child_specs()',src('src/ecai_sup.erl'))
        self.assertIn('{math_dashboard_enabled, true}',src('src/ecai.app.src'))
    def test_dom_references(self):
        fragment=src('priv/templates/ui/dashboard/ecai_math_paths.mustache');p=IDs();p.feed(fragment)
        self.assertEqual(len(p.ids),len(set(p.ids)))
        refs=set(re.findall(r"\$\(['\"]([^'\"]+)['\"]\)",src('priv/static/js/ecai-math-paths.js')))
        self.assertFalse(refs-set(p.ids))
    def test_console_lifecycle(self):
        s=src('priv/static/js/ecai-console.js')
        for text in ['initMathPaths(', 'mathPaths?.reset()', 'mathPaths?.accessChanged()',
                     'mathPaths?.dispose()', 'mathPaths?.setVisible(view === "math")','case "math":']:
            self.assertIn(text,s)
    def test_auth_and_limits(self):
        s=src('src/ecai_math_dashboard_http.erl')
        for text in ['resolve_oauth','auth_mode := custodial','explicit_bearer_required',
                     'N = Size + byte_size(Chunk)','no-store, private']:
            self.assertIn(text,s)
        self.assertNotIn('L402',s.replace('No payable auth challenges.',''))
    def test_backend_replays_and_strips_untrusted_flags(self):
        s=src('src/ecai_math_dashboard_task.erl')
        self.assertIn('ecai_math_pathfinder:verify_path(Path)',s)
        self.assertIn('ecai_math_codec:decode(Bin)',s)
        self.assertIn('independent_check => not_attached',s)
        self.assertIn('damagebdd_run => not_attached',s)
    def test_no_dynamic_html_or_client_verification(self):
        s=src('priv/static/js/ecai-math-paths.js')
        self.assertNotIn('innerHTML',s);self.assertNotIn('eval(',s)
        self.assertNotIn('localStorage',s);self.assertNotIn('sessionStorage',s)
        self.assertIn('No search-event trace',s)
    def test_no_demo_outcomes_hardcoded_in_production(self):
        for f in ['priv/static/js/ecai-math-paths.js','src/ecai_math_dashboard_task.erl']:
            s=src(f)
            self.assertNotIn('20261016201421',s)
            self.assertNotIn('QmSTqzPq',s)
            self.assertNotIn('57 tests',s)
    def test_fixture_adapters_cannot_shadow_release_modules(self):
        f=APP/'test/math_dashboard/fixtures'
        self.assertFalse(list(f.glob('*.erl')))
        self.assertTrue((f/'damage_auth.erl.fixture').exists())
    def test_no_dependency_added(self):
        s=src('priv/static/js/ecai-math-paths.js')
        self.assertNotIn('https://',s);self.assertNotIn('http://',s)
    def test_export_path_uses_original_json_bytes(self):
        s=src('priv/static/js/ecai-math-paths.js')
        self.assertIn("kind==='path'?selected.result.path_json",s)
        self.assertIn('URL.revokeObjectURL',s)
    def test_owner_scoping_and_retention(self):
        s=src('src/ecai_math_dashboard_srv.erl')
        self.assertIn('#{owner := Owner}',s)
        self.assertIn('length(AllActive) >= 2',s)
        self.assertIn('-define(MAX_OWNER_RECORDS, 8)',s)
        self.assertIn('math_dashboard_disabled',s)
if __name__=='__main__':unittest.main()
