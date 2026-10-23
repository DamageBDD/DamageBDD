"""Static wiring/security contracts; these are not Erlang execution tests."""
import re
import unittest
from html.parser import HTMLParser
from pathlib import Path
APP=Path(__file__).resolve().parents[1]
DAMAGE=APP.parent/'damage'
class Ids(HTMLParser):
    def __init__(self): super().__init__(); self.ids=[]
    def handle_starttag(self,tag,attrs):
        attrs=dict(attrs)
        if 'id' in attrs:self.ids.append(attrs['id'])
class LlmSettingsContract(unittest.TestCase):
    @classmethod
    def setUpClass(c):
        c.html=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
        c.js=(APP/'priv/static/js/ecai-llm-settings.js').read_text()
        c.console=(APP/'priv/static/js/ecai-console.js').read_text()
        c.http=(APP/'src/ecai_code_admin_http.erl').read_text()
        c.settings=(APP/'src/ecai_llm_settings.erl').read_text()
        c.pool=(APP/'src/ecai_ollama_pool.erl').read_text()
        c.client=(APP/'src/ecai_ollama_client.erl').read_text()
    def test_dom_ids_and_safe_rendering(self):
        p=Ids();p.feed(self.html);self.assertEqual(len(p.ids),len(set(p.ids)))
        refs=set(re.findall(r'\$\("([^"\n]+)"\)',self.js));self.assertFalse(refs-set(p.ids))
        for bad in ['innerHTML','localStorage','sessionStorage','new Function','eval(']:self.assertNotIn(bad,self.js)
        self.assertIn('type="password"',self.html)
    def test_shell_navigation_and_identity(self):
        for token in ['initLlmSettings','llmSettings?.reset()','llmSettings?.accessChanged()',
                      'llmSettings?.setVisible(view === "ai-providers")','case "ai-providers":']:
            self.assertIn(token,self.console)
        self.assertIn('data-go="ai-providers"',self.html)
        self.assertIn('id="llmSettingsNav" hidden',self.html)
    def test_authority_boundary(self):
        for path,action,method in [('/settings','llm_settings','get'),('/settings/update','llm_settings_update','post'),('/probe','llm_probe','post')]:
            self.assertIn(f'trail("/ecai/admin/llm{path}", {action}, {method})',self.http)
        for gate in ['damage_auth:authenticated_account','ecai_node_admin:session_is_node_admin',
                     'ecai_node_admin:can_manage_code(Account)','damage_auth:resolve_oauth(Token, #{})',
                     'bearer_identity_rejected','<<"cache-control">> => <<"no-store">>']:
            self.assertIn(gate,self.http)
    def test_credentials_never_persisted_as_values(self):
        for token in ['maps:remove(<<"api_key">>, C)','secrets:encrypt_store(node, Ref, Key)',
                      'secrets:sync()','invalid_saved_credentials','credential_destination_changed',
                      'format_status(Status)','(message, _) -> redacted']:
            self.assertIn(token,self.settings)
        self.assertIn('clearKeys(); busy = false',self.js)
        self.assertIn('for (const c of config.connections) delete c.api_key',self.js)
    def test_strict_bounded_settings(self):
        for token in ['unexpected_connection_fields','endpoint_not_allowed','environment_reference_not_allowed',
                      'remote_role_not_allowed','length(Connections) =< 32','stale_revision']:
            self.assertIn(token,self.settings)
        for bad in ['binary_to_atom(', 'list_to_atom(', 'erl_eval:', 'os:cmd(']:self.assertNotIn(bad,self.settings)
        self.assertIn('byte_size(Bin) =< 131072',self.http)
    def test_persistence_and_reload(self):
        for token in ['file:sync(Io)','file:change_mode(Tmp, 8#600)','file:rename(Tmp, File)',
                      'ecai_ollama_pool:reconfigure(Nodes, Runtime, Revision, Commit)']:
            self.assertIn(token,self.settings)
        for token in ['config_revision = Revision','config_token','erlang:monitor(process, Owner)',
                      "handle_info({'DOWN'",'maps:get(enabled, Node, true) andalso']:
            self.assertIn(token,self.pool)
        sup=(APP/'src/ecai_code_security_sup.erl').read_text()
        self.assertLess(sup.index('ecai_llm_settings:child_spec()'),sup.index('        OllamaPool,'))
    def test_saved_only_non_generation_probe(self):
        probe=self.settings.split('probe(Body) ->',1)[1].split('init(Opts)',1)[0]
        self.assertIn('generation_tested => false',probe)
        self.assertIn('max_response_bytes => 1048576',probe)
        self.assertNotIn('generate_',probe)
        self.assertIn('body: {revision, id}',self.js)
    def test_real_internal_consumers_follow_roles(self):
        for module in ['ecai_codebase_learner','ecai_code_knowledge','ecai_patch_worker','ecai_health_monitor','ecai_log_learning','ecai_vuln_monitor']:
            self.assertIn('ecai_llm_settings:code_options(', (APP/f'src/{module}.erl').read_text())
        self.assertIn('inference_provider(<<"anthropic">>) -> anthropic', (APP/'src/ecai_codebase_learner.erl').read_text())
        self.assertIn('ecai_llm_settings:route_chat()', (APP/'src/ecai_chat.erl').read_text())
        self.assertNotIn('ecai_llm_settings', (APP/'src/ecai_llm_bridge.erl').read_text())
    def test_damage_bridge_retains_contracts(self):
        adapter=(DAMAGE/'src/damage_ai_ecai.erl').read_text()
        self.assertIn('ecai_ollama_pool:chat_messages(bdd, Messages, Options)',adapter)
        self.assertIn('input_tokens =>',adapter)
        self.assertIn('Meta, undefined)',adapter)
        self.assertIn('complete(#{provider := openai}) -> false',adapter)
        self.assertNotIn('httpc:',adapter)
        self.assertNotIn('damage_ai_ecai',(DAMAGE/'src/damage_ai.erl').read_text())
    def test_native_claude_and_disabling(self):
        for token in ['<<"x-api-key">>','<<"anthropic-version">>','api_path(Opts, "/messages")',
                      'anthropic_truncated','anthropic_tools_not_supported','anthropic_model_list_incomplete']:
            self.assertIn(token,self.client)
        for module in ['ecai_eval_provider','ecai_ollama_model_registry']:
            self.assertIn('maps:get(enabled, ',(APP/f'src/{module}.erl').read_text())
if __name__=='__main__':unittest.main()
