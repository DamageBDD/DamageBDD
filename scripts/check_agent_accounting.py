#!/usr/bin/env python3
"""Static integration checks only: EUnit and chain integration must run separately."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'apps/damage/src'
def text(name): return (SRC / name).read_text()
class AccountingContractChecks(unittest.TestCase):
    def test_existing_and_async_api_coexist(self):
        s=text('damage_agent.erl')
        for name in ['create_agent/1','fund_agent/2','create_job/2','execute_job/2',
                     'pause_agent/1','revoke_agent/1','write_receipt/2','start/4','status/2']:
            self.assertIn(name,s)
    def test_no_legacy_paid_runner_in_agent_path(self):
        for name in ['damage_agent.erl','damage_agent_task.erl','damage_agent_budget.erl','damage_agent_chain.erl']:
            s=text(name)
            for bad in ['damage:execute_data(', 'damage_ae:spend(', 'damage_ae:confirm_spend(', 'damage_accounts:node_account()']:
                self.assertNotIn(bad,s)
    def test_signer_address_source_are_explicit(self):
        s=text('damage_agent_chain.erl')
        self.assertIn('damage_ae:contract_call(KP, Ct, Path, Function, Args)',s)
        self.assertIn('requester_signature_required',s)
        self.assertIn('signer_mismatch',s)
    def test_reservation_settlement_and_receipt_have_distinct_intents(self):
        s=text('damage_agent_task.erl')
        for event in ['reservation_intent','settlement_intent','receipt_intent','invocation_charged']:
            self.assertIn(event,s)
        self.assertIn('accounting_hold(settling,settlement_outcome_unknown,D)',s)
        self.assertIn('accounting_hold(receipting,receipt_outcome_unknown,D)',s)
    def test_integer_cap_and_fixed_tariff_are_enforced(self):
        s=text('damage_agent_budget.erl')
        self.assertIn('is_integer(N), N > 0',s)
        self.assertIn('maps:get(spent_units, B) + N =< maps:get(max_cost_units, B)',s)
        self.assertNotIn('round(',s)
    def test_receipt_identity_and_truth_scope(self):
        s=text('damage_agent_budget.erl')
        self.assertIn('agent-receipt-v1',s)
        self.assertIn('completed -> <<"passed">>; _ -> <<"error">>',s)
        self.assertIn('accounting_complete',text('damage_agent.erl'))
        self.assertIn('training_eligible => false',text('damage_agent.erl'))
    def test_no_invented_onchain_lookup_or_refund(self):
        s=text('damage_agent_chain.erl')
        self.assertIn('contract_reconciliation_adapter_required',s)
        self.assertNotIn('"get_reservation"',s)
        self.assertNotIn('"refund"',s)
    def test_source_hash_and_network_are_pinned(self):
        s=text('damage_agent_chain.erl')
        self.assertIn('Expected = string:lowercase(binary:encode_hex(crypto:hash(sha256, Bytes)))',s)
        self.assertIn('string_value(Network0) =:= maps:get(network_id, B)',s)
        self.assertIn('accounting_contracts_reviewed, false',s)
if __name__ == '__main__': unittest.main(verbosity=2)
