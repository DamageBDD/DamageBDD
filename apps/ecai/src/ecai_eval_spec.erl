%% Strict, bounded suite import; dataset approval is a separate authenticated act.
-module(ecai_eval_spec).
-export([normalize/1, case_by_id/2, selected/2, coverage/1]).

normalize(S) ->
    ecai_eval_util:keys(S, [<<"name">>, <<"version">>, <<"description">>, <<"annotation_guidelines">>,
                           <<"reviewers">>, <<"references">>, <<"cases">>]),
    Name = ecai_eval_util:text(maps:get(<<"name">>, S), 256),
    Version = ecai_eval_util:text(maps:get(<<"version">>, S), 128),
    Description = ecai_eval_util:text(maps:get(<<"description">>, S), 2048),
    Guidelines = ecai_eval_util:text(maps:get(<<"annotation_guidelines">>, S), 8192),
    Reviewers = maps:get(<<"reviewers">>, S, []),
    ecai_eval_util:require(is_list(Reviewers) andalso length(Reviewers) =< 16, invalid_reviewers),
    lists:foreach(fun(X) -> ecai_eval_util:text(X, 128) end, Reviewers),
    ecai_eval_util:require(length(Reviewers) =:= length(lists:usort(Reviewers)), duplicate_reviewer),
    References = ecai_eval_knowledge:normalize(maps:get(<<"references">>, S, [])),
    Cases0 = maps:get(<<"cases">>, S),
    ecai_eval_util:require(is_list(Cases0) andalso Cases0 =/= [] andalso
        length(Cases0) =< maps:get(<<"max_cases">>, ecai_eval_policy:node()), invalid_cases),
    Cases = [normalize_case(C, References) || C <- Cases0],
    Ids = [maps:get(<<"id">>, C) || C <- Cases],
    ecai_eval_util:require(length(Ids) =:= length(lists:usort(Ids)), duplicate_case),
    leakage(Cases),
    temporal_splits(Cases),
    #{<<"schema">> => <<"ecai-eval-suite/v1">>, <<"name">> => Name, <<"version">> => Version,
      <<"description">> => Description, <<"annotation_guidelines">> => Guidelines,
      <<"reviewers">> => Reviewers, <<"references">> => References, <<"cases">> => Cases,
      <<"knowledge_sha256">> => ecai_eval_util:hash(References)}.
normalize_case(C, Refs) ->
    ecai_eval_util:keys(C, [<<"id">>, <<"group">>, <<"domain">>, <<"dimension">>, <<"split">>,
         <<"messages">>, <<"query">>, <<"checks">>, <<"evidence_ids">>, <<"rubric">>, <<"market">>]),
    Id = ecai_eval_util:text(maps:get(<<"id">>, C), 128),
    Group = ecai_eval_util:text(maps:get(<<"group">>, C), 128),
    Domain = ecai_eval_util:enum(maps:get(<<"domain">>, C), [<<"dialogue">>, <<"trading">>, <<"general">>]),
    Dim = ecai_eval_util:text(maps:get(<<"dimension">>, C), 128),
    Split = ecai_eval_util:enum(maps:get(<<"split">>, C), [<<"dev">>, <<"test">>, <<"holdout">>]),
    Messages = maps:get(<<"messages">>, C),
    ecai_eval_util:require(is_list(Messages) andalso Messages =/= [] andalso length(Messages) =< 32,
                           invalid_messages),
    lists:foreach(fun message/1, Messages),
    ecai_eval_util:require(maps:get(<<"role">>, lists:last(Messages)) =:= <<"user">>, last_message_must_be_user),
    ecai_eval_util:require(byte_size(ecai_eval_util:json(Messages)) =< 262144, messages_too_large),
    Query = ecai_eval_util:text(maps:get(<<"query">>, C, maps:get(<<"content">>, lists:last(Messages))), 32768),
    RefIds = [maps:get(<<"id">>, R) || R <- Refs],
    Evidence = maps:get(<<"evidence_ids">>, C, []),
    ecai_eval_util:require(is_list(Evidence) andalso length(Evidence) =< 64, invalid_evidence_ids),
    lists:foreach(fun(I) -> ecai_eval_util:require(lists:member(I, RefIds), unknown_reference) end, Evidence),
    ecai_eval_util:require(length(Evidence) =:= length(lists:usort(Evidence)), duplicate_evidence),
    Checks = maps:get(<<"checks">>, C, []),
    ecai_eval_util:require(is_list(Checks) andalso length(Checks) =< 32, invalid_checks),
    Checked = [check(X, RefIds) || X <- Checks],
    CheckIds = [maps:get(<<"id">>, X) || X <- Checked],
    ecai_eval_util:require(length(CheckIds) =:= length(lists:usort(CheckIds)), duplicate_check),
    Rubric = rubric(maps:get(<<"rubric">>, C, null)),
    ecai_eval_util:require(Checked =/= [] orelse Rubric =/= null, empty_grading_contract),
    Base = #{<<"id">> => Id, <<"group">> => Group, <<"domain">> => Domain,
        <<"dimension">> => Dim, <<"split">> => Split, <<"messages">> => Messages,
        <<"query">> => Query, <<"checks">> => Checked, <<"evidence_ids">> => Evidence, <<"rubric">> => Rubric},
    case Domain of
        <<"trading">> ->
            ecai_eval_util:require(lists:any(fun(X) -> maps:get(<<"type">>, X) =:= <<"paper_trade">> end, Checked),
                                   paper_trade_check_required),
            Base#{<<"market">> => ecai_eval_trade:validate(maps:get(<<"market">>, C))};
        _ ->
            ecai_eval_util:require(not maps:is_key(<<"market">>, C), unexpected_market),
            ecai_eval_util:require(not lists:any(fun(X) -> maps:get(<<"type">>, X) =:= <<"paper_trade">> end, Checked),
                                   trading_domain_required), Base
    end.
message(M) ->
    ecai_eval_util:keys(M, [<<"role">>, <<"content">>]),
    ecai_eval_util:enum(maps:get(<<"role">>, M), [<<"system">>, <<"user">>, <<"assistant">>]),
    ecai_eval_util:text(maps:get(<<"content">>, M), 32768).
check(X, RefIds) ->
    Type = maps:get(<<"type">>, X),
    Common = [<<"id">>, <<"type">>, <<"critical">>, <<"description">>],
    Extra = case Type of
        <<"exact">> -> [<<"expected">>];
        <<"contains">> -> [<<"expected">>];
        <<"not_contains">> -> [<<"expected">>];
        <<"json_equal">> -> [<<"path">>, <<"expected">>];
        <<"json_range">> -> [<<"path">>, <<"min">>, <<"max">>];
        <<"json_keys">> -> [<<"path">>, <<"required">>];
        <<"citation_ids">> -> [<<"path">>, <<"required">>];
        <<"tool_allowlist">> -> [<<"path">>, <<"allowed">>];
        <<"paper_trade">> -> [];
        _ -> throw({eval_error, unknown_check})
    end,
    ecai_eval_util:keys(X, Common ++ Extra),
    Id = ecai_eval_util:text(maps:get(<<"id">>, X), 128),
    Critical = maps:get(<<"critical">>, X, false),
    ecai_eval_util:require(is_boolean(Critical), invalid_boolean),
    Description = ecai_eval_util:text(maps:get(<<"description">>, X), 2048),
    lists:foreach(fun(K) -> ecai_eval_util:require(maps:is_key(K, X), missing_check_field) end, Extra),
    case maps:find(<<"path">>, X) of
        {ok, Path} -> ecai_eval_util:require(is_list(Path) andalso length(Path) =< 16, invalid_path),
                      lists:foreach(fun(P) -> ecai_eval_util:text(P, 128) end, Path);
        error -> ok
    end,
    case Type of
        <<"json_range">> ->
            Min = maps:get(<<"min">>, X), Max = maps:get(<<"max">>, X),
            ecai_eval_util:require(is_number(Min) andalso is_number(Max) andalso Min =< Max, invalid_range);
        <<"exact">> -> ecai_eval_util:text(maps:get(<<"expected">>, X), 32768);
        <<"contains">> -> ecai_eval_util:text(maps:get(<<"expected">>, X), 32768);
        <<"not_contains">> -> ecai_eval_util:text(maps:get(<<"expected">>, X), 32768);
        <<"json_equal">> ->
            ecai_eval_util:require(byte_size(ecai_eval_util:json(maps:get(<<"expected">>, X))) =< 32768,
                                   expected_too_large);
        <<"json_keys">> -> strings(maps:get(<<"required">>, X));
        <<"tool_allowlist">> -> strings(maps:get(<<"allowed">>, X));
        <<"citation_ids">> ->
            R = maps:get(<<"required">>, X), strings(R),
            lists:foreach(fun(I) -> ecai_eval_util:require(lists:member(I, RefIds), unknown_reference) end, R);
        _ -> ok
    end,
    X#{<<"id">> => Id, <<"critical">> => Critical, <<"description">> => Description}.
strings(L) ->
    ecai_eval_util:require(is_list(L) andalso length(L) =< 64, invalid_string_list),
    lists:foreach(fun(X) -> ecai_eval_util:text(X, 128) end, L).
rubric(null) -> null;
rubric(R) ->
    Ks = [<<"instruction">>, <<"pass_anchor">>, <<"fail_anchor">>, <<"indeterminate_anchor">>],
    ecai_eval_util:keys(R, [<<"critical">> | Ks]),
    Critical = maps:get(<<"critical">>, R, false),
    ecai_eval_util:require(is_boolean(Critical), invalid_boolean),
    lists:foreach(fun(K) -> ecai_eval_util:text(maps:get(K, R), 4096) end, Ks), R#{<<"critical">> => Critical}.
leakage(Cases) ->
    _ = lists:foldl(fun(C, Seen) ->
        Split = maps:get(<<"split">>, C),
        Keys = [{group, maps:get(<<"group">>, C)}, {prompt, ecai_eval_util:hash(maps:get(<<"messages">>, C))}],
        lists:foldl(fun(K, Acc) ->
            case maps:find(K, Acc) of
                error -> Acc#{K => Split};
                {ok, Split} -> Acc;
                {ok, _} -> throw({eval_error, cross_split_leakage})
            end
        end, Seen, Keys)
    end, #{}, Cases), ok.
case_by_id(Suite, Id) ->
    case [C || C <- maps:get(<<"cases">>, Suite), maps:get(<<"id">>, C) =:= Id] of
        [C] -> C;
        [] -> throw({eval_error, case_not_found})
    end.
selected(Suite, Split) -> [C || C <- maps:get(<<"cases">>, Suite), maps:get(<<"split">>, C) =:= Split].
coverage(Suite) ->
    lists:foldl(fun(C, Acc) ->
        Key = iolist_to_binary(lists:join(<<" / ">>, [maps:get(K, C) ||
                      K <- [<<"domain">>, <<"dimension">>, <<"split">>]])),
        Acc#{Key => maps:get(Key, Acc, 0) + 1}
    end, #{}, maps:get(<<"cases">>, Suite)).

%% Chronological separation of trading labels: earlier-split outcomes may not
%% extend to or beyond a later split's decision time for the same symbol.
temporal_splits(Cases) ->
    Trades = [C || C <- Cases, maps:get(<<"domain">>, C) =:= <<"trading">>],
    lists:foreach(fun(A) -> lists:foreach(fun(B) ->
        MA = maps:get(<<"market">>, A), MB = maps:get(<<"market">>, B),
        Earlier = rank(maps:get(<<"split">>, A)) < rank(maps:get(<<"split">>, B)),
        Same = maps:get(<<"symbol">>, MA) =:= maps:get(<<"symbol">>, MB),
        case Earlier andalso Same of
            true -> Last = maps:get(<<"time_ms">>, lists:last(maps:get(<<"tape">>, MA))),
                    ecai_eval_util:require(Last < maps:get(<<"as_of_ms">>, MB), overlapping_trading_splits);
            false -> ok
        end
    end, Trades) end, Trades).
rank(<<"dev">>) -> 0;
rank(<<"test">>) -> 1;
rank(<<"holdout">>) -> 2.
