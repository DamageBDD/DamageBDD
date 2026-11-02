#!/usr/bin/env python3
"""Source integration checks, not Erlang compilation or live authorization tests."""
import re
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
D=ROOT/'apps/damage'
E=ROOT/'apps/ecai'
def read(root,path):return (root/path).read_text()
class Contract(unittest.TestCase):
    def test_standalone_removed(self):
        self.assertNotIn('/automated-tasks',read(D,'src/damage_agent_http.erl'))
        for name in ('agent-tasks.html','js/agent-tasks-page.js','css/agent-tasks.css'):
            self.assertFalse((D/'priv/static'/name).exists())
    def test_shared_markup_and_assets(self):
        self.assertIn('{{{agents_tab}}}',read(D,'priv/templates/ui/dashboard/page_shell.mustache'))
        self.assertIn('data-dashboard-panel="agents-tab"',read(D,'priv/templates/ui/dashboard/sidebar.mustache'))
        self.assertIn('{{{agents_panel}}}',read(E,'priv/templates/ui/dashboard/ecai_console.mustache'))
        self.assertIn('data-view="agents"',read(E,'priv/templates/ui/dashboard/ecai_console.mustache'))
        for name in ('js/agent-workspace.js','js/agent-tasks.js','js/bdd-routing.js','css/agent-workspace.css'):
            self.assertIn(name,read(E,'src/ecai_app.erl'));self.assertTrue((D/'priv/static'/name).is_file())
    def test_routes_on_both_listeners(self):
        for root in (D,E):
            app=read(root,'src/'+root.name+'_app.erl')
            for module in ('damage_agent_http','damage_bdd_http','damage_bdd_routing_http'):
                self.assertIn(module,app)
        self.assertIn("damage_agent_sup:child_spec()",read(D,"src/damage_sup.erl"))
        self.assertIn("undefined -> ignore",read(D,"src/damage_agent_sup.erl"))
    def test_drafting_has_no_execution_or_credential_call(self):
        s=read(D,'src/damage_agent_draft.erl')
        for unsafe in ('damage_agent:start','damage:execute','damage_ae:','secrets:', 'os:cmd', 'list_to_atom(', 'binary_to_atom('):
            self.assertNotIn(unsafe,s)
        self.assertIn('damage_bdd_validator:validate',s)
        self.assertIn('map_size(M) =:= 4',s)
        self.assertIn('maps:get(hash,P)',s)
    def test_inference_uses_existing_bdd_pool(self):
        s=read(D,'src/damage_bdd_inference.erl')
        self.assertIn('ecai_ollama_pool:generate_json(bdd, Prompt, Options)',s)
        self.assertIn('cluster_attempts => 1',s)
        self.assertIn('enforce_node_limits => true',s)
        self.assertNotIn('ecai_ollama_client:',read(D,'src/damage_bdd_generator.erl'))
        self.assertIn('bounded_client_opts',read(E,'src/ecai_ollama_pool.erl'))
    def test_routing_listeners_live_until_disposal(self):
        s=read(D,'priv/static/js/bdd-routing.js')
        self.assertIn("},{signal:life.signal});", s)
        self.assertIn("addEventListener('click',()=>void refresh(),{signal:life.signal})",s)
        self.assertNotIn("},{signal:AbortSignal.any([requests.signal",s)
    def test_control_plane_never_creates_payment_challenge(self):
        for filename in ('damage_agent_http','damage_bdd_http','damage_bdd_routing_http'):
            self.assertIn('damage_bdd_access:is_authorized',read(D,'src/'+filename+'.erl'))
        s=read(D,'src/damage_bdd_access.erl')
        self.assertIn('damage_auth:require_auth',s)
        self.assertIn('credential_allowed({access_token, Token})',s)
        self.assertIn('credential_allowed(_) -> false',s)
        self.assertNotIn('damage_l402:',s)
        self.assertIn('false -> stop(403,#{error => forbidden',read(D,'src/damage_agent_http.erl'))
    def test_route_mutation_is_revision_checked_admin_bearer(self):
        s=read(D,'src/damage_bdd_routing_http.erl')
        for fragment in ('ecai_node_admin:session_is_node_admin','ecai_node_admin:can_manage_code',
                         'damage_auth:resolve_oauth', '{ok,A} = damage_auth:authenticated_account(TokenState)',
                         'stale_revision','sec-fetch-site'):
            self.assertIn(fragment,s)
        settings=read(E,'src/ecai_llm_settings.erl')
        self.assertIn('exact(Body, [<<"revision">>, <<"route">>])',settings)
        self.assertIn('validate_bdd_route(bdd_route(C))',settings)
        self.assertIn('bdd_route(maps:get(config, Current))',settings)
    def test_lifecycle_integration(self):
        s=read(E,'priv/static/js/ecai-console.js')
        for text in ('agentWorkspace?.reset()', 'agentWorkspace?.accessChanged()',
                     'agentWorkspace?.setVisible(view === "agents")','agentWorkspace?.dispose()'):
            self.assertIn(text,s)
        self.assertIn('auth:changed',read(D,'priv/static/js/agent-dashboard.js'))
    def test_preview_hash_checked_at_admission(self):
        s=read(D,'src/damage_agent.erl')
        self.assertIn('case reviewed_template(O,Template,PolicyHash)',s)
        self.assertIn('Expected =:= Hash',s)
        self.assertIn('{error,policy_changed}',s)
    def test_wallet_can_read_route_not_mutate_or_start(self):
        s=read(D,'src/damage_wallet_policy.erl')
        get=s.split('allowed(<<"GET">>',1)[1].split('allowed(<<"POST">>',1)[0]
        post=s.split('allowed(<<"POST">>',1)[1].split('allowed(_, _, wallet)',1)[0]
        self.assertIn('<<"/ai/bdd/routing">>',get)
        self.assertNotIn('/ai/bdd/routing',post)
        self.assertNotIn('/api/agents/tasks',post)
if __name__=='__main__':unittest.main(verbosity=2)
