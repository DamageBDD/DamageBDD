"""Static integration/safety checks. These are NOT Erlang execution tests."""
import re
import unittest
from pathlib import Path

APP = Path(__file__).resolve().parents[1]

def read(rel):
    return (APP / rel).read_text()

class PoolContract(unittest.TestCase):
    def test_assets_and_module_order(self):
        t=read('priv/templates/ui/dashboard/ecai_console.mustache')
        for p in ['css/ecai-index-pool.css','js/ecai-index-pool.js']:
            self.assertIn('/static/'+p,t)
            self.assertTrue((APP/'priv/static'/p).is_file())
        self.assertLess(t.index('src="/static/js/ecai-index-pool.js"'),t.index('src="/static/js/ecai-console.js"'))
    def test_mutations_validate_explicit_bearer(self):
        s=read('src/ecai_index_pool_http.erl')
        body=s.split('authenticate(Req, <<"POST">>) ->',1)[1].split('authenticate(Req, _)')[0]
        self.assertIn('damage_auth:resolve_oauth(Token, #{})',body)
        self.assertNotIn('damage_http:is_authorized',body)
        self.assertIn('byte_size(Raw) =< 16384',s)
        self.assertIn('ecai_node_admin:is_node_admin(A)',s)
    def test_http_client_cannot_supply_actor_source_paths(self):
        s=read('src/ecai_index_pool_http.erl')
        keys=s.split('quote_keys() ->',1)[1].split('\nkeys(')[0]
        self.assertNotIn('<<"actor">>',keys)
        self.assertNotIn('<<"path">>',keys)
        self.assertIn('keys(B, [<<"job_id">>])',s)
    def test_no_arbitrary_cluster_atom_creation(self):
        s=read('src/ecai_index_pool_util.erl')
        self.assertIn('node_not_operator_allowlisted',s)
        self.assertNotIn('binary_to_atom(',s)
        self.assertNotIn('list_to_atom(',s)
        self.assertIn('symlink_not_permitted',s)
    def test_signed_participant_binding(self):
        s=read('src/ecai_index_pool.erl')
        self.assertIn('check_index_pool_message',s)
        self.assertIn('field(verified, Checked) =:= true',s)
        self.assertIn('field(pubkey, Checked) =:= Pubkey',s)
        self.assertIn('node_consents =>',s)
        for field in ['nonce','coordinator','pipeline_sha256']:
            self.assertIn(f'maps:get({field}, Offer)',s)
    def test_rewards_require_independent_rebuild(self):
        s=read('src/ecai_index_pool_runner.erl')
        self.assertIn('ecai_index_pool_proof:compare(IndexProof, VerifyProof)',s)
        self.assertIn('index_changed_during_verification',s)
        self.assertIn('snapshot_location_changed',s)
        self.assertIn('receipt_spec_changed',s)
        self.assertIn('ecai_index_source:verify_paths',s)
        self.assertLess(s.index('ecai_index_pool_proof:compare'),s.index('ecai_index_rewards:accept_work'))
    def test_no_channel_funding_or_automatic_transfer_on_join(self):
        s='\n'.join(p.read_text() for p in (APP/'src').glob('ecai_index_pool*.erl'))
        self.assertNotIn('damage_cln:open_channel(',s)
        self.assertNotIn('damage_cln:pay_invoice(',s)
        self.assertNotIn('push_msat',s)
        self.assertIn('advisory_only => true',s)
    def test_bounded_grant_and_linked_workers(self):
        s=read('src/ecai_index_pool.erl'); r=read('src/ecai_index_pool_runner.erl')
        self.assertIn('[link, monitor]',s)
        self.assertIn('control_revision',s)
        self.assertIn('maps:remove(finished, Delta0)',s)
        self.assertIn('ecai_index_pool:authorized(Id, pay',r)
        self.assertIn('payment_requires_operator_retry',r)
        self.assertIn('index_pool_max_inflight',r)
    def test_safe_snapshot_decoding(self):
        s=read('src/ecai_index_pool_proof.erl')
        for phrase in ['binary_to_term(Flat, [safe])','zlib:safeInflate','expanded_snapshot_too_large',
                       'duplicate_snapshot_rows','empty_index_not_rewardable']:
            self.assertIn(phrase,s)
    def test_same_price_table_used_for_hold_and_reward(self):
        s=read('src/ecai_index_reward_ledger.erl')
        self.assertGreaterEqual(s.count('Terms = unit_terms('),3)
        self.assertIn('quoted_budget_exceeded',s)
        b=read('src/ecai_index_pool_budget.erl')
        self.assertNotIn('round(',b)
        self.assertIn(' rem Total',b)
        self.assertIn('FeeReserve = N * Roles * FeeSats',b)
    def test_admin_navigation_and_session_cleanup(self):
        s=read('priv/static/js/ecai-index-pool.js')
        self.assertIn('clearPrivateState()',s)
        self.assertIn('state.controller?.abort()',s)
        self.assertIn('epoch !== state.epoch',s)
        self.assertIn('document.hidden',s)
        self.assertNotIn('.innerHTML',s)
    def test_required_operator_defaults_remain_disabled(self):
        app=read('src/ecai.app.src')
        for flag in ['index_pool_enabled','index_pool_participant_enabled','index_rewards_enabled']:
            self.assertIn('{'+flag+', false}',app)
        self.assertIn('ecai_index_pool_http',read('src/ecai_app.erl'))
        self.assertIn('indexing_pool_specs()',read('src/ecai_sup.erl'))

if __name__ == '__main__':
    unittest.main()
