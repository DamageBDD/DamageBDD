%% Versioned executable checks. Citation presence is NOT semantic entailment.
-module(ecai_eval_grader).
-export([grade/3, verdict/3, version/0]).
version() -> <<"ecai-eval-grader/v1">>.

grade(Case, Text, Suite) when is_binary(Text) ->
    Parsed = try {ok, ecai_eval_util:decode(Text)} catch _:_ -> invalid_json end,
    Checks = [check(C, Text, Parsed, Case, Suite) || C <- maps:get(<<"checks">>, Case)],
    Failed = [C || C <- Checks, maps:get(<<"status">>, C) =/= <<"pass">>],
    #{<<"version">> => version(), <<"checks">> => Checks,
      <<"status">> => case Failed of [] -> <<"pass">>; _ -> <<"fail">> end,
      <<"critical_failures">> => length([C || C <- Failed, maps:get(<<"critical">>, C)]),
      <<"human_required">> => maps:get(<<"rubric">>, Case) =/= null,
      <<"human_critical">> => case maps:get(<<"rubric">>, Case) of null -> false; Rubric -> maps:get(<<"critical">>, Rubric, false) end}.

check(C, Text, Parsed, Case, Suite) ->
    Base = maps:with([<<"id">>, <<"type">>, <<"critical">>, <<"description">>], C),
    try execute(maps:get(<<"type">>, C), C, Text, Parsed, Case, Suite) of
        true -> Base#{<<"status">> => <<"pass">>, <<"reason">> => <<"matched">>};
        false -> Base#{<<"status">> => <<"fail">>, <<"reason">> => <<"assertion_mismatch">>};
        M when is_map(M) -> maps:merge(Base, M)
    catch
        throw:{eval_error, Why} -> Base#{<<"status">> => <<"fail">>, <<"reason">> => ecai_eval_util:bin(Why)};
        error:{badkey, _} -> Base#{<<"status">> => <<"fail">>, <<"reason">> => <<"missing_field">>}
    end.
execute(<<"exact">>, C, T, _, _, _) -> T =:= maps:get(<<"expected">>, C);
execute(<<"contains">>, C, T, _, _, _) -> binary:match(T, maps:get(<<"expected">>, C)) =/= nomatch;
execute(<<"not_contains">>, C, T, _, _, _) -> binary:match(T, maps:get(<<"expected">>, C)) =:= nomatch;
execute(<<"json_equal">>, C, _, P, _, _) -> value(C, P) =:= maps:get(<<"expected">>, C);
execute(<<"json_range">>, C, _, P, _, _) ->
    V = value(C, P), is_number(V) andalso V >= maps:get(<<"min">>, C) andalso V =< maps:get(<<"max">>, C);
execute(<<"json_keys">>, C, _, P, _, _) ->
    V = value(C, P), is_map(V) andalso lists:all(fun(K) -> maps:is_key(K, V) end, maps:get(<<"required">>, C));
execute(<<"citation_ids">>, C, _, P, _, S) ->
    V = value(C, P), Required = maps:get(<<"required">>, C),
    Allowed = [maps:get(<<"id">>, R) || R <- maps:get(<<"references">>, S)],
    is_list(V) andalso lists:all(fun(I) -> lists:member(I, Allowed) end, V) andalso
        lists:all(fun(I) -> lists:member(I, V) end, Required);
execute(<<"tool_allowlist">>, C, _, P, _, _) ->
    V = value(C, P), Allowed = maps:get(<<"allowed">>, C),
    is_list(V) andalso lists:all(fun(T) -> is_map(T) andalso
        lists:member(maps:get(<<"name">>, T, undefined), Allowed) end, V);
execute(<<"paper_trade">>, _, _, {ok, P}, Case, _) when is_map(P) ->
    ecai_eval_trade:grade(maps:get(<<"market">>, Case), P);
execute(<<"paper_trade">>, _, _, _, _, _) -> throw({eval_error, invalid_json}).
value(C, {ok, V}) -> path(maps:get(<<"path">>, C), V);
value(_, _) -> throw({eval_error, invalid_json}).
path([], V) -> V;
path([K | Ks], M) when is_map(M) -> path(Ks, maps:get(K, M));
path(_, _) -> throw({eval_error, invalid_path}).

%% Votes are keyed by authenticated reviewer identity, not a caller-supplied name.
%% Human approval cannot waive deterministic failures or infrastructure errors.
verdict(#{<<"state">> := <<"done">>, <<"grade">> := G} = A, MinReviewers, Authorized) ->
    case {maps:get(<<"status">>, G), maps:get(<<"human_required">>, G)} of
        {<<"fail">>, _} -> <<"fail">>;
        {<<"pass">>, false} -> <<"pass">>;
        {<<"pass">>, true} ->
            Votes = [maps:get(<<"verdict">>, V) || {Who, V} <- maps:to_list(maps:get(<<"reviews">>, A, #{})),
                      lists:member(Who, Authorized)],
            case {length(Votes) >= MinReviewers, lists:usort(Votes)} of
                {true, [<<"pass">>]} -> <<"pass">>;
                {true, [<<"fail">>]} -> <<"fail">>;
                _ -> <<"indeterminate">>
            end
    end;
verdict(A, _, _) -> maps:get(<<"state">>, A, <<"pending">>).
