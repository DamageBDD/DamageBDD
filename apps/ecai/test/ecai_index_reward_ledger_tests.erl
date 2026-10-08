-module(ecai_index_reward_ledger_tests).
-include_lib("eunit/include/eunit.hrl").
-export([config/0, terms/1, hash/1, node_id/1, invoice/3, now_s/0]).

funding_is_idempotent_test() ->
    {Id, S, Inv} = funded(500000),
    S1 = step({funding_seen, Id, Inv}, S),
    C = campaign(Id, S1),
    ?assertEqual(500000, maps:get(funded_msat, C)),
    ?assertEqual(500000, maps:get(available_msat, C)).

funding_is_not_a_client_balance_claim_test() ->
    {ok, C, S, none} = change({create, <<"creator">>, <<"k">>, terms(500000)}, ecai_index_reward_ledger:new()),
    Id = maps:get(id, C),
    ?assertEqual({error, campaign_not_funded}, change({allocate, <<"creator">>, Id, hash(<<"unit1">>), <<"indexer">>, <<"verifier">>}, S)).

budget_reserves_rewards_and_fees_before_work_test() ->
    {Id, S0, _} = funded(122000),
    S = allocate(Id, hash(<<"unit1">>), S0),
    ?assertEqual(122000, maps:get(reserved_msat, campaign(Id, S))),
    ?assertEqual({error, budget_exhausted}, change({allocate, <<"creator">>, Id, hash(<<"unit2">>), <<"indexer">>, <<"verifier">>}, S)).

creator_and_key_are_bound_test() ->
    {Id, S, _} = funded(500000),
    ?assertEqual({error, owner_required}, change({close, <<"intruder">>, Id}, S)),
    ?assertEqual({error, campaign_key_conflict}, change({create, <<"creator">>, <<"k">>, terms(600000)}, S)).

a_second_campaign_cannot_reward_the_same_work_twice_test() ->
    {Id, S0, _} = funded(500000), U = hash(<<"unit1">>), S1 = allocate(Id, U, S0),
    {ok, C2, S2, none} = change({create, <<"creator">>, <<"another-key">>, terms(500000)}, S1),
    Id2 = maps:get(id, C2),
    I2 = #{label => maps:get(funding_label, C2), payment_hash => hash(<<"funding-2">>),
        amount_msat => 500000, amount_received_msat => 500000, status => <<"paid">>},
    S3 = step({funding_seen, Id2, I2}, S2),
    ?assertEqual({error, unit_reserved_or_paid_elsewhere}, change({allocate, <<"creator">>, Id2, U, <<"indexer">>, <<"verifier">>}, S3)).

same_account_cannot_verify_itself_test() ->
    {Id, S, _} = funded(500000),
    ?assertEqual({error, independent_verifier_required}, change({allocate, <<"creator">>, Id, hash(<<"unit1">>), <<"indexer">>, <<"indexer">>}, S)).

same_ln_node_under_two_accounts_is_not_independent_test() ->
    {Id, S, _} = funded(500000),
    Config = config(), Ps = maps:get(participants, Config),
    Bad = Config#{participants => Ps#{<<"verifier">> => node_id(2)}},
    ?assertEqual({error, independent_verifier_required},
        ecai_index_reward_ledger:change({allocate, <<"creator">>, Id, hash(<<"unit1">>), <<"indexer">>, <<"verifier">>}, S, Bad, now_s())).

acceptance_requires_the_assigned_verifier_test() ->
    {Id, S0, _} = funded(500000), U = hash(<<"unit1">>), S1 = allocate(Id, U, S0),
    S = step({submit, <<"indexer">>, Id, U, hash(<<"artifact">>), hash(<<"evidence">>)}, S1),
    ?assertEqual({error, work_not_attested}, change({accept_work, <<"creator">>, Id, U, hash(<<"artifact">>), accept}, S)),
    ?assertEqual({error, wrong_verifier}, change({attest, <<"indexer">>, Id, U, hash(<<"artifact">>), accept, hash(<<"report">>)}, S)).

artifact_cannot_change_after_submission_test() ->
    {Id, S0, _} = funded(500000), U = hash(<<"unit1">>), S1 = allocate(Id, U, S0),
    S = step({submit, <<"indexer">>, Id, U, hash(<<"artifact">>), hash(<<"evidence">>)}, S1),
    ?assertEqual({error, immutable_result_conflict}, change({submit, <<"indexer">>, Id, U, hash(<<"other">>), hash(<<"evidence">>)}, S)),
    ?assertEqual({error, artifact_mismatch}, change({attest, <<"verifier">>, Id, U, hash(<<"other">>), accept, hash(<<"report">>)}, S)).

negative_verification_can_be_rewarded_without_index_reward_test() ->
    {Id, S} = decided(reject), C = campaign(Id, S),
    [P] = maps:get(payouts, C),
    ?assertEqual(verify, maps:get(role, P)),
    ?assertEqual(21000, maps:get(reserved_msat, C)),
    ?assertEqual(479000, maps:get(available_msat, C)).

invoice_binds_payee_amount_network_and_work_test() ->
    {Id, S} = decided(accept), P = role(index, campaign(Id, S)),
    D = invoice(Id, P, 17), Pid = maps:get(id, P),
    lists:foreach(fun({Field, Value, Reason}) ->
        ?assertEqual({error, Reason}, change({invoice, <<"indexer">>, Id, Pid, <<"mock-invoice">>, D#{Field => Value}}, S))
    end, [{valid, false, invalid_bolt11}, {currency, <<"bc">>, wrong_invoice_network},
          {amount_msat, 99999, invoice_amount_mismatch}, {payee, node_id(3), invoice_payee_mismatch},
          {description, <<"different work">>, invoice_description_mismatch}, {expiry, 0, invoice_expired}]).

payment_hash_cannot_pay_two_obligations_test() ->
    {Id, S0} = decided(accept), C = campaign(Id, S0),
    I = role(index, C), V = role(verify, C),
    S = step({invoice, <<"indexer">>, Id, maps:get(id, I), <<"mock-index-invoice">>, invoice(Id, I, 17)}, S0),
    ?assertEqual({error, payment_hash_already_used}, change({invoice, <<"verifier">>, Id, maps:get(id, V), <<"mock-verify-invoice">>, invoice(Id, V, 17)}, S)).

payments_default_off_test() ->
    {Id, P, S} = ready(),
    C = maps:remove(payments_enabled, config()),
    ?assertEqual({error, payments_disabled}, ecai_index_reward_ledger:change({pay, <<"creator">>, Id, maps:get(id, P)}, S, C, now_s())).

payment_intent_precedes_effect_and_restart_does_not_resend_test() ->
    {Id, P, S0} = ready(), Pid = maps:get(id, P),
    {ok, _, S, {pay, Id, Pid, EffectP}} = change({pay, <<"creator">>, Id, Pid}, S0),
    ?assertEqual(paying, maps:get(state, EffectP)),
    Recovered = ecai_index_reward_ledger:recover(S, now_s()+1),
    {ok, RecoveredP} = ecai_index_reward_ledger:payout(Id, Pid, Recovered),
    ?assertEqual(uncertain, maps:get(state, RecoveredP)),
    ?assertEqual({error, payout_not_ready}, change({pay, <<"creator">>, Id, Pid}, Recovered)),
    ?assertEqual(122000, maps:get(reserved_msat, campaign(Id, Recovered))).

unknown_absent_and_old_failed_results_do_not_release_money_test() ->
    {Id, P, S0} = ready(), Pid = maps:get(id, P), S = step({pay, <<"creator">>, Id, Pid}, S0),
    lists:foreach(fun(Status) ->
        N = step({payment_seen, Id, Pid, #{status => Status, payment_hash => maps:get(payment_hash, invoice(Id, P, 17))}}, S),
        {ok, NP} = ecai_index_reward_ledger:payout(Id, Pid, N),
        ?assertEqual(uncertain, maps:get(state, NP)),
        ?assertEqual(122000, maps:get(reserved_msat, campaign(Id, N)))
    end, [unknown, absent, pending, failed]).

settled_preimage_is_checked_and_fees_are_accounted_once_test() ->
    {Id, P, S0} = ready(), Pid = maps:get(id, P), S1 = step({pay, <<"creator">>, Id, Pid}, S0),
    O = settled(Id, P, 100500), S = step({payment_seen, Id, Pid, O}, S1),
    C = campaign(Id, S),
    ?assertEqual(100500, maps:get(spent_msat, C)),
    ?assertEqual(21000, maps:get(reserved_msat, C)),
    S2 = step({payment_seen, Id, Pid, O}, S),
    ?assertEqual(maps:get(spent_msat, C), maps:get(spent_msat, campaign(Id, S2))),
    ?assertEqual({error, payout_not_ready}, change({pay, <<"creator">>, Id, Pid}, S2)).

invalid_proof_quarantines_the_ledger_test() ->
    {Id, P, S0} = ready(), Pid = maps:get(id, P), S1 = step({pay, <<"creator">>, Id, Pid}, S0),
    S = step({payment_seen, Id, Pid, (settled(Id, P, 100500))#{preimage => hash(<<"wrong">>)}}, S1),
    ?assertEqual(true, maps:get(quarantined, ecai_index_reward_ledger:summary(S))),
    ?assertEqual(0, maps:get(spent_msat, campaign(Id, S))),
    ?assertEqual({error, ledger_quarantined}, change({allocate, <<"creator">>, Id, hash(<<"unit2">>), <<"indexer">>, <<"verifier">>}, S)).

fee_cap_cannot_be_exceeded_test() ->
    {Id, P, S0} = ready(), Pid = maps:get(id, P), S1 = step({pay, <<"creator">>, Id, Pid}, S0),
    S = step({payment_seen, Id, Pid, settled(Id, P, 101001)}, S1),
    ?assertEqual(true, maps:get(quarantined, S)),
    ?assertEqual(122000, maps:get(reserved_msat, campaign(Id, S))).

cancel_before_submission_releases_exact_reservation_test() ->
    {Id, S0, _} = funded(500000), U = hash(<<"unit1">>), S1 = allocate(Id, U, S0),
    S = step({cancel_unit, <<"creator">>, Id, U}, S1),
    ?assertEqual(0, maps:get(reserved_msat, campaign(Id, S))).

refund_reserves_only_unencumbered_funds_test() ->
    {Id, S0} = decided(accept), S1 = step({close, <<"creator">>, Id}, S0),
    S = step({refund, <<"creator">>, Id}, S1), C = campaign(Id, S), P = role(refund, C),
    ?assertEqual(377000, maps:get(amount_msat, P)),
    ?assertEqual(500000, maps:get(reserved_msat, C)),
    ?assertEqual(0, maps:get(available_msat, C)),
    ?assertEqual({error, no_refundable_balance}, change({refund, <<"creator">>, Id}, S)).

treasury_switch_is_rejected_on_recovery_test() ->
    {_Id, S, _} = funded(500000),
    ?assertEqual({error, ledger_or_treasury_mismatch}, ecai_index_reward_ledger:validate(S, (config())#{treasury_node => node_id(8)})).

config() -> #{creators => [<<"creator">>], participants => #{<<"creator">> => node_id(1),
    <<"indexer">> => node_id(2), <<"verifier">> => node_id(3)}, treasury_node => node_id(4),
    network => <<"regtest">>, payments_enabled => true}.
terms(Budget) -> #{plan_root => hash(<<"plan">>), unit_ids => [hash(<<"unit1">>), hash(<<"unit2">>)],
    budget_msat => Budget, index_msat => 100000, verify_msat => 20000, fee_cap_msat => 1000}.
now_s() -> 2000000000.
node_id(N) -> <<"02", (hash(integer_to_binary(N)))/binary>>.
hash(B) -> ecai_index_job_codec:id_hex(crypto:hash(sha256, B)).
change(C, S) -> ecai_index_reward_ledger:change(C, S, config(), now_s()).
step(C, S) -> {ok, _, N, _} = change(C, S), N.
campaign(Id, S) -> {ok, C} = ecai_index_reward_ledger:campaign(Id, S), C.
role(R, C) -> [P] = [X || X <- maps:get(payouts, C), maps:get(role, X) =:= R], P.
funded(Budget) ->
    {ok, C, S0, none} = change({create, <<"creator">>, <<"k">>, terms(Budget)}, ecai_index_reward_ledger:new()),
    Id = maps:get(id, C), Inv = #{label => maps:get(funding_label, C), payment_hash => hash(<<"funding">>),
        amount_msat => Budget, amount_received_msat => Budget, status => <<"paid">>, bolt11 => <<"mock-funding-invoice">>},
    {Id, step({funding_seen, Id, Inv}, S0), Inv}.
allocate(Id, U, S) -> step({allocate, <<"creator">>, Id, U, <<"indexer">>, <<"verifier">>}, S).
decided(Verdict) ->
    {Id, S0, _} = funded(500000), U = hash(<<"unit1">>), S1 = allocate(Id, U, S0),
    S2 = step({submit, <<"indexer">>, Id, U, hash(<<"artifact">>), hash(<<"evidence">>)}, S1),
    S3 = step({attest, <<"verifier">>, Id, U, hash(<<"artifact">>), Verdict, hash(<<"report">>)}, S2),
    {Id, step({accept_work, <<"creator">>, Id, U, hash(<<"artifact">>), Verdict}, S3)}.
invoice(Id, P, Byte) ->
    #{valid => true, type => <<"bolt11 invoice">>, currency => <<"bcrt">>, payee => maps:get(payee, P),
      amount_msat => maps:get(amount_msat, P), payment_hash => hash(binary:copy(<<Byte>>, 32)),
      description => ecai_index_reward_ledger:invoice_description(Id, maps:get(id, P), maps:get(artifact_sha256, P)),
      created_at => now_s(), expiry => 3600}.
ready() ->
    {Id, S0} = decided(accept), P = role(index, campaign(Id, S0)),
    {Id, P, step({invoice, <<"indexer">>, Id, maps:get(id, P), <<"mock-index-invoice">>, invoice(Id, P, 17)}, S0)}.
settled(Id, P, Sent) ->
    #{status => complete, payment_hash => maps:get(payment_hash, invoice(Id, P, 17)),
      amount_msat => maps:get(amount_msat, P), amount_sent_msat => Sent,
      preimage => ecai_index_job_codec:id_hex(binary:copy(<<17>>, 32))}.
