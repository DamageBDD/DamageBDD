-module(ecai_llm_pool_reload_tests).
-include_lib("eunit/include/eunit.hrl").

%% Exercise callbacks and lease ownership without any networking or receipts.
%% This private test record must match ecai_ollama_pool's state layout.
-record(state, {nodes=#{}, leases=#{}, seq=0, health_interval_ms=30000,
    health_timeout_ms=5000, failure_threshold=2, last_probe_at=undefined,
    receipt_tab=undefined, receipt_file=undefined, probe_timer=undefined,
    config_revision=0, receipt_counts=#{}, lease_started=#{}, probes=#{}}).
fixture_node(Model) -> #{id => <<"unit">>, provider => ollama, enabled => true,
    host => "127.0.0.1", port => 11434, roles => [patch],
    default_model => Model, models => all, auth => none}.
state() ->
    {ok, Ns} = ecai_ollama_pool:validate_nodes([fixture_node(<<"old-model">>)]),
    #state{nodes=maps:map(fun(_,N)->N#{health=>healthy} end,Ns)}.
runtime() -> #{<<"health_interval_ms">> => 30000, <<"health_timeout_ms">> => 5000,
               <<"failure_threshold">> => 2}.
reload_retains_lease_and_rejects_stale_health_test() ->
    S0 = state(), OldToken = maps:get(config_token, maps:get(<<"unit">>, S0#state.nodes)),
    {reply, {ok, Lease}, S1} = ecai_ollama_pool:handle_call(
        {checkout, patch, any, undefined, []}, {self(), make_ref()}, S0),
    Ref = maps:get(ref, Lease),
    {reply, ok, S2} = ecai_ollama_pool:handle_call(
        {reconfigure, [fixture_node(<<"new-model">>)], runtime(), 7, fun()->ok end},
        {self(),make_ref()}, S1),
    receive probe_all -> ok after 0 -> ok end,
    ?assertEqual(<<"old-model">>, maps:get(model, Lease)),
    ?assertEqual(1, maps:get(inflight, maps:get(<<"unit">>, S2#state.nodes))),
    {noreply,S3} = ecai_ollama_pool:handle_cast(
        {probe_result, <<"unit">>, OldToken, {ok, #{models=>#{}}}, 1}, S2),
    ?assertEqual(unknown, maps:get(health,maps:get(<<"unit">>, S3#state.nodes))),
    {noreply,S4} = ecai_ollama_pool:handle_cast({checkin,Ref,#{ok=>true,duration_ms=>1}},S3),
    ?assertEqual(unknown, maps:get(health,maps:get(<<"unit">>, S4#state.nodes))),
    ?assertEqual(0, maps:get(inflight,maps:get(<<"unit">>, S4#state.nodes))),
    ?assertEqual(0, map_size(S4#state.leases)).
failed_commit_preserves_configuration_test() ->
    S0 = state(),
    ?assertEqual({reply,{error,persistence_failed},S0}, ecai_ollama_pool:handle_call(
        {reconfigure, [], runtime(), 1, fun()->{error,persistence_failed} end},
        {self(),make_ref()},S0)).
disabled_node_cannot_route_test() ->
    {ok,Ns} = ecai_ollama_pool:validate_nodes([(fixture_node(<<"fixture">>))#{enabled=>false}]),
    S = #state{nodes=maps:map(fun(_,N)->N#{health=>healthy} end,Ns)},
    ?assertMatch({reply,{error,{no_eligible_inference_node,patch,any,undefined}},_},
        ecai_ollama_pool:handle_call({checkout,patch,any,undefined,[]},{self(),make_ref()},S)).
owner_death_releases_capacity_test() ->
    Owner=spawn(fun()->receive stop->ok end end), S0=state(),
    {reply,{ok,Lease},S1}=ecai_ollama_pool:handle_call(
        {checkout,patch,any,undefined,[]},{Owner,make_ref()},S0),
    {_,_,Monitor}=maps:get(maps:get(ref,Lease),S1#state.leases),
    Owner ! stop,
    receive
        Down={'DOWN',Monitor,process,Owner,_} ->
            {noreply,S2}=ecai_ollama_pool:handle_info(Down,S1),
            ?assertEqual(0,map_size(S2#state.leases)),
            ?assertEqual(0,maps:get(inflight,maps:get(<<"unit">>,S2#state.nodes)))
    after 1000 -> erlang:error(monitor_timeout)
    end.

status_uses_cached_receipt_counts_without_dets_test() ->
    %% A deliberately unopened table proves status performs no DETS call.
    S = (state())#state{receipt_tab = unopened_receipt_table,
                       receipt_counts = #{completed => 42, uncertain => 2}},
    {reply, Status, S} = ecai_ollama_pool:handle_call(status, {self(), make_ref()}, S),
    ?assertEqual(#{completed => 42, uncertain => 2},
                 maps:get(statuses, maps:get(inference_receipts, Status))).

saturation_and_lease_age_test() ->
    {reply, {ok, Lease}, S1} = ecai_ollama_pool:handle_call(
        {checkout, patch, any, undefined, []}, {self(), make_ref()}, state()),
    Ref = maps:get(ref, Lease),
    S2 = S1#state{lease_started = #{Ref => erlang:monotonic_time(millisecond) - 1000}},
    {reply, #{nodes := [N], available_capacity := Available}, _} =
        ecai_ollama_pool:handle_call(status, {self(), make_ref()}, S2),
    ?assertEqual(true, maps:get(saturated, N)),
    ?assertEqual(0, maps:get(available_slots, N)),
    ?assert(maps:get(oldest_inflight_ms, N) >= 1000),
    ?assertEqual(0, maps:get(patch, Available)),
    {noreply, S3} = ecai_ollama_pool:handle_cast({release, Ref}, S2),
    ?assertEqual(#{}, S3#state.lease_started).

first_failed_probe_is_not_a_routable_node_test() ->
    {ok, Ns} = ecai_ollama_pool:validate_nodes([fixture_node(<<"old-model">>)]),
    S0 = #state{nodes = Ns}, Token = maps:get(config_token, maps:get(<<"unit">>, Ns)),
    {noreply, S1} = ecai_ollama_pool:handle_cast(
        {probe_result, <<"unit">>, Token, {error, probe_failed}, 1}, S0),
    ?assertMatch({reply, {error, no_capacity}, _}, ecai_ollama_pool:handle_call(
        {checkout, patch, any, undefined, []}, {self(), make_ref()}, S1)),
    {noreply, S2} = ecai_ollama_pool:handle_cast(
        {probe_result, <<"unit">>, Token, {ok, #{models => #{<<"old-model">> => #{}}}}, 2}, S1),
    {reply, {ok, Lease}, S3} = ecai_ollama_pool:handle_call(
        {checkout, patch, any, undefined, []}, {self(), make_ref()}, S2),
    Error = {ollama_request_failed, {await_body_failed, {error, timeout}}},
    {noreply, S4} = ecai_ollama_pool:handle_cast(
        {checkin, maps:get(ref, Lease), #{ok => false, error => Error, duration_ms => 1000}}, S3),
    {noreply, S5} = ecai_ollama_pool:handle_cast(
        {probe_result, <<"unit">>, Token, {ok, #{models => #{<<"old-model">> => #{}}}}, 2}, S4),
    {reply, #{nodes := [Public]}, _} = ecai_ollama_pool:handle_call(status, {self(), make_ref()}, S5),
    ?assertEqual(undefined, maps:get(last_error, Public)),
    ?assertMatch(#{phase := response_body, reason := timeout}, maps:get(last_request_error, Public)),
    ?assertEqual(1000.0, maps:get(latency_ema_ms, Public)),
    ?assertEqual(2, maps:get(probe_latency_ms, Public)).

refresh_does_not_duplicate_an_active_probe_test() ->
    S0 = state(), Node = maps:get(<<"unit">>, S0#state.nodes),
    Pid = spawn(fun() -> receive stop -> ok end end),
    Monitor = erlang:monitor(process, Pid), Ref = make_ref(),
    S1 = S0#state{probes = #{<<"unit">> => #{pid => Pid, monitor => Monitor,
        ref => Ref, token => maps:get(config_token, Node)}}},
    try
        {noreply, S2} = ecai_ollama_pool:handle_info(probe_now, S1),
        ?assertEqual(S1#state.probes, S2#state.probes),
        {noreply, S3} = ecai_ollama_pool:handle_cast(
            {probe_result, <<"unit">>, maps:get(config_token, Node), make_ref(), {error, probe_failed}, 1}, S2),
        ?assertEqual(S2, S3)
    after Pid ! stop, erlang:demonitor(Monitor, [flush]) end.

receipt_counters_follow_transitions_and_restart_test() ->
    Root = filename:join("/tmp", "ecai-receipt-counts-" ++ integer_to_list(erlang:unique_integer([positive]))),
    Opts = #{state_root => Root, nodes => [(fixture_node(<<"fixture">>))#{enabled => false}]},
    {ok, S0} = ecai_ollama_pool:init(Opts),
    receive probe_all -> ok after 0 -> ok end,
    From = {self(), make_ref()}, Id = <<"unit-receipt">>,
    try
        {reply, {ok, claimed}, S1} = ecai_ollama_pool:handle_call({receipt_claim, Id, #{}}, From, S0),
        ?assertEqual(#{claimed => 1}, S1#state.receipt_counts),
        {reply, ok, S2} = ecai_ollama_pool:handle_call({receipt_sent, Id, #{}}, From, S1),
        ?assertEqual(#{sent => 1}, S2#state.receipt_counts),
        {reply, ok, S3} = ecai_ollama_pool:handle_call({receipt_uncertain, Id,
            {ollama_request_failed, {await_body_failed, {error, timeout}}}}, From, S2),
        ?assertEqual(#{uncertain => 1}, S3#state.receipt_counts),
        {reply, {blocked, _}, S4} = ecai_ollama_pool:handle_call({receipt_claim, Id, #{}}, From, S3),
        ?assertEqual(S3#state.receipt_counts, S4#state.receipt_counts),
        {reply, ok, S5} = ecai_ollama_pool:handle_call({receipt_complete, Id, <<"ok">>, #{}}, From, S4),
        ?assertEqual(#{completed => 1}, S5#state.receipt_counts),
        ok = ecai_ollama_pool:terminate(normal, S5),
        {ok, S6} = ecai_ollama_pool:init(Opts),
        receive probe_all -> ok after 0 -> ok end,
        ?assertEqual(#{completed => 1}, S6#state.receipt_counts),
        {reply, {completed, <<"ok">>, #{}}, S7} = ecai_ollama_pool:handle_call({receipt_claim, Id, #{}}, From, S6),
        ?assertEqual(S6#state.receipt_counts, S7#state.receipt_counts),
        {reply, ok, S8} = ecai_ollama_pool:handle_call({receipt_release, Id}, From, S7),
        ?assertEqual(#{}, S8#state.receipt_counts),
        ok = ecai_ollama_pool:terminate(normal, S8)
    after
        dets:close(ecai_inference_receipts_dets), file:del_dir_r(Root)
    end.
