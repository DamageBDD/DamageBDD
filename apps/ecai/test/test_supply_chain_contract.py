"""Source/markup and checksum tests. These do not execute Erlang or Cowboy."""
import hashlib
import importlib.util
import json
import re
import unittest
from html.parser import HTMLParser
from pathlib import Path

APP=Path(__file__).resolve().parents[1]

def read(name):return (APP/name).read_text()

class Markup(HTMLParser):
    def __init__(self):super().__init__();self.ids=[];self.panels=[]
    def handle_starttag(self,tag,attrs):
        a=dict(attrs)
        if 'id' in a:self.ids.append(a['id'])
        if 'data-panel' in a:self.panels.append(a['data-panel'])

class RecoveryContract(unittest.TestCase):
    def test_fragment_ids_and_references(self):
        p=Markup();p.feed(read('priv/templates/ui/dashboard/ecai_supply_chain.mustache'))
        self.assertEqual(len(p.ids),len(set(p.ids)))
        self.assertEqual(p.panels,['supply-chain'])
        refs=set(re.findall(r"\$\(['\"]([^'\"]+)['\"]\)",read('priv/static/js/ecai-supply-chain.js')))
        self.assertFalse(refs-set(p.ids),refs-set(p.ids))
        existing=[]
        for path in (APP/'priv/templates/ui').rglob('*.mustache'):
            if path.name=='ecai_supply_chain.mustache':continue
            m=Markup();m.feed(path.read_text());existing.extend(m.ids)
        self.assertFalse(set(p.ids)&set(existing))

    def test_shell_wiring(self):
        shell=read('priv/templates/ui/dashboard/ecai_console.mustache')
        for text in ['data-view="supply-chain"','{{{supply_chain_panel}}}','/static/css/ecai-supply-chain.css','recovery=recovery-lab-public-v2']:
            self.assertIn(text,shell)
        controller=read('priv/static/js/ecai-console.js')
        for text in ['initSupplyChain({request, currentToken, managedSession, openLogin})',
                     'supplyChain?.reset()', 'supplyChain?.accessChanged()',
                     'supplyChain?.setVisible(view === "supply-chain")','supplyChain?.dispose()',
                     'case "supply-chain": await supplyChain?.refresh();']:
            self.assertIn(text,controller)
        self.assertIn('supply_chain_panel => SupplyChain',read('src/ecai_dashboard.erl'))
        self.assertIn('ecai_supply_chain_srv:child_specs()',read('src/ecai_sup.erl'))
        self.assertIn('ecai_supply_chain_http',read('src/ecai_app.erl'))

    def test_private_and_public_api_routes_match_catalog(self):
        routes=set(re.findall(r'trail\("([^"]+)",\w+,\[(get|post)\]\)',read('src/ecai_supply_chain_http.erl')))
        catalog=set((p,m.lower()) for m,p in re.findall(r'method:\s*"(GET|POST)",\s*path:\s*"(/ecai/supply-chain[^"]*)"',read('priv/static/js/ecai-console.js')))
        self.assertEqual(len(routes),14);self.assertEqual(routes,catalog)

    def test_applications_are_public_and_grouped(self):
        shell=read('priv/templates/ui/dashboard/ecai_console.mustache')
        applications=shell.split('id="navApplicationsLabel"',1)[1].split('<details class="sidebar-tools"',1)[0]
        for view in ['supply-chain','orbital']:
            self.assertIn('data-view="'+view+'"',applications)
            self.assertEqual(shell.count('data-view="'+view+'"'),1)
        fragment=read('priv/templates/ui/dashboard/ecai_supply_chain.mustache')
        self.assertIn('Public demo · no sign-in required.',fragment)
        self.assertIn('<div id="scWorkspace">',fragment)
        self.assertNotIn('data-ecai-managed',fragment)
        js=read('priv/static/js/ecai-supply-chain.js')
        self.assertIn("const base=managed?'/ecai/supply-chain':PUBLIC_ROOT",js)
        console=read('priv/static/js/ecai-console.js')
        self.assertIn('isPublicSupplyChainRequest(pathname, method)',console)
        self.assertIn('"orbital", "supply-chain", "personalities"].includes(state.view)',console)
        self.assertIn('const publicLab = isPublicSupplyChainRequest(path, method)',console)
        self.assertIn('if (wasAuthenticated) supplyChain?.reset();',console)
        self.assertNotIn('fetch(',read('priv/static/js/ecai-orbital.js'))

    def test_ephemeral_store_and_csrf_boundaries(self):
        http=read('src/ecai_supply_chain_http.erl')
        for text in ['access => public','x-ecai-lab-request','same_site => strict','http_only => true',
                     'public_guard(', 'supply_chain_public_origin','guest_session_expired -> 410']:
            self.assertIn(text,http)
        guest=read('src/ecai_supply_chain_guest.erl')
        self.assertIn('[set,private]',guest)
        self.assertNotIn('dets:',guest)
        self.assertIn('crypto:strong_rand_bytes(32)',guest)
        for text in ['guest_rate_limited','guest_capacity','guest_session_expired','max_sessions','prune(G)']:
            self.assertIn(text,guest)
        service=read('src/ecai_supply_chain_srv.erl')
        self.assertIn('persist({guest,_}=Owner,W,St) -> ecai_supply_chain_guest:save',service)
        self.assertIn('GuestJobs<1',service)
        self.assertIn('is_binary(maps:get(owner,J)),not dets:member',service)

    def test_auth_boundaries_present(self):
        http=read('src/ecai_supply_chain_http.erl')
        for text in ['auth_mode := custodial,authenticated := true','damage_auth:authenticated_account(Auth)',
                     'explicit_bearer_required','cross_site_rejected','Size=<8192','no-store, private']:
            self.assertIn(text,http)
        self.assertNotRegex(http,r'(binary_to_atom|list_to_atom)\(')
        service=read('src/ecai_supply_chain_srv.erl')
        self.assertIn('maps:get(input_revision,P)=:=maps:get(revision,W)',service)
        self.assertIn('dets:sync(Tab)',service)
        self.assertIn('[link,monitor]',service)

    def test_independent_validator_and_no_live_spend(self):
        validator=read('src/ecai_supply_chain_validator.erl')
        self.assertNotIn('ecai_supply_chain_planner:',validator)
        self.assertNotIn('ecai_supply_chain_model:schedule',validator)
        self.assertIn('optimality_proven => false',validator)
        for path in (APP/'src').glob('ecai_supply_chain*.erl'):
            self.assertNotRegex(path.read_text(),r'\b(gun|httpc|cln|ecai_compute_settings):')
        js=read('priv/static/js/ecai-supply-chain.js')
        self.assertNotRegex(js,r'\.innerHTML\s*=|localStorage\.')
        self.assertIn('epoch!==state.epoch||token!==currentToken()',js)
        self.assertNotIn('supply_chain_browser.json',js)

class EvidenceChecksum(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec=importlib.util.spec_from_file_location('sc_verify',APP/'scripts/verify_supply_chain_evidence.py')
        cls.module=importlib.util.module_from_spec(spec);spec.loader.exec_module(cls.module)
    def evidence(self):
        text=json.dumps({'revision':2,'note':'Synthetic café'},ensure_ascii=False,separators=(',',':'))
        domain=self.module.DOMAIN
        return dict(schema=domain,domain=domain,manifest_json=text,
                    digest=hashlib.sha256(domain.encode()+b'\x00'+text.encode()).hexdigest(),authenticated_signature=False)
    def test_valid_utf8_manifest(self):self.assertEqual(self.module.verify(self.evidence())['revision'],2)
    def test_tampered_content(self):
        p=self.evidence();p['manifest_json']=p['manifest_json'].replace(':2',':3')
        with self.assertRaisesRegex(ValueError,'mismatch'):self.module.verify(p)
    def test_changed_domain(self):
        p=self.evidence();p['domain']='other'
        with self.assertRaisesRegex(ValueError,'domain'):self.module.verify(p)
    def test_missing_digest(self):
        p=self.evidence();del p['digest']
        with self.assertRaises(ValueError):self.module.verify(p)

if __name__=='__main__':unittest.main(verbosity=2)
