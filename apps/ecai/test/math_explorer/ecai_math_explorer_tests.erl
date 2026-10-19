-module(ecai_math_explorer_tests).
-include_lib("eunit/include/eunit.hrl").
-define(C,ecai_math_curve).
-define(I,ecai_math_isogeny).
-define(S,ecai_math_isomorphism).
-define(E,ecai_math_explorer).
-define(F,ecai_math_pathfinder).
c(A,B,D) -> {ok,E}=?C:new(A,B,D), E.
seed() -> c(0,-1,0).
cmp(A,B) -> {ok,R}=?S:compare(A,B), R.
relation(A,B) -> maps:get(relation,cmp(A,B)).
run(O) -> {ok,R}=?E:explore(seed(),O), R.

invariants_1728_test() -> {ok,I}=?S:invariants(seed()),?assertEqual({1728,1},maps:get(j,I)).
invariants_zero_test() -> {ok,I}=?S:invariants(c(0,0,1)),?assertEqual({0,1},maps:get(j,I)).
identity_classification_test() -> ?assertEqual(isomorphic,relation(seed(),seed())).
same_j_not_isomorphic_test() ->
    R=cmp(seed(),c(0,4,0)),?assertEqual(non_isomorphic,maps:get(relation,R)),
    ?assertEqual(fourth_power_obstruction,maps:get(reason,R)).
same_j_positive_non_power_test() -> ?assertEqual(non_isomorphic,relation(c(0,1,0),c(0,2,0))).
scaling_isomorphic_test() ->
    R=cmp(seed(),c(0,-16,0)),?assertEqual(isomorphic,maps:get(relation,R)),
    ?assertEqual({2,1},maps:get(forward_scale,R)),
    ?assertMatch({ok,_},?I:check(maps:get(witness,R))).
translation_isomorphic_test() ->
    %% Forward map (x,y) -> (4x+4,8y).
    R=cmp(seed(),c(-12,32,0)),?assertEqual(isomorphic,maps:get(relation,R)),
    ?assertEqual({4,1},maps:get(x_shift,R)).
general_j_scaling_test() ->
    E=c(0,-2,1),{ok,M}=?I:scale(E,{3,2}),
    ?assertEqual(isomorphic,relation(E,maps:get(codomain,M))).
general_j_twist_test() -> ?assertEqual(non_isomorphic,relation(c(0,-2,1),c(0,-8,8))).
general_j_negative_twist_test() -> ?assertEqual(non_isomorphic,relation(c(0,-2,1),c(0,-2,-1))).
general_j_distinct_test() -> ?assertEqual(non_isomorphic,relation(seed(),c(0,-2,1))).
sixth_power_yes_test() -> ?assertEqual(isomorphic,relation(c(0,0,1),c(0,0,64))).
sixth_power_no_test() -> ?assertEqual(non_isomorphic,relation(c(0,0,1),c(0,0,2))).
sixth_negative_test() -> ?assertEqual(non_isomorphic,relation(c(0,0,1),c(0,0,-1))).
fractional_fourth_test() -> ?assertEqual(isomorphic,relation(seed(),c(0,{-1,16},0))).
fractional_sixth_test() -> ?assertEqual(isomorphic,relation(c(0,0,1),c(0,0,{1,64}))).
large_power_test() ->
    U=(1 bsl 80)+1,{ok,M}=?I:scale(seed(),U),
    ?assertEqual(isomorphic,relation(seed(),maps:get(codomain,M))).
certificate_tamper_test() ->
    R=cmp(seed(),c(0,4,0)),
    ?assertEqual({error,isomorphism_certificate_mismatch},?S:verify(seed(),c(0,4,0),R#{relation:=isomorphic})).
certificate_replay_test() -> R=cmp(seed(),c(0,-16,0)),?assertEqual({ok,R},?S:verify(seed(),c(0,-16,0),R)).
unsupported_field_test() -> ?assertMatch({error,_},?S:compare((seed())#{field:=r},seed())).
singular_rejected_test() -> ?assertMatch({error,_},?S:invariants((seed())#{a4:={0,1}})).
from_steps_identity_test() -> {ok,P}=?F:from_steps(seed(),[]),?assertEqual(0,maps:get(hops,P)),?assertMatch({ok,_},?F:verify_path(P)).
from_steps_map_test() -> {ok,M}=?I:two(seed(),0),{ok,P}=?F:from_steps(seed(),[#{map=>M,cost=>1,origins=>[<<"test">>]}]),?assertEqual(2,maps:get(total_degree,P)).
from_steps_bad_cost_test() -> {ok,M}=?I:two(seed(),0),?assertMatch({error,_},?F:from_steps(seed(),[#{map=>M,cost=>0,origins=>[]}])).
source_only_rejects_target_test() -> ?assertMatch({error,_},?E:explore(seed(),#{target=>seed()})).
invalid_budget_test() -> ?assertMatch({error,_},?E:explore(seed(),#{max_depth=>4})).
zero_depth_test() -> R=run(#{max_depth=>0}),?assertEqual(1,maps:get(retained_models,maps:get(summary,R))),?assertEqual(bounded_search_exhausted,maps:get(stop_reason,R)).
model_budget_retains_source_test() -> R=run(#{max_curves=>1}),?assertEqual(model_budget,maps:get(stop_reason,R)),?assertEqual(1,length(maps:get(results,R))),?assertEqual(false,maps:get(completed_within_declared_bounds,R)).
model_budget_retains_path_test() -> R=run(#{max_curves=>2}),?assertEqual(model_budget,maps:get(stop_reason,R)),?assertEqual(2,length(maps:get(results,R))).
no_rational_kernel_test() ->
    {ok,R}=?E:explore(c(0,0,1),#{numerator_bound=>0,max_depth=>2}),
    ?assertEqual(1,length(maps:get(results,R))),?assertEqual(bounded_search_exhausted,maps:get(stop_reason,R)).
first_layer_classes_test_() -> {timeout,45,fun() ->
    R=run(#{max_depth=>1,timeout_ms=>20000}), S=maps:get(summary,R),
    ?assertEqual(4,maps:get(retained_models,S)),?assertEqual(4,maps:get(local_q_classes,S)),
    ?assertEqual(3,maps:get(non_isomorphic_to_source_models,S)) end}.
second_layer_groups_scalings_test_() -> {timeout,45,fun() ->
    R=run(#{max_depth=>2,timeout_ms=>20000}), S=maps:get(summary,R),
    ?assertEqual(7,maps:get(retained_models,S)),?assertEqual(4,maps:get(local_q_classes,S)),
    ?assertEqual(3,maps:get(non_isomorphic_to_source_models,S)),
    ?assertEqual(3,maps:get(isomorphic_to_source_other_models,S)) end}.
every_path_replays_test_() -> {timeout,45,fun() ->
    R=run(#{max_depth=>2,timeout_ms=>20000}),
    lists:foreach(fun(Row)->
        ?assertMatch({ok,_},?F:verify_path(maps:get(path,Row))),
        ?assertMatch({ok,_},?S:verify(seed(),maps:get(curve,Row),maps:get(comparison_to_source,Row)))
    end,maps:get(results,R)) end}.
source_change_is_not_fixture_test_() -> {timeout,45,fun() ->
    E=c(0,-2,0),{ok,R}=?E:explore(E,#{max_depth=>1,timeout_ms=>20000}),
    ?assertEqual(E,maps:get(source,R)),?assertEqual(2,length(maps:get(results,R))) end}.
exact_json_export_test_() -> {timeout,45,fun() ->
    R=run(#{max_depth=>1,timeout_ms=>20000}),{ok,B}=?E:encode(R),W=json:decode(B),
    ?assertEqual(<<"mathematical_exploration">>,maps:get(<<"kind">>,W)),
    lists:foreach(fun(Row)->
        Bin=maps:get(<<"path_json">>,Row),?assertMatch({ok,_},ecai_math_codec:decode(Bin)),
        ?assertEqual(binary:encode_hex(crypto:hash(sha256,Bin)),maps:get(<<"artifact_sha256">>,Row))
    end,maps:get(<<"results">>,W)) end}.
deterministic_retained_models_test_() -> {timeout,90,fun()->
    O=#{max_depth=>1,timeout_ms=>20000},A=run(O),B=run(O),
    ?assertEqual(maps:get(results,A),maps:get(results,B)) end}.

api_rejects_target_test() ->
    B=explore_body(),?assertMatch({error,_},ecai_math_dashboard_task:prepare(B#{<<"target">>=>#{}})).
api_accepts_source_only_test() -> ?assertMatch({ok,#{operation:=explore}},ecai_math_dashboard_task:prepare(explore_body())).
api_bounds_limit_test() -> ?assertMatch({error,_},ecai_math_dashboard_task:prepare((explore_body())#{<<"bounds">>=>#{<<"max_curves">>=>33}})).
api_execute_explore_test_() -> {timeout,45,fun()->
    {ok,T}=ecai_math_dashboard_task:prepare(explore_body()),{ok,R}=ecai_math_dashboard_task:execute(T),
    ?assertNot(maps:is_key(path_json,R)),?assert(maps:is_key(exploration_json,R)),
    ?assertEqual(not_attached,maps:get(independent_check,maps:get(evidence,R))) end}.
explore_body() -> #{<<"operation">>=><<"explore">>,<<"source">>=>#{<<"a2">>=>[<<"0">>,<<"1">>],<<"a4">>=>[<<"-1">>,<<"1">>],<<"a6">>=>[<<"0">>,<<"1">>]},<<"bounds">>=>#{<<"max_depth">>=>1,<<"timeout_ms">>=>20000}}.

bdd_discovery_steps_test_() -> {timeout,45,fun()->
    C0=steps_ecai_math_explorer:step([],#{},<<"Given">>,1,["the source-only mathematical exploration seed"],<<>>),
    C1=steps_ecai_math_explorer:step([],C0,<<"When">>,2,["I explore from the mathematical source without a target"],<<>>),
    C2=steps_ecai_math_explorer:step([],C1,<<"Then">>,3,["the exploration has four rational isomorphism classes"],<<>>),
    C3=steps_ecai_math_explorer:step([],C2,<<"Then">>,4,["every retained exploration path replays successfully"],<<>>),
    C4=steps_ecai_math_explorer:step([],C3,<<"Then">>,5,["every retained source-isomorphism certificate rechecks successfully"],<<>>),
    ?assertNot(maps:is_key(fail,C4)),?assert(maps:is_key(ecai_exploration_json,C4)) end}.
bdd_budget_steps_test_() -> {timeout,45,fun()->
    C0=steps_ecai_math_explorer:step([],#{},<<"Given">>,1,["the source-only mathematical exploration seed"],<<>>),
    C1=steps_ecai_math_explorer:step([],C0,<<"When">>,2,["I explore with a two-model mathematical budget"],<<>>),
    C2=steps_ecai_math_explorer:step([],C1,<<"Then">>,3,["the exploration retains two checked models and reports its limit"],<<>>),
    ?assertNot(maps:is_key(fail,C2)) end}.
