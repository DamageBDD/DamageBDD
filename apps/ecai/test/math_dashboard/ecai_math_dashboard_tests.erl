-module(ecai_math_dashboard_tests).
-include_lib("eunit/include/eunit.hrl").
-define(T, ecai_math_dashboard_task).
-define(S, ecai_math_dashboard_srv).

prepare_demo_test() -> ?assertEqual({ok, #{operation => demo}}, ?T:prepare(#{<<"operation">> => <<"demo">>})).
unknown_fields_test() -> ?assertEqual({error, unexpected_fields}, ?T:prepare(#{<<"operation">> => <<"demo">>, <<"owner">> => <<"other">>})).
invalid_operation_test() -> ?assertMatch({error,_}, ?T:prepare(#{<<"operation">> => <<"eval">>})).
exact_coefficients_test() ->
    {ok, T} = ?T:prepare(discover()),
    ?assertEqual({-1,1}, maps:get(a4,maps:get(source,T))).
float_rejected_test() ->
    B = discover(), C = maps:get(<<"source">>, B),
    ?assertMatch({error,_}, ?T:prepare(B#{<<"source">> := C#{<<"a4">> := -1.0}})).
numeric_pair_rejected_test() ->
    B = discover(), C = maps:get(<<"source">>, B),
    ?assertMatch({error,_}, ?T:prepare(B#{<<"source">> := C#{<<"a4">> := [-1,1]}})).
zero_denominator_test() ->
    B = discover(), C = maps:get(<<"source">>, B),
    ?assertMatch({error,_}, ?T:prepare(B#{<<"source">> := C#{<<"a4">> := [<<"1">>,<<"0">>]}})).
singular_source_test() ->
    B = discover(), C = maps:get(<<"source">>, B),
    ?assertEqual({error,singular_curve}, ?T:prepare(B#{<<"source">> := C#{<<"a4">> := [<<"0">>,<<"1">>]}})).
bounds_rejected_test() -> ?assertMatch({error,_},?T:prepare((discover())#{<<"bounds">> => #{<<"max_depth">> => 4}})).
unknown_bounds_test() -> ?assertMatch({error,_},?T:prepare((discover())#{<<"bounds">> => #{<<"timeout_ms">> => 999999}})).
oversized_import_test() -> ?assertMatch({error,_},?T:prepare(#{<<"operation">> => <<"import">>,<<"path_json">> => binary:copy(<<"x">>,262145)})).

demo_exec_test() ->
    {ok,R} = ?T:execute(#{operation=>demo}), P=maps:get(path,R),
    ?assertEqual(<<"4">>,maps:get(<<"total_degree">>,P)),
    ?assertEqual(2,maps:get(<<"hops">>,P)),
    ?assertEqual(maps:get(artifact_sha256,R),binary:encode_hex(crypto:hash(sha256,maps:get(path_json,R)))),
    ?assertEqual(not_attached,maps:get(independent_check,maps:get(evidence,R))).
discover_exec_test_() -> {timeout,35,fun() ->
    {ok,T}=?T:prepare(discover()), {ok,R}=?T:execute(T),
    ?assertEqual(2,maps:get(<<"hops">>,maps:get(path,R))),
    ?assert(maps:is_key(generation_bounds,maps:get(metadata,R))) end}.
import_rechecks_test() ->
    {ok,R}=?T:execute(#{operation=>demo}), W=maps:get(path,R),
    Input=iolist_to_binary(json:encode(W#{<<"verification">>=>#{<<"status">>=><<"forged">>,<<"formal_proof">>=>true},
                                        <<"search">>=>#{<<"checked_edges">>=>999}})),
    {ok,New}=?T:execute(#{operation=>import,path_json=>Input}), P=maps:get(path,New),
    ?assertNot(maps:is_key(<<"search">>,P)),
    ?assertEqual(false,maps:get(<<"formal_proof">>,maps:get(<<"verification">>,P))),
    ?assertEqual(<<"verified">>,maps:get(<<"status">>,maps:get(<<"verification">>,P))).
tampered_import_test() ->
    {ok,R}=?T:execute(#{operation=>demo}), W=maps:get(path,R),
    Bin=iolist_to_binary(json:encode(W#{<<"total_degree">>:=<<"999">>})),
    ?assertMatch({error,_},?T:execute(#{operation=>import,path_json=>Bin})).
malformed_import_test() -> ?assertMatch({error,_},?T:execute(#{operation=>import,path_json=><<"{oops">>})).
graph_import_rejected_test() -> ?assertEqual({error,mathematical_path_required},?T:execute(#{operation=>import,path_json=><<"{\"kind\":\"math_graph\"}">>})).
hop_limit_test() ->
    W=#{<<"kind">>=><<"mathematical_path">>,<<"steps">>=>lists:duplicate(17,#{})},
    ?assertEqual({error,dashboard_hop_limit},?T:execute(#{operation=>import,path_json=>iolist_to_binary(json:encode(W))})).

owner_isolation_test() -> with_server(fun() ->
    {ok,J}=?S:submit(<<"alice">>,#{<<"operation">>=><<"demo">>}), Id=maps:get(id,J),
    ?assertEqual({error,not_found},?S:get(<<"bob">>,Id)),
    ?assertEqual({error,not_found},?S:replay(<<"bob">>,Id)),
    ?assertEqual({ok,[]},?S:list(<<"bob">>)),
    Final=await(<<"alice">>,Id,200), ?assertEqual(succeeded,maps:get(status,Final)),
    ?assertNot(maps:is_key(owner,Final)), ?assertNot(maps:is_key(pid,Final)),
    {ok,[Summary]}=?S:list(<<"alice">>), ?assertNot(maps:is_key(result,Summary)) end).
rate_limit_test() -> with_server(fun() ->
    {ok,_}=?S:submit(<<"alice">>,#{<<"operation">>=><<"demo">>}),
    ?assertMatch({error,_},?S:submit(<<"alice">>,#{<<"operation">>=><<"demo">>})) end).
replay_new_job_test_() -> {timeout,10,fun() -> with_server(fun() ->
    {ok,J}=?S:submit(<<"alice">>,#{<<"operation">>=><<"demo">>}), Id=maps:get(id,J),
    First=await(<<"alice">>,Id,200),timer:sleep(1050),
    {ok,R}=?S:replay(<<"alice">>,Id), NewId=maps:get(id,R),
    ?assertNotEqual(Id,NewId),Final=await(<<"alice">>,NewId,200),
    ?assertEqual(Id,maps:get(replayed_job_id,Final)),
    P1=maps:get(path,maps:get(result,First)),P2=maps:get(path,maps:get(result,Final)),
    ?assertEqual(maps:get(<<"id">>,P1),maps:get(<<"id">>,P2)) end) end}.
failed_job_test() -> with_server(fun() ->
    {ok,J}=?S:submit(<<"alice">>,#{<<"operation">>=><<"import">>,<<"path_json">>=><<"oops">>}),
    Final=await(<<"alice">>,maps:get(id,J),200),
    ?assertEqual(failed,maps:get(status,Final)), ?assertNot(maps:is_key(result,Final)) end).
invalid_owner_test() -> with_server(fun() -> ?assertEqual({error,authenticated_account_required},?S:submit(<<>>,#{<<"operation">>=><<"demo">>})) end).
disabled_test() ->
    Old=application:get_env(ecai,math_dashboard_enabled), application:set_env(ecai,math_dashboard_enabled,false),
    try ?assertEqual([],?S:child_specs()),?assertEqual({error,math_dashboard_disabled},?S:list(<<"alice">>))
    after restore(Old) end.

with_server(Fun) ->
    application:ensure_all_started(crypto),
    Old=application:get_env(ecai,math_dashboard_enabled),application:set_env(ecai,math_dashboard_enabled,true),
    {ok,Pid}=?S:start_link(),
    try Fun() after gen_server:stop(Pid),restore(Old) end.
restore(undefined) -> application:unset_env(ecai,math_dashboard_enabled);
restore({ok,V}) -> application:set_env(ecai,math_dashboard_enabled,V).
await(_,_,0) -> error(job_did_not_finish);
await(O,Id,N) ->
    {ok,J}=?S:get(O,Id),
    case maps:get(status,J) of running -> timer:sleep(10),await(O,Id,N-1); _ -> J end.
discover() ->
    #{<<"operation">>=><<"discover">>,<<"source">>=>c(<<"-1">>),<<"target">>=>c(<<"-16">>)}.
c(A4) -> #{<<"a2">>=>[<<"0">>,<<"1">>],<<"a4">>=>[A4,<<"1">>],<<"a6">>=>[<<"0">>,<<"1">>]}.
