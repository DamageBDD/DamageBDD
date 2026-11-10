%% Pure model/planner/validator, retrieval and durable workspace regression tests.
-module(ecai_supply_chain_tests).
-include_lib("eunit/include/eunit.hrl").

scenario_test() ->
    S=ecai_supply_chain_model:scenario(42),
    ?assertEqual(S,ecai_supply_chain_model:scenario(42)),
    ?assertEqual(48,length(maps:get(orders,S))),?assertEqual(26,length(maps:get(nodes,S))),
    ?assertEqual(6,length(maps:get(vehicles,S))),
    ?assertNotEqual(ecai_supply_chain_model:fingerprint(S),ecai_supply_chain_model:fingerprint(ecai_supply_chain_model:scenario(43))).

input_rejection_test() ->
    S=ecai_supply_chain_model:scenario(42),
    ?assertThrow({supply_chain,invalid_integer},ecai_supply_chain_model:scenario(0)),
    ?assertThrow({supply_chain,unknown_id},ecai_supply_chain_model:event(S,#{<<"kind">> => <<"road">>,<<"id">> => <<"not-a-road">>,<<"closed">> => true})),
    ?assertThrow({supply_chain,unexpected_fields},ecai_supply_chain_model:event(S,#{<<"kind">> => <<"urgent_order">>,<<"owner">> => <<"other">>})),
    ?assertThrow({supply_chain,invalid_integer},ecai_supply_chain_model:event(S,#{<<"kind">> => <<"demand">>,<<"id">> => <<"O1">>,<<"quantity">> => 999})).

canonical_evidence_test() ->
    A=#{b => 2,a => [true,<<"x">>]},B=#{<<"a">> => [true,<<"x">>],<<"b">> => 2},
    ?assertEqual(ecai_supply_chain_util:json(A),ecai_supply_chain_util:json(B)),
    ?assertEqual(<<"{\"a\":[true,\"x\"],\"b\":2}">>,ecai_supply_chain_util:json(A)),
    ?assertNotEqual(ecai_supply_chain_util:hash(<<"a">>,A),ecai_supply_chain_util:hash(<<"b">>,A)).

planner_regressions_test_() -> {timeout,120,fun() ->
    S=ecai_supply_chain_model:scenario(42),P=ecai_supply_chain_task:plan(S,null,[],cold),
    ?assert(maps:get(valid,ecai_supply_chain_validator:validate(S,P))),
    ?assert(maps:get(on_time,maps:get(metrics,P))>40),
    Again=ecai_supply_chain_task:plan(S,null,[],cold),
    ?assertEqual(ecai_supply_chain_model:skeleton(P),ecai_supply_chain_model:skeleton(Again)),
    ?assertEqual(maps:get(metrics,P),maps:get(metrics,Again)),
    %% A road actually used by this plan must invalidate it when closed.
    [FirstRoute|_]=maps:get(routes,P),
    Used=hd([L || L <- maps:get(legs,FirstRoute),length(maps:get(path,L))>=2]),
    [A,B|_]=maps:get(path,Used),
    Edge=hd([E || E <- maps:get(edges,S),(maps:get(from,E)=:=A andalso maps:get(to,E)=:=B) orelse
                                       (maps:get(from,E)=:=B andalso maps:get(to,E)=:=A)]),
    Broken=ecai_supply_chain_model:event(S,#{<<"kind">> => <<"road">>,<<"id">> => maps:get(id,Edge),<<"closed">> => true}),
    ?assertNot(maps:get(valid,ecai_supply_chain_validator:validate(Broken,P))),
    Repaired=ecai_supply_chain_task:plan(Broken,P,[],warm),
    ?assert(maps:get(valid,ecai_supply_chain_validator:validate(Broken,Repaired))),
    %% No available fleet must produce an honest feasible partial-service plan.
    None=S#{vehicles := [V#{available := false} || V <- maps:get(vehicles,S)]},
    Empty=ecai_supply_chain_task:plan(None,P,[],cold),
    ?assertEqual(48,maps:get(unserved,maps:get(metrics,Empty))),
    ?assertEqual(0,maps:get(on_time,maps:get(metrics,Empty))),
    ?assert(maps:get(valid,maps:get(validation,Empty))),
    ?assertEqual(false,maps:get(optimality_proven,maps:get(validation,Empty))),
    %% The independent checker rejects duplicates, path/timing changes and overload.
    ?assertNot(maps:get(valid,ecai_supply_chain_validator:validate(S,P#{routes := [FirstRoute|maps:get(routes,P)]}))),
    Tampered=FirstRoute#{load := maps:get(load,FirstRoute)+1},
    ?assertNot(maps:get(valid,ecai_supply_chain_validator:validate(S,P#{routes := [Tampered|tl(maps:get(routes,P))]}))),
    [L0|Ls]=maps:get(legs,FirstRoute),BadLeg=L0#{arrive := maps:get(arrive,L0)+1},
    ?assertNot(maps:get(valid,ecai_supply_chain_validator:validate(S,P#{routes := [FirstRoute#{legs := [BadLeg|Ls]}|tl(maps:get(routes,P))]}))),
    LowCapacity=S#{vehicles := [V#{capacity := 0} || V <- maps:get(vehicles,S)]},
    ?assertNot(maps:get(valid,ecai_supply_chain_validator:validate(LowCapacity,P))),
    NoStock=S#{warehouses := [W#{stock := #{<<"chilled">> => 0,<<"produce">> => 0,<<"ambient">> => 0}} || W <- maps:get(warehouses,S)]},
    ?assertNot(maps:get(valid,ecai_supply_chain_validator:validate(NoStock,P))),
    NoCooling=S#{vehicles := [V#{refrigerated := false} || V <- maps:get(vehicles,S)]},
    ?assertNot(maps:get(valid,ecai_supply_chain_validator:validate(NoCooling,P))),
    Expired=S#{warehouses := [W#{expiry := #{<<"chilled">> => 0,<<"produce">> => 0,<<"ambient">> => 0}} || W <- maps:get(warehouses,S)]},
    ?assertNot(maps:get(valid,ecai_supply_chain_validator:validate(Expired,P))),
    ?assertThrow({supply_chain,case_validation_failed},ecai_supply_chain_cases:put(Broken,P,[],1)),
    %% Both case-selection implementations use identical feature/ranking semantics.
    {Cases,Id}=ecai_supply_chain_cases:put(S,P,[],1),
    EC=ecai_supply_chain_cases:retrieve(S,Cases,ecai),Lookup=ecai_supply_chain_cases:retrieve(S,Cases,lookup),
    ?assertEqual(exact,maps:get(kind,EC)),
    ?assertEqual(Id,maps:get(id,maps:get(case_record,EC))),
    ?assertEqual(maps:get(case_record,EC),maps:get(case_record,Lookup)),
    Hit=ecai_supply_chain_task:plan(S,P,Cases,ecai),
    ?assertEqual(retrieved_revalidated,maps:get(source,Hit)),?assertEqual(0,maps:get(search_starts,Hit)),
    Near=ecai_supply_chain_task:plan(Broken,P,Cases,ecai),
    ?assertEqual(retrieved_repaired,maps:get(source,Near)),
    ?assert(maps:get(valid,maps:get(validation,Near))),
    [C]=Cases,Corrupt=C#{digest := <<"tampered">>},
    ?assertEqual(miss,maps:get(kind,ecai_supply_chain_cases:retrieve(S,[Corrupt],ecai))),
    {Dedup,_}=ecai_supply_chain_cases:put(S,P,Cases,2),?assertEqual(1,length(Dedup)),
    Bounded=lists:foldl(fun(N,Cs) -> {Next,_}=ecai_supply_chain_cases:put(S#{stability_weight := N},P,Cs,N),Next end,[],lists:seq(1,70)),
    ?assertEqual(64,length(Bounded)),
    Bench=ecai_supply_chain_task:benchmark(S,P,Cases),?assertEqual(4,length(maps:get(rows,Bench))),
    ?assert(lists:all(fun(R) -> maps:get(valid,R) end,maps:get(rows,Bench)))
end}.

scenario_matrix_test_() -> {timeout,120,fun() ->
    lists:foreach(fun(Seed) ->
        S=ecai_supply_chain_model:scenario(Seed),
        Broken=ecai_supply_chain_model:event(S,#{<<"kind">> => <<"vehicle">>,<<"id">> => <<"T1">>,<<"available">> => false}),
        WithUrgent=ecai_supply_chain_model:event(Broken,#{<<"kind">> => <<"urgent_order">>}),
        P=ecai_supply_chain_task:plan(WithUrgent,null,[],cold),
        ?assert(maps:get(valid,ecai_supply_chain_validator:validate(WithUrgent,P))),
        ?assertEqual(49,length(maps:get(unserved,P))+lists:sum([length(maps:get(orders,R)) || R <- maps:get(routes,P)]))
    end,[1,42,999999])
end}.

workspace_regressions_test_() -> {timeout,120,fun() ->
    Dir=temp_dir(),Opts=#{dir => Dir,table => ecai_supply_chain_test_store},
    {ok,Pid}=ecai_supply_chain_srv:start_link(Opts),
    try
        {ok,Before}=req(Pid,state,<<"alice">>,#{}),?assertEqual(false,maps:get(exists,Before)),
        {ok,W1}=req(Pid,reset,<<"alice">>,#{<<"expected_revision">> => 0,<<"seed">> => 42,<<"keep_cases">> => false}),
        ?assertEqual(1,maps:get(revision,W1)),
        {ok,Bob}=req(Pid,state,<<"bob">>,#{}),?assertEqual(false,maps:get(exists,Bob)),?assertEqual([],maps:get(cases,Bob)),
        ?assertEqual({error,revision_conflict},req(Pid,reset,<<"alice">>,#{<<"expected_revision">> => 0})),
        ?assertEqual({error,unexpected_fields},req(Pid,plan,<<"alice">>,#{<<"expected_revision">> => 1,<<"owner">> => <<"bob">>})),
        {ok,W2}=req(Pid,plan,<<"alice">>,#{<<"expected_revision">> => 1,<<"mode">> => <<"ecai">>}),
        Proposal=maps:get(proposal,W2),?assertEqual(1,maps:get(case_count,W2)),
        {ok,W3}=req(Pid,event,<<"alice">>,#{<<"expected_revision">> => 1,
            <<"event">> => #{<<"kind">> => <<"road">>,<<"id">> => <<"bridge-central">>,<<"closed">> => true}}),
        ?assertEqual(2,maps:get(revision,W3)),
        ?assertEqual({error,stale_plan},req(Pid,approve,<<"alice">>,#{<<"expected_revision">> => 2,<<"plan_id">> => maps:get(id,Proposal)})),
        {ok,New}=req(Pid,plan,<<"alice">>,#{<<"expected_revision">> => 2}),
        {ok,Approved}=req(Pid,approve,<<"alice">>,#{<<"expected_revision">> => 2,<<"plan_id">> => maps:get(id,maps:get(proposal,New))}),
        ?assertEqual(3,maps:get(revision,Approved)),?assertEqual(null,maps:get(proposal,Approved)),
        {ok,Export}=req(Pid,evidence,<<"alice">>,#{}),
        Expected=ecai_supply_chain_util:hex(crypto:hash(sha256,[maps:get(domain,Export),<<0>>,maps:get(manifest_json,Export)])),
        ?assertEqual(Expected,maps:get(digest,Export)),
        ok=gen_server:stop(Pid),
        {ok,Restarted}=ecai_supply_chain_srv:start_link(Opts),
        try
            {ok,Persisted}=req(Restarted,state,<<"alice">>,#{}),
            ?assertEqual(3,maps:get(revision,Persisted)),?assertEqual(maps:get(case_count,Approved),maps:get(case_count,Persisted)),
            {ok,Reset}=req(Restarted,reset,<<"alice">>,#{<<"expected_revision">> => 3,<<"seed">> => 42,<<"keep_cases">> => true}),
            ?assertEqual(4,maps:get(revision,Reset)),?assertEqual(maps:get(case_count,Persisted),maps:get(case_count,Reset)),
            {ok,Cleared}=req(Restarted,reset,<<"alice">>,#{<<"expected_revision">> => 4,<<"keep_cases">> => false}),
            ?assertEqual(0,maps:get(case_count,Cleared))
        after gen_server:stop(Restarted) end
    after case is_process_alive(Pid) of true -> gen_server:stop(Pid);false -> ok end,file:del_dir_r(Dir) end
end}.

bounded_worker_test_() -> {timeout,30,fun() ->
    Dir=temp_dir(),{ok,Pid}=ecai_supply_chain_srv:start_link(#{dir => Dir,table => ecai_supply_chain_test_limit,max_workers => 0}),
    try ?assertEqual({error,worker_capacity},req(Pid,reset,<<"alice">>,#{<<"expected_revision">> => 0}))
    after gen_server:stop(Pid),file:del_dir_r(Dir) end,
    D2=temp_dir(),{ok,P2}=ecai_supply_chain_srv:start_link(#{dir => D2,table => ecai_supply_chain_test_timeout,job_timeout_ms => 1}),
    try
        ?assertEqual({error,planning_timeout},req(P2,reset,<<"alice">>,#{<<"expected_revision">> => 0})),
        {ok,W}=req(P2,state,<<"alice">>,#{}),?assertEqual(false,maps:get(exists,W))
    after gen_server:stop(P2),file:del_dir_r(D2) end
end}.
req(Pid,Op,Owner,B) -> ecai_supply_chain_srv:request(Pid,Op,Owner,B).
temp_dir() -> filename:join("/tmp","ecai-supply-chain-test-"++integer_to_list(erlang:unique_integer([positive,monotonic]))).
