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
    def test_public_kernel_widget_uses_math_panel_and_native_assets(self):
        shell=src('priv/templates/ui/dashboard/ecai_console.mustache')
        fragment=src('priv/templates/ui/dashboard/ecai_math_paths.mustache')
        console=src('priv/static/js/ecai-console.js')
        kernel=src('priv/static/js/ecai-math-kernel.js')
        self.assertIn('id="mathKernel"',fragment)
        self.assertLess(fragment.index('id="mathKernelTitle"'),fragment.index('id="mathLibraryTitle"'))
        self.assertLess(fragment.index('id="mathLibraryTitle"'),fragment.index('id="mathBuilderDisclosure"'))
        self.assertIn('/static/css/ecai-math-kernel.css?v=elliptic-kernel-v1',shell)
        self.assertIn('/static/js/ecai-math-kernel.js?v=elliptic-kernel-v1',console)
        for text in ('initMathKernel()', 'mathKernel?.setVisible(view === "math")',
                     'mathKernel?.dispose()'):
            self.assertIn(text,console)
        for text in ('realOvalPoint(', 'fourierCoefficients(', 'fourierPoint(',
                     'prefers-reduced-motion', 'IntersectionObserver', 'AbortController'):
            self.assertIn(text,kernel)
        for forbidden in ('fetch(', 'XMLHttpRequest', 'localStorage', 'sessionStorage',
                          'innerHTML', 'eval(', 'https://', 'http://'):
            self.assertNotIn(forbidden,kernel)
        self.assertIn('static/',src('src/ecai_app.erl'))

    def test_3d_geometry_lab_is_local_and_mint_hand_off_only(self):
        shell=src('priv/templates/ui/dashboard/ecai_console.mustache')
        fragment=src('priv/templates/ui/dashboard/ecai_math_paths.mustache')
        console=src('priv/static/js/ecai-console.js')
        visual=src('priv/static/js/ecai-math-3d.js')
        paths=src('priv/static/js/ecai-math-paths.js')
        self.assertIn('id="math3DWorkbench"',fragment)
        self.assertIn('id="math3DPrepare"',fragment)
        self.assertLess(fragment.index('id="mathKernel"'),fragment.index('id="math3DWorkbench"'))
        self.assertLess(fragment.index('id="math3DWorkbench"'),fragment.index('id="mathLibrary"'))
        self.assertIn('/static/css/ecai-math-3d.css?v=geometry-lab-v1',shell)
        self.assertIn('/static/js/ecai-math-3d.js?v=geometry-lab-v1',console)
        self.assertIn('math3D?.setVisible(view === "math")',console)
        self.assertIn('math3D?.dispose()',console)
        self.assertIn('initMath3D()',console)
        self.assertIn('"math3DWorkbench"',paths)
        for term in ('generate3DMesh', 'meshToOBJ','sha256Fallback', 'experimentBundle',
                     'exact_isogeny:false','blockchain_transactions:0'):
            self.assertIn(term,visual)
        for forbidden in ('fetch(', 'XMLHttpRequest', 'localStorage', 'sessionStorage',
                          'innerHTML', 'eval(', 'ethereum.request', 'private_key'):
            self.assertNotIn(forbidden,visual)
        self.assertIn('No IPFS upload, payment, signature or blockchain transaction',fragment)
        ids=IDs();ids.feed(fragment)
        self.assertEqual(len(ids.ids),len(set(ids.ids)))

    def test_guided_exploration_and_scoped_links(self):
        fragment=src('priv/templates/ui/dashboard/ecai_math_paths.mustache')
        paths=src('priv/static/js/ecai-math-paths.js')
        css=src('priv/static/css/ecai-math-paths.css')
        order=['mathKernel','mathLibrary','mathBuilderDisclosure','mathResults','mathECAIBridge']
        self.assertEqual(len(order),len(set(order)))
        for a,b in zip(order,order[1:]):
            self.assertLess(fragment.index(f'id="{a}"'),fragment.index(f'id="{b}"'))
        for id in order:
            self.assertIn(f'data-math-jump="{id}"',fragment)
        for anchor in ('https://doc.sagemath.org/html/en/reference/arithmetic_curves/index.html',
                       'https://doc.sagemath.org/html/en/reference/arithmetic_curves/sage/schemes/elliptic_curves/ell_curve_isogeny.html',
                       'https://www.3blue1brown.com/lessons/fourier-series/',
                       'https://damagebdd.com/ecai/'):
            self.assertIn(anchor,fragment)
        self.assertIn('data-go="search"',fragment)
        self.assertIn('A verified curve map is',fragment)
        self.assertIn('not automatically a verified relationship',fragment)
        self.assertIn('jumpToMathStep(',paths)
        self.assertIn('destination.scrollIntoView(',paths)
        self.assertIn('aria-current',paths)
        self.assertNotIn('location.hash =',paths)
        self.assertIn('.math-journey-steps',css)
        self.assertIn('math-guided-journey-v1',src('priv/templates/ui/dashboard/ecai_console.mustache'))
        self.assertIn('math-guided-journey-v1',src('priv/static/js/ecai-console.js'))

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
        self.assertIn("kind==='path'?r.path_json",s)
        self.assertIn('URL.revokeObjectURL',s)
    def test_owner_scoping_and_retention(self):
        s=src('src/ecai_math_dashboard_srv.erl')
        self.assertIn('#{owner := Owner}',s)
        self.assertIn('length(AllActive) >= 2',s)
        self.assertIn('-define(MAX_OWNER_RECORDS, 8)',s)
        self.assertIn('math_dashboard_disabled',s)
if __name__=='__main__':unittest.main()
