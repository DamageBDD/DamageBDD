%% Node policy is authoritative; account preferences can only narrow it.
-module(ecai_eval_policy).
-compile({no_auto_import, [node/0]}).
-export([node/0, defaults/0, validate/2, effective/1, allowed/2, node_fields/0]).

node() ->
    Ds = definitions(),
    Values = [{Name, application:get_env(ecai, Key, Default), Type, Min, Max} ||
        {Name, Key, Default, Type, Min, Max} <- Ds],
    Valid = lists:all(fun({_, V, Ty, Lo, Hi}) -> valid(V, Ty, Lo, Hi) end, Values),
    Base = case Valid of
        true -> maps:from_list([{Name, V} || {Name, V, _, _, _} <- Values]);
        false -> (maps:from_list([{Name, Default} || {Name, _, Default, _, _, _} <- Ds]))#{<<"enabled">> => false, <<"target_ids">> => []}
    end,
    Base#{<<"configuration_valid">> => Valid,
          <<"target_ids">> => [ecai_eval_util:bin(I) || I <- maps:get(<<"target_ids">>, Base)]}.
valid(V, boolean, _, _) -> is_boolean(V);
valid(V, integer, Lo, Hi) -> is_integer(V) andalso V >= Lo andalso V =< Hi;
valid(V, string_list, _, _) when is_list(V), length(V) =< 64 ->
    lists:all(fun(I) -> try B = ecai_eval_util:bin(I), is_binary(B) andalso byte_size(B)>0 andalso byte_size(B)=<128 catch _:_ -> false end end, V);
valid(_, _, _, _) -> false.

%% Shared schema metadata consumed by DamageBDD's existing versioned settings UI.
node_fields() ->
    [field(Name, Key, Default, Type, Min, Max) ||
        {Name, Key, Default, Type, Min, Max} <- definitions()].
field(Name, Key, Default, Type, Min, Max) ->
    Base = #{key => Key, label => label(Name), type => Type, default => Default,
             apply => hot, group => <<"evaluation">>},
    case Type of integer -> Base#{min => Min, max => Max}; _ -> Base end.
label(Name) -> binary:replace(Name, <<"_">>, <<" ">>, [global]).
definitions() ->
    [{<<"enabled">>, eval_enabled, false, boolean, 0, 0},
     {<<"allow_remote">>, eval_allow_remote, false, boolean, 0, 0},
     {<<"target_ids">>, eval_target_ids, [], string_list, 0, 0},
     {<<"max_parallel">>, eval_max_parallel, 2, integer, 1, 32},
     {<<"max_parallel_per_account">>, eval_max_parallel_per_account, 1, integer, 1, 8},
     {<<"max_queued_runs">>, eval_max_queued_runs, 64, integer, 1, 1000},
     {<<"max_account_runs">>, eval_max_account_runs, 100, integer, 1, 10000},
     {<<"max_account_suites">>, eval_max_account_suites, 50, integer, 1, 1000},
     {<<"max_cases">>, eval_max_cases, 100, integer, 1, 1000},
     {<<"max_repetitions">>, eval_max_repetitions, 5, integer, 1, 20},
     {<<"max_run_calls">>, eval_max_run_calls, 500, integer, 1, 10000},
     {<<"daily_calls">>, eval_daily_calls, 1000, integer, 1, 100000},
     {<<"node_daily_calls">>, eval_node_daily_calls, 10000, integer, 1, 1000000},
     {<<"max_output_tokens">>, eval_max_output_tokens, 2048, integer, 16, 32768},
     {<<"max_prompt_bytes">>, eval_max_prompt_bytes, 32768, integer, 1024, 262144},
     {<<"max_response_bytes">>, eval_max_response_bytes, 131072, integer, 1024, 1048576},
     {<<"timeout_ms">>, eval_timeout_ms, 120000, integer, 1000, 900000},
     {<<"min_pass_bps">>, eval_min_pass_bps, 9500, integer, 0, 10000},
     {<<"min_reviewers">>, eval_min_reviewers, 1, integer, 1, 3},
     {<<"retention_days">>, eval_retention_days, 30, integer, 2, 3650}].

defaults() ->
    N = node(),
    #{<<"enabled">> => false, <<"remote_consent">> => false,
      <<"target_ids">> => [], <<"repetitions">> => 1,
      <<"max_output_tokens">> => min(1024, maps:get(<<"max_output_tokens">>, N)),
      <<"daily_calls">> => min(100, maps:get(<<"daily_calls">>, N)),
      <<"pass_bps">> => maps:get(<<"min_pass_bps">>, N),
      <<"knowledge_mode">> => <<"none">>, <<"retrieval_k">> => 4}.

validate(Changes, Existing) ->
    ecai_eval_util:keys(Changes, maps:keys(defaults())),
    P = maps:merge(Existing, Changes), N = node(),
    lists:foreach(fun(K) -> ecai_eval_util:require(is_boolean(maps:get(K, P)), invalid_boolean) end,
                  [<<"enabled">>, <<"remote_consent">>]),
    Ids = maps:get(<<"target_ids">>, P),
    ecai_eval_util:require(is_list(Ids) andalso length(Ids) =< 8, invalid_targets),
    Allowed = [ecai_eval_util:bin(I) || I <- maps:get(<<"target_ids">>, N)],
    lists:foreach(fun(I) -> ecai_eval_util:text(I, 128),
        ecai_eval_util:require(lists:member(I, Allowed), target_not_allowed) end, Ids),
    ecai_eval_util:require(length(Ids) =:= length(lists:usort(Ids)), duplicate_target),
    ecai_eval_util:integer(maps:get(<<"repetitions">>, P), 1, maps:get(<<"max_repetitions">>, N)),
    ecai_eval_util:integer(maps:get(<<"daily_calls">>, P), 1, maps:get(<<"daily_calls">>, N)),
    ecai_eval_util:integer(maps:get(<<"max_output_tokens">>, P), 16, maps:get(<<"max_output_tokens">>, N)),
    ecai_eval_util:integer(maps:get(<<"pass_bps">>, P), maps:get(<<"min_pass_bps">>, N), 10000),
    ecai_eval_util:enum(maps:get(<<"knowledge_mode">>, P), [<<"none">>, <<"ecai">>]),
    ecai_eval_util:integer(maps:get(<<"retrieval_k">>, P), 1, 20), P.

effective(P) ->
    N = node(),
    Ids = [ecai_eval_util:bin(I) || I <- maps:get(<<"target_ids">>, N)],
    P#{<<"enabled">> => maps:get(<<"enabled">>, P) andalso maps:get(<<"enabled">>, N),
       <<"remote_consent">> => maps:get(<<"remote_consent">>, P) andalso maps:get(<<"allow_remote">>, N),
       <<"target_ids">> => [I || I <- maps:get(<<"target_ids">>, P), lists:member(I, Ids)],
       <<"repetitions">> => min(maps:get(<<"repetitions">>, P), maps:get(<<"max_repetitions">>, N)),
       <<"max_output_tokens">> => min(maps:get(<<"max_output_tokens">>, P), maps:get(<<"max_output_tokens">>, N)),
       <<"daily_calls">> => min(maps:get(<<"daily_calls">>, P), maps:get(<<"daily_calls">>, N)),
       <<"pass_bps">> => max(maps:get(<<"pass_bps">>, P), maps:get(<<"min_pass_bps">>, N))}.
allowed(Target, P) ->
    maps:get(<<"enabled">>, P) andalso
    lists:member(maps:get(<<"id">>, Target), maps:get(<<"target_ids">>, P)) andalso
    (maps:get(<<"remote">>, Target) =:= false orelse maps:get(<<"remote_consent">>, P)).
