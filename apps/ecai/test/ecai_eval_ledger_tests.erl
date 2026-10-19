%% Isolated DETS/OTP contract tests. Provider calls are mocked, never networked.
%% Requires the umbrella's existing meck test dependency. Do not run against a
%% started production application: setup fails rather than stopping its services.
-module(ecai_eval_ledger_tests).
-include_lib("eunit/include/eunit.hrl").

ledger_test_() ->
    {timeout, 45, {foreach, fun setup/0, fun cleanup/1,
        [fun(C) -> ?_test(tenant_isolation(C)) end,
         fun(C) -> ?_test(settings_cas(C)) end,
         fun(C) -> ?_test(review_required(C)) end,
         fun(C) -> ?_test(idempotency(C)) end,
         fun(C) -> ?_test(restart_does_not_retry(C)) end,
         fun(C) -> ?_test(quota_survives_restart(C)) end]}}.
setup() ->
    ?assertEqual(undefined, whereis(ecai_eval_srv)),
    ?assertEqual(undefined, whereis(ecai_eval_worker_sup)),
    {ok, _} = application:ensure_all_started(crypto),
    Fields = ecai_eval_policy:node_fields(),
    Previous = [{maps:get(key,F), application:get_env(ecai,maps:get(key,F))} || F <- Fields],
    lists:foreach(fun(F) -> application:set_env(ecai,maps:get(key,F),maps:get(default,F)) end, Fields),
    application:set_env(ecai,eval_target_ids,[<<"fixture">>]),
    ok = meck:new(ecai_eval_provider, [no_link]),
    Target = #{<<"id">> => <<"fixture">>, <<"remote">> => false,
        <<"model">> => <<"fixture">>, <<"configuration_sha256">> => <<"fixture">>},
    ok = meck:expect(ecai_eval_provider,catalog,fun() -> {ok,[{Target,#{}}]} end),
    ok = meck:expect(ecai_eval_provider,resolve,fun(<<"fixture">>) -> {ok,Target,#{}} end),
    Calls = atomics:new(1, []),
    ok = meck:expect(ecai_eval_provider,call,fun(_,_,_,_) -> atomics:add_get(Calls,1,1), {ok,<<"ok">>,#{}} end),
    Dir = filename:join("/tmp", "ecai-eval-test-" ++ binary_to_list(ecai_eval_util:id())),
    Path = filename:join(Dir,"ledger.dets"),
    {ok, W} = ecai_eval_worker_sup:start_link(), unlink(W),
    {ok, P} = ecai_eval_srv:start_link(#{path => Path}), unlink(P),
    #{path => Path, dir => Dir, previous => Previous, calls => Calls}.
cleanup(C) ->
    application:set_env(ecai,eval_enabled,false),
    stop(ecai_eval_srv), stop(ecai_eval_worker_sup),
    ok = meck:unload(ecai_eval_provider),
    lists:foreach(fun({K, undefined}) -> application:unset_env(ecai,K);
                     ({K, {ok,V}}) -> application:set_env(ecai,K,V) end, maps:get(previous,C)),
    ok = file:del_dir_r(maps:get(dir,C)).
stop(Name) -> case whereis(Name) of undefined -> ok; P -> gen_server:stop(P) end.
request(Op, Owner, B) -> ecai_eval_srv:request(Op,Owner,B).
source() -> #{<<"name">> => <<"Fixture">>, <<"version">> => <<"1">>,
    <<"description">> => <<"Synthetic unit test">>, <<"annotation_guidelines">> => <<"Check exact ok">>,
    <<"references">> => [], <<"reviewers">> => [], <<"cases">> => [fixture_case(<<"case-a">>)]}.
fixture_case(Id) -> #{<<"id">> => Id, <<"group">> => Id, <<"domain">> => <<"general">>,
    <<"dimension">> => <<"contract">>, <<"split">> => <<"test">>,
    <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Id}],
    <<"checks">> => [#{<<"id">> => <<"ok">>, <<"type">> => <<"exact">>,
        <<"description">> => <<"Expected fixture response">>, <<"expected">> => <<"ok">>}]}.
import(Source) ->
    {ok,S} = request(import_suite,<<"alice">>,Source), maps:get(<<"id">>,S).
approve(Id) -> {ok,_} = request(approve_suite,<<"alice">>,#{<<"id">> => Id, <<"note">> => <<"Reviewed fixture">>}), ok.
prefs(Daily) ->
    {ok,S} = request(settings,<<"alice">>,#{}),
    {ok,_} = request(save_settings,<<"alice">>,#{<<"version">> => maps:get(<<"version">>,S),
        <<"changes">> => #{<<"enabled">> => true, <<"target_ids">> => [<<"fixture">>], <<"daily_calls">> => Daily}}), ok.
body(Id, Key) -> #{<<"suite_id">> => Id, <<"split">> => <<"test">>, <<"idempotency_key">> => Key}.
run_view(Id) -> {ok,V} = request(run,<<"alice">>,#{<<"id">> => Id}), V.
wait(F) -> wait(F, erlang:monotonic_time(millisecond)+4000).
wait(F, Until) ->
    case F() of true -> ok; false ->
        ?assert(erlang:monotonic_time(millisecond)<Until), timer:sleep(20), wait(F,Until) end.
restart(C) ->
    stop(ecai_eval_srv),
    {ok,P} = ecai_eval_srv:start_link(#{path => maps:get(path,C)}), unlink(P), ok.
tenant_isolation(_) ->
    Id = import(source()),
    ?assertEqual({error,not_found}, request(suite,<<"bob">>,#{<<"id">> => Id})),
    ?assertEqual({ok,[]}, request(suites,<<"bob">>,#{})),
    ?assertEqual({error,not_found},request(approve_suite,<<"bob">>,#{<<"id">> => Id,<<"owner">> => <<"alice">>,<<"note">> => <<"Forged">>})).
settings_cas(_) ->
    prefs(10),
    ?assertEqual({error,version_conflict},request(save_settings,<<"alice">>,#{<<"version">> => 0,<<"changes">> => #{}})),
    {ok,B} = request(settings,<<"bob">>,#{}),
    ?assertEqual(false,maps:get(<<"enabled">>,maps:get(<<"preferences">>,B))),
    ?assertEqual({error,unexpected_fields},request(save_settings,<<"alice">>,#{<<"version">> => 1,<<"changes">> => #{<<"eval_allow_remote">> => true}})).
review_required(_) ->
    Id=import(source()), prefs(10), application:set_env(ecai,eval_enabled,true),
    ?assertEqual({error,suite_review_required},request(submit,<<"alice">>,body(Id,<<"needs-review">>))).
idempotency(_) ->
    Id=import(source()), approve(Id), prefs(10), application:set_env(ecai,eval_enabled,true),
    B=body(Id,<<"same-key">>), {ok,A}=request(submit,<<"alice">>,B), {ok,D}=request(submit,<<"alice">>,B),
    ?assertEqual(maps:get(<<"id">>,A),maps:get(<<"id">>,D)),
    ?assertEqual({error,idempotency_conflict},request(submit,<<"alice">>,B#{<<"split">> => <<"dev">>})),
    ?assertEqual({error,not_found},request(run,<<"bob">>,#{<<"id">> => maps:get(<<"id">>,A)})).
restart_does_not_retry(C) ->
    Calls=maps:get(calls,C),
    ok=meck:expect(ecai_eval_provider,call,fun(_,_,_,_) -> atomics:add_get(Calls,1,1), receive fixture_release -> {ok,<<"ok">>,#{}} end end),
    Id=import(source()), approve(Id), prefs(10), application:set_env(ecai,eval_enabled,true),
    {ok,R}=request(submit,<<"alice">>,body(Id,<<"restart">>)), RunId=maps:get(<<"id">>,R),
    wait(fun() -> maps:get(<<"inflight">>,maps:get(<<"counts">>,maps:get(<<"report">>,run_view(RunId))),0)=:=1 end),
    wait(fun() -> atomics:get(Calls,1)=:=1 end),
    restart(C),
    Report=maps:get(<<"report">>,run_view(RunId)),
    ?assertEqual(1,maps:get(<<"uncertain">>,maps:get(<<"counts">>,Report))),
    ?assertEqual(false,maps:get(<<"release_gate">>,Report)),
    timer:sleep(350), ?assertEqual(1,atomics:get(maps:get(calls,C),1)),
    {ok,Settings}=request(settings,<<"alice">>,#{}),?assertEqual(1,maps:get(<<"daily_reserved_calls">>,Settings)).
quota_survives_restart(C) ->
    Id=import((source())#{<<"cases">> => [fixture_case(<<"a">>),fixture_case(<<"b">>)]}),
    approve(Id), prefs(1), application:set_env(ecai,eval_enabled,true),
    {ok,R}=request(submit,<<"alice">>,body(Id,<<"quota">>)), RunId=maps:get(<<"id">>,R),
    wait(fun() -> maps:get(<<"pass">>,maps:get(<<"counts">>,maps:get(<<"report">>,run_view(RunId))),0)=:=1 end),
    restart(C),timer:sleep(350),
    ?assertEqual(1,atomics:get(maps:get(calls,C),1)),
    {ok,Settings}=request(settings,<<"alice">>,#{}),?assertEqual(1,maps:get(<<"daily_reserved_calls">>,Settings)),
    ?assertEqual(false,maps:get(<<"release_gate">>,maps:get(<<"report">>,run_view(RunId)))).
