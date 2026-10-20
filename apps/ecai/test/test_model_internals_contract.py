"""Standard-library contracts for Model Internals wiring and authority boundaries."""
import re
import unittest
from html.parser import HTMLParser
from pathlib import Path
APP = Path(__file__).resolve().parents[1]

class Ids(HTMLParser):
    def __init__(self):
        super().__init__(); self.ids=[]
    def handle_starttag(self, _tag, attrs):
        attrs=dict(attrs)
        if 'id' in attrs: self.ids.append(attrs['id'])

class ModelInternalsContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.html=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
        cls.js=(APP/'priv/static/js/ecai-model-internals.js').read_text()
        cls.console=(APP/'priv/static/js/ecai-console.js').read_text()
        cls.http=(APP/'src/ecai_code_admin_http.erl').read_text()
        cls.backend=(APP/'src/ecai_model_internals.erl').read_text()
        cls.pool=(APP/'src/ecai_ollama_pool.erl').read_text()

    def test_nested_panel_and_assets(self):
        code=self.html.index('data-panel="code"'); internals=self.html.index('id="modelInternalsPanel"')
        network=self.html.index('data-panel="network"')
        self.assertLess(code,internals); self.assertLess(internals,network)
        self.assertIn('role="tabpanel" aria-labelledby="codeModelInternalsTab"',self.html)
        self.assertIn('ecai-model-internals.css?v=model-internals-v1',self.html)
        self.assertIn('ecai-model-internals.js?v=model-internals-v1',self.console)

    def test_ids_and_safe_dom(self):
        parser=Ids(); parser.feed(self.html)
        self.assertEqual(len(parser.ids),len(set(parser.ids)))
        refs=set(re.findall(r'\$\("([^"\n]+)"\)',self.js))
        self.assertFalse(refs-set(parser.ids))
        for bad in ['innerHTML','eval(', 'new Function', 'localStorage', 'sessionStorage']:
            self.assertNotIn(bad,self.js)

    def test_navigation_and_identity(self):
        self.assertIn('view === "code/model-internals"',self.console)
        self.assertIn('modelInternals?.reset()',self.console)
        self.assertIn('modelInternals?.accessChanged()',self.console)
        self.assertIn('event.key === "ArrowRight"',self.console)
        self.assertIn('event.key === "ArrowLeft"',self.console)
        self.assertIn('ticket !== epoch',self.js)

    def test_routes_share_existing_node_admin_bearer_boundary(self):
        for suffix,action,method in [('', 'model_internals','get'),('/update','model_internals_update','post'),('/preview','model_internals_preview','post')]:
            self.assertIn(f'trail("/ecai/admin/code/model-internals{suffix}", {action}, {method})',self.http)
        for action in ['model_internals_update','model_internals_preview']:
            self.assertIn(f'Action =:= {action};',self.http)
        for gate in ['ecai_node_admin:can_manage_code(Account)', 'damage_auth:resolve_oauth(Token, #{})',
                     'bearer_identity_rejected','byte_size(Bin) =< ?LIMIT']:
            self.assertIn(gate,self.http)

    def test_supervision_precedes_inference(self):
        source=(APP/'src/ecai_code_security_sup.erl').read_text()
        self.assertLess(source.index('ecai_model_internals:child_spec(),'),source.index('        OllamaPool,'))
        self.assertIn('rest_for_one',source)

    def test_policy_is_pinned_before_retry_loop(self):
        self.assertIn('ecai_model_internals:prepare(Kind, Role, Opts0)',self.pool)
        self.assertIn('run_prepared_request(Kind, Role, Prompt, Opts)',self.pool)
        self.assertIn('ecai_model_internals:apply_policy(Resolved)',self.pool)
        self.assertIn('Kind =:= json orelse Kind =:= text',self.backend)
        self.assertNotIn('binary_to_atom(',self.backend)
        self.assertIn('<<"enabled">> => false',self.backend)

    def test_effective_settings_participate_in_receipt_identity(self):
        self.assertIn('output_options(client_opts(Lease, Opts))',self.pool)
        self.assertIn('system, format, model_internals',self.pool)
        worker=(APP/'src/ecai_patch_worker.erl').read_text()
        safe=worker.split('SafeMeta = maps:with(',1)[1].split('Entry = SafeMeta',1)[0]
        self.assertIn('model_internals',safe)

    def test_revision_and_durability_contract(self):
        for token in ['stale_revision','file:sync(Fd)','file:rename(Temp, File)',
                      'file:change_mode(Temp, 8#600)','binary_to_term(Bin, [safe])',
                      'exact_keys(Config','config_sha256','?MAX_EVENTS']:
            self.assertIn(token,self.backend)
        self.assertIn('revision: baseRevision',self.js)
        self.assertIn('if (!dirty) fill(data.config, data.revision)',self.js)

    def test_preview_has_no_inference_dispatch(self):
        preview=self.backend.split('preview(#{',1)[1].split('provider_atom(',1)[0]
        self.assertNotIn('ecai_ollama_pool:',preview)
        self.assertNotIn('damage_gun:',preview)
        self.assertIn('No model is loaded',self.html)
        self.assertIn('bridge_required',self.backend)

    def test_sanitized_pool_and_observations(self):
        sanitized=self.backend.split('Fields = [id, provider, roles',1)[1].split('catch exit:',1)[0]
        for secret in ['auth,','headers,','client_options,','host,']:
            self.assertNotIn(secret,sanitized)
        self.assertIn('observations_durable => false',self.backend)
        self.assertIn('maps:remove(model_internals, Safe0)',self.backend)

if __name__=='__main__': unittest.main()
