-module(ecai_inference_receipt_recovery_tests).
-include_lib("eunit/include/eunit.hrl").

%% Matches the pool AFTER ecai-timeout-ui-fixes.patch; no network or LLM calls.
-record(state, {nodes=#{}, leases=#{}, seq=0, health_interval_ms=30000,
    health_timeout_ms=5000, failure_threshold=2, last_probe_at=undefined,
    receipt_tab=undefined, receipt_file=undefined, probe_timer=undefined,
    config_revision=0, receipt_counts=#{}, lease_started=#{}, probes=#{}}).
-define(TAB, ecai_receipt_recovery_test_dets).

id() -> binary:copy(<<"a">>, 64).
from() -> {self(), make_ref()}.
call(Msg, State) -> ecai_ollama_pool:handle_call(Msg, from(), State).
approval(Attempt) ->
    {approve_inference_retry, id(), Attempt, accept_duplicate_inference_cost}.

with_store(Fun) ->
    Root = filename:join("/tmp", "ecai-receipt-recovery-" ++
                         integer_to_list(erlang:unique_integer([positive]))),
    File = filename:join(Root, "receipts.dets"),
    ok = filelib:ensure_dir(File),
    {ok, ?TAB} = dets:open_file(?TAB, [{file, File}, {type, set}]),
    try Fun(#state{receipt_tab = ?TAB, receipt_file = File})
    after dets:close(?TAB), file:del_dir_r(Root) end.

seed(Status, Extra, State) ->
    Receipt = maps:merge(#{request_id => id(), status => Status,
        provider => ollama, role => audit, node_id => <<"ollama_pro">>,
        model => <<"fixture-model">>, created_at => <<"2026-11-02T09:00:00Z">>,
        uncertain_at => <<"2026-11-02T09:10:00Z">>, error => ollama_request_failed}, Extra),
    ok = dets:insert(?TAB, {{inference_receipt, id()}, Receipt}),
    ok = dets:sync(?TAB),
    State#state{receipt_counts = #{Status => 1}}.

legacy_inspection_is_read_only_and_redacted_test() ->
    with_store(fun(S0) ->
        S = seed(uncertain, #{value => <<"secret output">>, prompt => <<"secret prompt">>,
            client_meta => #{auth => <<"secret token">>}, headers => [<<"secret header">>],
            error_detail => #{code => ollama_request_failed, phase => response_body,
                              reason => timeout, body => <<"secret body">>}}, S0),
        Before = dets:lookup(?TAB, {inference_receipt, id()}),
        {reply, {ok, Public}, S} = call({inference_receipt, id()}, S),
        ?assertEqual(1, maps:get(attempt, Public)),
        ?assertEqual(uncertain, maps:get(status, Public)),
        ?assertEqual([], maps:get(retry_history, Public)),
        ?assertEqual(nomatch, binary:match(term_to_binary(Public), <<"secret">>)),
        ?assertMatch(#{phase := response_body, reason := timeout}, maps:get(error_detail, Public)),
        ?assertEqual(Before, dets:lookup(?TAB, {inference_receipt, id()}))
    end).

explicit_acknowledgement_required_test() ->
    with_store(fun(S0) ->
        S = seed(uncertain, #{}, S0),
        ?assertMatch({reply, {error, duplicate_inference_cost_acknowledgement_required}, S},
            call({approve_inference_retry, id(), 1, no}, S)),
        ?assertMatch({reply, {ok, #{status := uncertain}}, S},
            call({inference_receipt, id()}, S))
    end).

stale_and_invalid_attempt_rejected_test() ->
    with_store(fun(S0) ->
        S = seed(uncertain, #{attempt => 3}, S0),
        ?assertMatch({reply, {error, stale_receipt_attempt}, S}, call(approval(2), S)),
        ?assertMatch({reply, {error, invalid_expected_attempt}, S}, call(approval(0), S)),
        ?assertMatch({reply, {error, invalid_expected_attempt}, S}, call(approval(<<"3">>), S))
    end).

only_uncertain_can_be_approved_test() ->
    with_store(fun(S0) ->
        lists:foreach(fun(Status) ->
            S = seed(Status, #{}, S0),
            ?assertEqual({reply, {error, {receipt_not_uncertain, Status}}, S},
                         call(approval(1), S))
        end, [claimed, sent, completed, retry_approved])
    end).

approval_is_consumed_once_and_retains_history_test() ->
    with_store(fun(S0) ->
        S1 = seed(uncertain, #{}, S0),
        {reply, {ok, #{status := retry_approved, attempt := 2, retry_history := [H]}}, S2} =
            call(approval(1), S1),
        ?assertEqual(uncertain, maps:get(status, H)),
        ?assertEqual(1, maps:get(attempt, H)),
        ?assertEqual(true, maps:get(duplicate_inference_cost_accepted, H)),
        ?assertEqual(#{retry_approved => 1}, S2#state.receipt_counts),
        ?assertMatch({reply, {error, {receipt_not_uncertain, retry_approved}}, S2},
                     call(approval(1), S2)),
        {reply, {ok, claimed}, S3} = call({receipt_claim, id(), #{request_id => id()}}, S2),
        ?assertEqual(#{claimed => 1}, S3#state.receipt_counts),
        ?assertMatch({reply, {blocked, #{status := claimed, attempt := 2}}, S3},
                     call({receipt_claim, id(), #{}}, S3)),
        {reply, ok, S4} = call({receipt_sent, id(), #{}}, S3),
        {reply, ok, S5} = call({receipt_uncertain, id(),
            {ollama_request_failed, {await_body_failed, {error, timeout}}}}, S4),
        ?assertEqual(#{uncertain => 1}, S5#state.receipt_counts),
        ?assertMatch({reply, {error, stale_receipt_attempt}, S5}, call(approval(1), S5)),
        {reply, {ok, #{attempt := 3, retry_history := History}}, _} = call(approval(2), S5),
        ?assertEqual([1, 2], [maps:get(attempt, R) || R <- History])
    end).

pre_send_failure_preserves_prior_history_test() ->
    with_store(fun(S0) ->
        S1 = seed(uncertain, #{}, S0),
        {reply, {ok, _}, S2} = call(approval(1), S1),
        {reply, {ok, claimed}, S3} = call({receipt_claim, id(), #{}}, S2),
        {reply, ok, S4} = call({receipt_sent, id(), #{}}, S3),
        {reply, ok, S5} = call({receipt_release, id()}, S4),
        ?assertEqual(#{retry_approved => 1}, S5#state.receipt_counts),
        {reply, {ok, #{status := retry_approved, attempt := 2, retry_history := [_]}}, S5} =
            call({inference_receipt, id()}, S5),
        {reply, {ok, claimed}, _} = call({receipt_claim, id(), #{}}, S5)
    end).

successful_retry_preserves_cache_and_history_test() ->
    with_store(fun(S0) ->
        S1 = seed(uncertain, #{}, S0),
        {reply, {ok, _}, S2} = call(approval(1), S1),
        {reply, {ok, claimed}, S3} = call({receipt_claim, id(), #{}}, S2),
        {reply, ok, S4} = call({receipt_sent, id(), #{}}, S3),
        {reply, ok, S5} = call({receipt_complete, id(), <<"result">>, #{tokens => 5}}, S4),
        ?assertEqual(#{completed => 1}, S5#state.receipt_counts),
        ?assertMatch({reply, {completed, <<"result">>, #{tokens := 5}}, S5},
                     call({receipt_claim, id(), #{}}, S5)),
        ?assertMatch({reply, {ok, #{status := completed, retry_history := [_]}}, S5},
                     call({inference_receipt, id()}, S5)),
        ?assertMatch({reply, {error, receipt_history_must_be_preserved}, S5},
                     call({receipt_release, id()}, S5))
    end).

approval_persists_across_dets_reopen_test() ->
    with_store(fun(S0) ->
        S1 = seed(uncertain, #{}, S0),
        {reply, {ok, Approved}, S2} = call(approval(1), S1),
        ok = dets:close(?TAB),
        {ok, ?TAB} = dets:open_file(?TAB, [{file, S2#state.receipt_file}, {type, set}]),
        ?assertEqual({reply, {ok, Approved}, S2}, call({inference_receipt, id()}, S2)),
        {reply, {ok, claimed}, _} = call({receipt_claim, id(), #{}}, S2)
    end).

invalid_ids_do_not_access_store_test() ->
    S = #state{receipt_tab = table_not_open},
    lists:foreach(fun(Id) ->
        ?assertEqual({reply, {error, invalid_receipt_id}, S}, call({inference_receipt, Id}, S)),
        ?assertEqual({reply, {error, invalid_receipt_id}, S}, call(
            {approve_inference_retry, Id, 1, accept_duplicate_inference_cost}, S))
    end, [undefined, '_', '$1', <<>>, <<"bad">>, binary:copy(<<"z">>, 64)]).

missing_receipt_is_not_created_test() ->
    with_store(fun(S) ->
        ?assertEqual({reply, {error, not_found}, S}, call({inference_receipt, id()}, S)),
        ?assertEqual({reply, {error, not_found}, S}, call(approval(1), S)),
        ?assertEqual([], dets:lookup(?TAB, {inference_receipt, id()}))
    end).

unknown_state_fails_closed_test() ->
    with_store(fun(S0) ->
        S = seed(unrecognized_state, #{}, S0),
        ?assertMatch({reply, {error, invalid_inference_receipt_state}, _},
                     call({receipt_claim, id(), #{}}, S)),
        ?assertMatch([{{inference_receipt, _}, #{status := unrecognized_state}}],
                     dets:lookup(?TAB, {inference_receipt, id()}))
    end).

concurrent_claims_have_one_winner_test() ->
    with_store(fun(S0) ->
        S1 = seed(uncertain, #{}, S0),
        {reply, {ok, _}, S2} = call(approval(1), S1),
        %% This test loop serializes the real callbacks like gen_server does.
        %% Workers race at the call boundary; no provider function is invoked.
        Server = spawn_link(fun() -> callback_loop(S2) end),
        Parent = self(), Tag = make_ref(),
        try
            [spawn_link(fun() -> Parent ! {Tag, gen_server:call(Server,
                {receipt_claim, id(), #{}}, 5000)} end) || _ <- [1, 2]],
            Replies = [receive {Tag, R} -> R after 6000 -> error(claim_timeout) end
                       || _ <- [1, 2]],
            ?assertEqual(1, length([ok || {ok, claimed} <- Replies])),
            ?assertEqual(1, length([ok || {blocked, #{status := claimed}} <- Replies]))
        after
            ok = gen_server:call(Server, test_stop, 5000)
        end
    end).

callback_loop(State) ->
    receive
        {'$gen_call', From, test_stop} -> gen_server:reply(From, ok);
        {'$gen_call', From, Msg} ->
            {reply, Reply, NewState} = ecai_ollama_pool:handle_call(Msg, From, State),
            gen_server:reply(From, Reply), callback_loop(NewState)
    end.
