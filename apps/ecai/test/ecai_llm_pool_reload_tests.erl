-module(ecai_llm_pool_reload_tests).
-include_lib("eunit/include/eunit.hrl").

%% Exercise callbacks and lease ownership without any networking or receipts.
%% This private test record must match ecai_ollama_pool's state layout.
-record(state, {nodes=#{}, leases=#{}, seq=0, health_interval_ms=30000,
    health_timeout_ms=5000, failure_threshold=2, last_probe_at=undefined,
    receipt_tab=undefined, receipt_file=undefined, probe_timer=undefined,
    config_revision=0}).
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
