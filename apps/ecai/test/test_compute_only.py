"""Compute/index-artifact UI separation contracts; no network or chain calls."""
from pathlib import Path
from html.parser import HTMLParser
import re
import unittest

APP = Path(__file__).resolve().parents[1]
def read(p): return (APP / p).read_text()

class Tags(HTMLParser):
    def __init__(self):
        super().__init__(); self.tags = []
    def handle_starttag(self, tag, attrs): self.tags.append((tag,dict(attrs)))

class ComputeOnlyContract(unittest.TestCase):
    def test_compute_has_no_nft_forms_or_secondary_requests(self):
        fragment = read('priv/templates/ui/dashboard/compute_settings.mustache')
        js = read('priv/static/js/ecai-compute-settings.js')
        self.assertNotRegex(fragment.lower(), r'\bnft|\bmint')
        for term in ['computeMint', '/mintable', '/mint-requests', "call('/ecai/compute/policy'"]:
            self.assertNotIn(term,js)
        self.assertIn("call('/ecai/compute/budget'",js)
        self.assertIn('<h1 id="computeTitle">Compute</h1>', fragment)

    def test_real_tabs_and_keyboard_panels(self):
        tags = Tags(); tags.feed(read('priv/templates/ui/dashboard/compute_settings.mustache'))
        tabs = [a for _,a in tags.tags if a.get('role')=='tab']
        panels = {a['id'] for _,a in tags.tags if a.get('role')=='tabpanel'}
        self.assertEqual(len(tabs),3)
        self.assertEqual({a['aria-controls'] for a in tabs},panels)
        self.assertEqual([a['aria-selected'] for a in tabs],['true','false','false'])
        js=read('priv/static/js/ecai-compute-settings.js')
        for key in ['ArrowLeft','ArrowRight','Home','End']:
            self.assertIn(key,js)
        self.assertIn('Setup &amp; reservations only',read('priv/templates/ui/dashboard/compute_settings.mustache'))

    def test_nft_policy_and_history_are_under_index_jobs(self):
        shell=read('priv/templates/ui/dashboard/ecai_console.mustache')
        indexing=shell.split('data-panel="indexing"',1)[1].split('data-panel="wikimedia"',1)[0]
        for id_ in ['indexMintSettings','indexMintPolicyForm','indexMintRequestList']:
            self.assertIn(f'id="{id_}"', indexing)
        self.assertNotIn('Compute &amp; NFT', shell)
        js=read('priv/static/js/ecai-console.js')
        self.assertIn('compute: "Compute"',js)
        self.assertIn('window.EcaiIndexMintSettings?.open?.()',js)
        self.assertIn('copies', js)
        self.assertIn('/ecai/compute/mint-requests',js)

    def test_separate_scoped_policy_writes(self):
        service=read('src/ecai_compute_settings.erl')
        for action in ['compute_budget','mint_policy']:
            self.assertIn(f'handle_call({{{action}, Owner, Input}}',service)
        self.assertIn('maps:merge(maps:get(<<"budget">>, Old), Input)',service)
        http=read('src/ecai_compute_settings_http.erl')
        for route in ['/ecai/compute/policy','/ecai/compute/budget','/ecai/compute/mint-policy','/ecai/compute/mint-requests']:
            self.assertIn(route,http)
        for guard in ['explicit_bearer_required','auth_mode := custodial','job_not_owned_or_not_ready']:
            self.assertIn(guard,http)
        js=read('priv/static/js/ecai-index-mint-settings.js')
        self.assertIn("request('/ecai/compute/mint-policy', body)",js)
        self.assertNotIn("request('/ecai/compute/policy'",js)
        self.assertNotIn('/mint-requests',js)

    def test_mint_settings_dom_and_asset_contracts(self):
        shell=read('priv/templates/ui/dashboard/ecai_console.mustache')
        ids=re.findall(r'id="([^"]+)"',shell)
        self.assertEqual(len(ids),len(set(ids)))
        js=read('priv/static/js/ecai-index-mint-settings.js')
        used=set(re.findall(r"\$\('([^']+)'\)",js))
        self.assertTrue(used.issubset(ids),used-set(ids))
        for asset in ['css/ecai-index-mint-settings.css','js/ecai-index-mint-settings.js']:
            self.assertIn('/static/'+asset+'?v=index-mint-settings-v1',shell)
            self.assertTrue((APP/'priv/static'/asset).is_file())
        self.assertIn("document.addEventListener('ecai:identity-changed'",js)
        self.assertIn('identity !== token()',js)
        self.assertNotIn('.innerHTML',js)

if __name__ == '__main__': unittest.main()
