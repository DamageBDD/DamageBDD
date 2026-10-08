-module(ecai_index_rewards_tests).
-include_lib("eunit/include/eunit.hrl").

funded_ledger_survives_restart_test() -> with_service(fun(Cfg) ->
    {Id, _} = fund(),
    gen_server:stop(ecai_index_rewards),
    {ok, _} = ecai_index_rewards:start_link(Cfg),
    {ok, C} = ecai_index_rewards:campaign(Id),
    ?assertEqual(500000, maps:get(funded_msat, C)),
    ?assertEqual(false, maps:get(cln_operation_in_flight, ecai_index_rewards:status()))
end).

invoice_notification_is_only_a_requery_hint_test() -> with_service(fun(_Cfg) ->
    {ok, C} = ecai_index_rewards:create(<<"creator">>, <<"event-test">>, ecai_index_reward_ledger_tests:terms(500000)),
    Id = maps:get(id, C),
    {ok, _} = ecai_index_rewards:funding_invoice(<<"creator">>, Id), wait_idle(100),
    whereis(ecai_index_rewards) ! {cln_event, invoice_paid,
        #{label => maps:get(funding_label, C), amount_received_msat => 999999999}},
    wait_idle(100),
    {ok, Checked} = ecai_index_rewards:campaign(Id),
    ?assertEqual(500000, maps:get(funded_msat, Checked))
end).

crash_during_payment_requires_reconciliation_test() -> with_service(fun(Cfg) ->
    {Id, _} = fund(), H = fun ecai_index_reward_ledger_tests:hash/1, U = H(<<"unit1">>),
    {ok, _} = ecai_index_rewards:allocate(<<"creator">>, Id, U, <<"indexer">>, <<"verifier">>),
    {ok, _} = ecai_index_rewards:submit(<<"indexer">>, Id, U, H(<<"artifact">>), H(<<"evidence">>)),
    {ok, _} = ecai_index_rewards:attest(<<"verifier">>, Id, U, H(<<"artifact">>), accept, H(<<"report">>)),
    {ok, Accepted} = ecai_index_rewards:accept_work(<<"creator">>, Id, U, H(<<"artifact">>), accept),
    [P] = [X || X <- maps:get(payouts, Accepted), maps:get(role, X) =:= index],
    Pid = maps:get(id, P),
    D0 = ecai_index_reward_ledger_tests:invoice(Id, P, 17),
    D = D0#{created_at => erlang:system_time(second)},
    persistent_term:put({ecai_index_rewards_test_backend, decoded}, D),
    {ok, _} = ecai_index_rewards:submit_invoice(<<"indexer">>, Id, Pid, <<"mock-invoice">>),
    ?assertEqual({error, explicit_payment_confirmation_required}, ecai_index_rewards:pay(<<"creator">>, Id, Pid, <<"yes">>)),
    {ok, _} = ecai_index_rewards:pay(<<"creator">>, Id, Pid, <<"pay indexing reward">>),
    Worker = receive {fake_payment_started, W, _} -> W after 1000 -> error(payment_not_started) end,
    gen_server:stop(ecai_index_rewards),
    exit(Worker, kill),
    {ok, _} = ecai_index_rewards:start_link(Cfg),
    {ok, Recovered} = ecai_index_rewards:campaign(Id),
    [R] = [X || X <- maps:get(payouts, Recovered), maps:get(id, X) =:= Pid],
    ?assertEqual(uncertain, maps:get(state, R)),
    ?assertEqual(122000, maps:get(reserved_msat, Recovered)),
    ?assertEqual({error, payout_not_ready}, ecai_index_rewards:pay(<<"creator">>, Id, Pid, <<"pay indexing reward">>)),
    {ok, _} = ecai_index_rewards:reconcile(<<"creator">>, Id, Pid),
    wait_idle(100),
    {ok, Settled} = ecai_index_rewards:campaign(Id),
    ?assertEqual(100250, maps:get(spent_msat, Settled)),
    receive {fake_payment_started, _, _} -> error(payment_was_resent) after 0 -> ok end
end).

fund() ->
    {ok, C} = ecai_index_rewards:create(<<"creator">>, <<"service-test">>, ecai_index_reward_ledger_tests:terms(500000)),
    Id = maps:get(id, C),
    {ok, _} = ecai_index_rewards:funding_invoice(<<"creator">>, Id), wait_idle(100),
    {ok, _} = ecai_index_rewards:refresh_funding(<<"creator">>, Id), wait_idle(100),
    {ok, Funded} = ecai_index_rewards:campaign(Id),
    ?assertEqual(500000, maps:get(funded_msat, Funded)), {Id, Funded}.
wait_idle(0) -> error(operation_timeout);
wait_idle(N) ->
    case maps:get(cln_operation_in_flight, ecai_index_rewards:status()) of
        false -> ok; true -> timer:sleep(10), wait_idle(N-1)
    end.
with_service(F) ->
    %% Never stop a node's actual rewards service to make tests pass.
    ?assertEqual(undefined, whereis(ecai_index_rewards)),
    Dir = filename:join("/tmp", "ecai-rewards-" ++ integer_to_list(erlang:unique_integer([positive,monotonic]))),
    Cfg = (ecai_index_reward_ledger_tests:config())#{ledger_file => filename:join(Dir, "ledger.dets"),
        adapter => ecai_index_rewards_test_backend, test_pid => self()},
    {ok, _} = ecai_index_rewards:start_link(Cfg),
    try F(Cfg)
    after
        case whereis(ecai_index_rewards) of undefined -> ok; P -> gen_server:stop(P) end,
        persistent_term:erase({ecai_index_rewards_test_backend, invoice}),
        persistent_term:erase({ecai_index_rewards_test_backend, decoded}),
        file:del_dir_r(Dir)
    end.
