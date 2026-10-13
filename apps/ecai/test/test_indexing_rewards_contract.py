#!/usr/bin/env python3
"""Source contract checks only. These do NOT execute Erlang or test Lightning."""
from pathlib import Path
import unittest

APP = Path(__file__).resolve().parents[1]

def src(name):
    return (APP / 'src' / name).read_text(encoding='utf-8')

class Contract(unittest.TestCase):
    def test_no_second_cln_transport(self):
        bridge = src('ecai_index_rewards_cln.erl')
        for method in ('decode_invoice', 'list_pays', 'list_peerchannels', 'create_invoice', 'xpay_invoice'):
            self.assertIn('damage_cln:' + method, bridge)
        for forbidden in ('secrets:', 'open_port(', 'gun:', 'rune', 'rpc_socket'):
            self.assertNotIn(forbidden, '\n'.join(x for x in bridge.splitlines() if not x.startswith('%')))

    def test_funding_and_public_http_are_separate(self):
        self.assertIn('ecai-index:v1:', src('ecai_index_reward_ledger.erl'))
        http = src('ecai_index_jobs_http.erl')
        self.assertIn('work_unit_requires_node_operator', http)
        self.assertNotIn('ecai_index_rewards', src('ecai_app.erl'))
        self.assertIn('{index_rewards_enabled, false}', src('ecai.app.src'))

    def test_persist_before_payment_effect(self):
        service = src('ecai_index_rewards.erl')
        self.assertLess(service.index('persist(S#st.tab, L)'), service.index('launch(Effect, S#st'))
        self.assertIn('ecai_index_reward_ledger:recover(Old', service)
        self.assertIn('ecai_index_reward_ledger:validate(Old, Config)', service)
        self.assertIn('pay indexing reward', service)

    def test_receipt_hash_and_reserved_budget_invariants(self):
        ledger = src('ecai_index_reward_ledger.erl')
        for required in ('preimage_matches(Preimage, H)', 'payment_hash_already_used',
                         'independent_verifier_required', 'HeldUnits + HeldPays',
                         'ledger_quarantined', 'invoice_description_mismatch',
                         'attempted_invoice_is_immutable'):
            self.assertIn(required, ledger)

    def test_ambiguous_payment_does_not_fallback_or_release_budget(self):
        ledger = src('ecai_index_reward_ledger.erl')
        self.assertIn('settle(P, C, _) -> {P#{state => uncertain}, C}', ledger)
        bridge = src('ecai_index_rewards_cln.erl')
        self.assertIn('definitive => true', bridge)
        self.assertIn('maxfee => maps:get(fee_cap_msat, P)', bridge)
        self.assertIn('payment(maps:get(payment_hash, P))', bridge)
        self.assertNotIn('push_msat =>', bridge)

    def test_queue_placement_is_persisted_before_remote_enqueue(self):
        dispatch = src('ecai_index_dispatch.erl')
        self.assertLess(dispatch.index('ok = write(File, I)'), dispatch.index('call(Node1, enqueue'))
        self.assertIn('worker_node_not_allowed', dispatch)
        self.assertIn('ecai_index_dispatch:get(Placement)', src('ecai_index_shards.erl'))

    def test_upstream_callbacks_match_existing_api(self):
        work = src('ecai_wikimedia_work.erl')
        self.assertIn('ecai_wikimedia_content:prepare(Dir, Catalog, Selector, Opts)', work)
        self.assertIn('{ok, Tab, _Count}', work)
        self.assertIn('ecai_wikimedia_selector:load_selection(maps:get(selection_path, Sel))', work)
        self.assertIn('ecai_index_shards:plan(Spec, OutputRoot, Limits)', work)
        self.assertIn('wikimedia_unit', src('ecai_index_job_adapter.erl'))

    def test_partition_cap_does_not_drop_records(self):
        selector = src('ecai_wikimedia_selector.erl')
        self.assertIn('partition_resource_limit', selector)
        self.assertIn('ets:info(Tab, memory)', selector)
        self.assertIn('{error, _} = Error -> Error', selector)

if __name__ == '__main__':
    unittest.main(verbosity=2)
