%% Anonymous demos must never share the durable account store or another cookie.
-module(ecai_supply_chain_public_tests).
-include_lib("eunit/include/eunit.hrl").

public_origin_guard_test() ->
    O= <<"https://ecai.example">>,
    ?assertEqual(ok,ecai_supply_chain_http:public_guard(<<"same-origin">>,O,O,<<"1">>)),
    ?assertEqual(ok,ecai_supply_chain_http:public_guard(<<>>,undefined,O,<<"1">>)),
    lists:foreach(fun({Site,Origin,Header}) ->
        ?assertEqual({error,public_origin_rejected},ecai_supply_chain_http:public_guard(Site,Origin,O,Header))
    end,[{<<"cross-site">>,O,<<"1">>},{<<"same-site">>,O,<<"1">>},
         {<<"same-origin">>,<<"https://other.example">>,<<"1">>},
         {<<"same-origin">>,<<"null">>,<<"1">>},{<<"same-origin">>,O,<<>>}]).

guest_isolation_test() ->
    G=store(#{}),
    {ok,A,TA}=ecai_supply_chain_guest:admit(G,undefined,{127,0,0,1},true,state),
    {ok,B,TB}=ecai_supply_chain_guest:admit(G,undefined,{127,0,0,2},true,state),
    ?assertNotEqual(A,B),?assertNotEqual(TA,TB),?assertEqual(64,byte_size(TA)),
    ?assert(ecai_supply_chain_guest:is_guest(A)),?assertNot(ecai_supply_chain_guest:is_guest(TA)),
    ?assertEqual(undefined,ecai_supply_chain_guest:load(G,A)),
    ok=ecai_supply_chain_guest:save(G,A,#{revision => 4}),
    ?assertEqual(undefined,ecai_supply_chain_guest:load(G,B)),
    ?assertEqual({ok,A,TA},ecai_supply_chain_guest:admit(G,TA,{127,0,0,1},false,event)),
    ?assertEqual(#{revision => 4},ecai_supply_chain_guest:load(G,A)),
    ?assertThrow({supply_chain,guest_session_expired},ecai_supply_chain_guest:admit(G,<<"forged-token">>,{127,0,0,1},false,state)).

%% Expiry is deterministic via an injected clock; no sleeps or wall-clock races.
guest_expiry_test() ->
    put(guest_clock,0),G=store(#{guest_ttl_ms => 100}),
    {ok,A,T}=ecai_supply_chain_guest:admit(G,undefined,peer,true,state),
    ok=ecai_supply_chain_guest:save(G,A,#{revision => 7}),
    put(guest_clock,100),
    ?assertThrow({supply_chain,guest_session_expired},ecai_supply_chain_guest:load(G,A)),
    ?assertThrow({supply_chain,guest_session_expired},ecai_supply_chain_guest:save(G,A,#{revision => 8})),
    ?assertThrow({supply_chain,guest_session_expired},ecai_supply_chain_guest:admit(G,T,peer,false,plan)),
    {ok,B,_}=ecai_supply_chain_guest:admit(G,T,peer,true,state),
    ?assertNotEqual(A,B),?assertEqual(undefined,ecai_supply_chain_guest:load(G,B)).

guest_capacity_test() ->
    G=store(#{max_guests => 1}),
    {ok,A,T}=ecai_supply_chain_guest:admit(G,undefined,a,true,state),
    ?assertThrow({supply_chain,guest_capacity},ecai_supply_chain_guest:admit(G,undefined,b,true,state)),
    ?assertEqual({ok,A,T},ecai_supply_chain_guest:admit(G,T,a,false,state)),
    ?assertThrow({supply_chain,guest_session_expired},ecai_supply_chain_guest:admit(G,<<"forged">>,a,false,reset)).

guest_rate_limit_test() ->
    G=store(#{}),
    {ok,_,T}=ecai_supply_chain_guest:admit(G,undefined,a,true,state),
    lists:foreach(fun(_) -> {ok,_,T}=ecai_supply_chain_guest:admit(G,T,a,false,benchmark) end,lists:seq(1,3)),
    ?assertThrow({supply_chain,guest_rate_limited},ecai_supply_chain_guest:admit(G,T,a,false,benchmark)),
    put(guest_clock,10000),
    ?assertMatch({ok,_,T},ecai_supply_chain_guest:admit(G,T,a,false,benchmark)).

guest_peer_table_bound_test() ->
    G=store(#{max_guest_peers => 1}),
    {ok,_,_}=ecai_supply_chain_guest:admit(G,undefined,a,true,state),
    ?assertThrow({supply_chain,guest_rate_limited},ecai_supply_chain_guest:admit(G,undefined,b,true,state)),
    put(guest_clock,60000),
    ?assertMatch({ok,_,_},ecai_supply_chain_guest:admit(G,undefined,b,true,state)).

guest_workspace_regression_test_() -> {timeout,120,fun() ->
    Dir=filename:join("/tmp","ecai-public-test-"++integer_to_list(erlang:unique_integer([positive]))),
    Opts=#{dir => Dir,table => ecai_supply_chain_public_test_store,max_owners => 1},
    {ok,Pid}=ecai_supply_chain_srv:start_link(Opts),
    try
        {ok,A,TA,1800}=ecai_supply_chain_srv:guest_session(Pid,undefined,a,true,state),
        {ok,B,_,1800}=ecai_supply_chain_srv:guest_session(Pid,undefined,b,true,state),
        {ok,W}=req(Pid,reset,A,#{<<"expected_revision">> => 0,<<"seed">> => 42}),
        ?assertEqual(true,maps:get(exists,W)),
        {ok,Other}=req(Pid,state,B,#{}),?assertEqual(false,maps:get(exists,Other)),
        ?assertEqual(0,dets:info(ecai_supply_chain_public_test_store,size)),
        {ok,Private}=req(Pid,reset,<<"alice">>,#{<<"expected_revision">> => 0,<<"seed">> => 43}),
        ?assertEqual(1,dets:info(ecai_supply_chain_public_test_store,size)),
        ?assertNotEqual(maps:get(scenario,W),maps:get(scenario,Private)),
        {ok,Proposed}=req(Pid,plan,A,#{<<"expected_revision">> => 1,<<"mode">> => <<"ecai">>}),
        Proposal=maps:get(proposal,Proposed),
        {ok,Changed}=req(Pid,event,A,#{<<"expected_revision">> => 1,<<"event">> =>
            #{<<"kind">> => <<"road">>,<<"id">> => <<"bridge-central">>,<<"closed">> => true}}),
        ?assertEqual(2,maps:get(revision,Changed)),
        ?assertEqual({error,stale_plan},req(Pid,approve,A,#{<<"expected_revision">> => 2,<<"plan_id">> => maps:get(id,Proposal)})),
        ?assertEqual({error,unexpected_fields},req(Pid,plan,A,#{<<"expected_revision">> => 2,<<"owner">> => <<"alice">>})),
        ok=gen_server:stop(Pid),
        {ok,Again}=ecai_supply_chain_srv:start_link(Opts),
        try
            ?assertEqual({error,guest_session_expired},ecai_supply_chain_srv:guest_session(Again,TA,a,false,state)),
            {ok,Saved}=req(Again,state,<<"alice">>,#{}),?assertEqual(1,maps:get(revision,Saved)),
            {ok,C,_,_}=ecai_supply_chain_srv:guest_session(Again,undefined,c,true,state),
            {ok,Empty}=req(Again,state,C,#{}),?assertEqual(false,maps:get(exists,Empty))
        after gen_server:stop(Again) end
    after
        case is_process_alive(Pid) of true -> gen_server:stop(Pid);false -> ok end,
        file:del_dir_r(Dir)
    end
end}.

store(Options) ->
    put(guest_clock,0),ecai_supply_chain_guest:new(Options#{guest_clock => fun() -> get(guest_clock) end}).
req(Pid,Action,Owner,Body) -> ecai_supply_chain_srv:request(Pid,Action,Owner,Body).
