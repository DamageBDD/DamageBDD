"""Source-level integration checks; not a substitute for Erlang or live auth tests."""
import re
import unittest
from pathlib import Path
APP=Path(__file__).resolve().parents[1]
DAMAGE=APP.parent/'damage'
def read(p):return p.read_text()
class BrowserAuthContract(unittest.TestCase):
    def test_shared_assets_not_copied(self):
        s=read(APP/'src/ecai_auth_http.erl')
        for f in ['auth-ui','auth-model','auth-wallet-loader','wallet-switcher','wallet','sidekick']:
            self.assertIn('"js/'+f+'.js"',s)
            self.assertTrue((DAMAGE/'priv/static/js'/f'{f}.js').is_file())
        self.assertIn('{priv_file, damage, "static/" ++ File}',s)
        self.assertIn('damage_utils:load_template(damage, "ui/dashboard/auth_modal.mustache"',read(APP/'src/ecai_dashboard.erl'))
    def test_router_uses_dedicated_origin(self):
        self.assertIn('damage_browser_auth_http:trails(ecai)',read(APP/'src/ecai_app.erl'))
        s=read(DAMAGE/'src/damage_browser_auth_http.erl')
        self.assertIn('application:get_env(ecai, browser_auth_origin)',s)
        self.assertNotIn('cowboy_req:host(',s)
        self.assertNotIn('x-forwarded-host',s)
        self.assertIn('damage_browser_auth:verify(Id, Signature, Origin, Binding)',s)
    def test_console_uses_only_new_session_path(self):
        s=read(APP/'priv/static/js/ecai-console.js')
        self.assertNotIn('fetch("/accounts/auth/"',s)
        self.assertNotIn('request("/accounts/logout"',s)
        self.assertIn('await logoutActiveSession()',s)
        self.assertIn('await TokenManager.refreshSession()',s)
        self.assertIn('epoch !== state.authEpoch',s)
        self.assertNotIn('state.accessToken',s)
    def test_wallet_does_not_inherit_funded_admin(self):
        s=read(APP/'src/ecai_index_pool_http.erl')
        self.assertIn('ecai_node_admin:session_is_node_admin(Auth)',s)
        self.assertIn('damage_auth:resolve_oauth(Token, #{})',s)
        self.assertIn('session_is_node_admin(#{auth_mode := wallet}) -> false',read(APP/'src/ecai_node_admin.erl'))
    def test_code_admin_binds_bearer_to_principal(self):
        s=read(APP/'src/ecai_code_admin_http.erl')
        self.assertIn('damage_auth:resolve_oauth(Token, #{})',s)
        self.assertIn('ecai_node_admin:session_is_node_admin(State)',s)
        self.assertIn('bearer_identity_rejected',s)
        self.assertIn('externalize(false) -> false',s)
        self.assertIn('externalize(true) -> true',s)
    def test_guest_and_wallet_panels(self):
        t=read(APP/'priv/templates/ui/dashboard/ecai_console.mustache')
        for i in ['createAccountBtn','connectWalletBtn','switchAccountBtn','consoleWalletNotice']:
            self.assertIn('id="'+i+'"',t)
        self.assertNotIn('id="consoleLoginForm"',t)
        self.assertIn('{{{browser_auth_modal}}}',t)
        self.assertIn('data-ecai-managed',t)
    def test_mobile_returns_to_console(self):
        s=read(APP/'src/ecai_dashboard.erl')
        self.assertIn('auth_callback_path => <<"/dashboard">>',s)
        self.assertIn('auth_auto_open => <<"false">>',s)
        u=read(DAMAGE/'priv/static/js/auth-ui.js')
        self.assertIn('root.dataset.authCallbackPath',u)
        self.assertIn('ticket === epoch',u)
    def test_legacy_indexer_kept_separate(self):
        s=read(APP/'src/ecai_app.erl')
        self.assertIn('"/accounts/auth/", damage_accounts',s)
        self.assertNotIn('            damage_accounts,',s)
        self.assertNotIn('"/accounts/create"',s)

if __name__=='__main__':unittest.main(verbosity=2)
