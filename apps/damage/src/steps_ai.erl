%% SPDX-License-Identifier: Apache-2.0
%% AI task steps: explicit input -> versioned skill -> validated typed result.
%% Unknown steps deliberately have NO catch-all clause: preserve runner discovery.
-module(steps_ai).
-export([step/6, step_dry/6, result/2]).
-import(damage_ai, [text/1, require/2]).

-spec step_dry(list(), map(), term(), integer(), list(), term()) -> map().
step_dry(Config, Context, Keyword, N, Parts, Body) ->
    step([{ai_dry_run, true} | Config], Context, Keyword, N, Parts, Body).

-spec step(list(), map(), term(), integer(), list(), term()) -> map() | string().
step(Config, Context, Keyword, _N, ["I use AI profile", Name], _Body) ->
    dispatch(Config, Context, Keyword, select_profile, [Name]);
step(Config, Context, Keyword, _N, ["I set the AI input to"], Body) ->
    dispatch(Config, Context, Keyword, set_input, [Body]);
step(Config, Context, Keyword, _N, ["I use variable", Name, "as AI input"], _Body) ->
    dispatch(Config, Context, Keyword, variable_input, [Name]);
step(Config, Context, Keyword, _N, ["I use the HTTP response body as AI input"], _Body) ->
    dispatch(Config, Context, Keyword, response_input, []);
step(Config, Context, Keyword, _N, ["I set the AI instruction to"], Body) ->
    dispatch(Config, Context, Keyword, instruction, [Body]);
step(Config, Context, Keyword, _N, ["I set the AI labels to"], Body) ->
    dispatch(Config, Context, Keyword, labels, [Body]);
step(Config, Context, Keyword, _N, ["I set the AI fields to"], Body) ->
    dispatch(Config, Context, Keyword, fields, [Body]);
step(Config, Context, Keyword, _N, ["I set the AI language to", Language], _Body) ->
    dispatch(Config, Context, Keyword, language, [Language]);
step(Config, Context, Keyword, _N, ["I set the AI question to", Question], _Body) ->
    dispatch(Config, Context, Keyword, question, [Question]);
step(Config, Context, Keyword, _N, ["I run AI skill", Skill, "and store result in", Name], _Body) ->
    dispatch(Config, Context, Keyword, run, [Skill, Name]);
step(Config, Context, Keyword, _N, ["I summarize the AI input and store result in", Name], _Body) ->
    dispatch(Config, Context, Keyword, run, ["summarize", Name]);
step(Config, Context, Keyword, _N, ["I classify the AI input and store result in", Name], _Body) ->
    dispatch(Config, Context, Keyword, run, ["classify", Name]);
step(Config, Context, Keyword, _N, ["I extract fields from the AI input and store result in", Name], _Body) ->
    dispatch(Config, Context, Keyword, run, ["extract", Name]);
step(Config, Context, Keyword, _N, ["I translate the AI input and store result in", Name], _Body) ->
    dispatch(Config, Context, Keyword, run, ["translate", Name]);
step(Config, Context, Keyword, _N, ["I embed the AI input and store result in", Name], _Body) ->
    dispatch(Config, Context, Keyword, run, ["embed", Name]);
step(Config, Context, Keyword, _N, ["the AI result should equal", Expected], _Body) ->
    dispatch(Config, Context, Keyword, equals, [Expected]);
step(Config, Context, Keyword, _N, ["the AI result should contain", Expected], _Body) ->
    dispatch(Config, Context, Keyword, contains, [Expected]);
step(Config, Context, Keyword, _N, ["the AI result should be valid JSON"], _Body) ->
    dispatch(Config, Context, Keyword, valid_json, []);
step(Config, Context, Keyword, _N, ["the AI result at pointer", Pointer, "should equal JSON"], Body) ->
    dispatch(Config, Context, Keyword, json_equals, [Pointer, Body]);
step(Config, Context, Keyword, _N, ["the AI request should finish within", Ms, "milliseconds"], _Body) ->
    dispatch(Config, Context, Keyword, latency, [Ms]);
step(Config, Context, Keyword, _N, ["the AI token usage should not exceed", Tokens], _Body) ->
    dispatch(Config, Context, Keyword, tokens, [Tokens]);
step(Config, Context, Keyword, _N, ["the AI embedding should have", Dimensions, "dimensions"], _Body) ->
    dispatch(Config, Context, Keyword, dimensions, [Dimensions]);
step(Config, Context, Keyword, _N, ["AI embeddings in", Left, "and", Right, "should have cosine similarity at least", Minimum], _Body) ->
    dispatch(Config, Context, Keyword, similarity, [Left, Right, Minimum]).

%% This is reached only after a concrete step pattern matched.
dispatch(_Config, _Context, documentation, Action, _Args) ->
    lists:flatten(io_lib:format("AI skill step: ~p (explicit inputs, no tool execution)", [Action]));
dispatch(Config, Context, _Keyword, Action, Args) ->
    case maps:is_key(fail, Context) of
        true -> Context;
        false ->
            Outcome = damage_ai:safe(fun() ->
                case proplists:get_value(dry_run, Config, false) =:= true orelse
                     proplists:get_value(ai_dry_run, Config, false) =:= true of
                    true -> dry_action(Action, Args, Context);
                    false -> action(Action, Args, Context)
                end
            end),
            case Outcome of
                {ok, C} -> C;
                {error, Reason} -> failure(Context, Reason)
            end
    end.

%% Only recognition/placeholders: no profile lookup, secret reads, inference or
%% assertions. Placeholders permit subsequent {{ai_name}} template rendering.
dry_action(run, [_Skill, Name0], C) ->
    Name = output_name(Name0),
    maps:put(Name, <<"__damage_ai_dry_run__">>, C);
dry_action(_, _, C) -> C.

action(select_profile, [Name0], C) ->
    Name = text(Name0),
    _ = unwrap(damage_ai:profile(Name, C)),
    Old = state(C),
    %% Re-selection clears per-task inputs but never resets usage counters.
    put_state(C, #{profile => Name, params => #{},
                   calls => maps:get(calls, Old, #{}),
                   results => maps:get(results, Old, #{})});
action(set_input, [Body], C) ->
    set_input(C, text(Body));
action(variable_input, [Name], C) ->
    V = variable(C, Name),
    Input = case V of
        B when is_binary(B) -> B;
        L when is_list(L) ->
            case io_lib:printable_unicode_list(L) of
                true -> text(L);
                false -> jsx:encode(L)
            end;
        _ -> jsx:encode(V)
    end,
    set_input(C, Input);
action(response_input, [], C) ->
    case maps:get(response, C, undefined) of
        R when is_list(R) ->
            Body = proplists:get_value(body, R, undefined),
            set_input(C, text(Body));
        _ -> throw({ai_error, missing_http_response})
    end;
action(instruction, [Body], C) -> set_param(C, instruction, text(Body));
action(language, [Language], C) -> set_param(C, language, text(Language));
action(question, [Question], C) -> set_param(C, question, text(Question));
action(labels, [Body], C) ->
    Labels = damage_ai:json(Body),
    require(is_list(Labels), invalid_labels),
    set_param(C, labels, Labels);
action(fields, [Body], C) ->
    Fields = damage_ai:json(Body),
    require(is_map(Fields), invalid_fields),
    set_param(C, fields, Fields);
action(run, [Skill0, Name0], C) ->
    Name = output_name(Name0), Skill = text(Skill0),
    S = state(C), Profile = maps:get(profile, S, undefined),
    require(is_binary(Profile), missing_profile),
    %% Re-authorize every call, not only profile selection.
    P = unwrap(damage_ai:profile(Profile, C)),
    Calls = maps:get(calls, S, #{}), Count = maps:get(Profile, Calls, 0),
    require(is_integer(Count) andalso Count >= 0, invalid_call_count),
    require(Count < proplists:get_value(max_calls, P, 10), call_limit_exceeded),
    S1 = maps:remove(last, S#{calls => Calls#{Profile => Count + 1}}),
    Results0 = maps:remove(text(Name), maps:get(results, S1, #{})),
    C1 = maps:remove(Name, put_state(C, S1#{results => Results0})),
    %% A failed attempt consumes a slot and removes stale data at its destination.
    case damage_ai:run(P, Skill, maps:get(input, S, <<>>), maps:get(params, S, #{})) of
        {ok, Result} ->
            S2 = S1#{last => Result, results => Results0#{text(Name) => Result}},
            maps:put(Name, maps:get(value, Result), put_state(C1, S2));
        {error, Reason} -> failure(C1, Reason)
    end;
action(equals, [Expected], C) ->
    require(maps:get(value, last(C)) =:= text(Expected), result_mismatch), C;
action(contains, [Expected0], C) ->
    Value = maps:get(value, last(C)), Expected = text(Expected0),
    require(is_binary(Value) andalso byte_size(Expected) > 0, invalid_text_assertion),
    require(binary:match(Value, Expected) =/= nomatch, result_missing_text), C;
action(valid_json, [], C) ->
    _ = result_json(last(C)), C;
action(json_equals, [Pointer, Body], C) ->
    Value = damage_ai:pointer(result_json(last(C)), Pointer),
    Expected = damage_ai:json(Body),
    require(Value =:= Expected, json_result_mismatch), C;
action(latency, [Ms], C) ->
    Limit = integer(Ms), require(Limit >= 0, invalid_limit),
    require(maps:get(elapsed_ms, last(C)) =< Limit, latency_limit_exceeded), C;
action(tokens, [Tokens], C) ->
    Limit = integer(Tokens), require(Limit >= 0, invalid_limit),
    Usage = maps:get(usage, last(C), #{}),
    Total = maps:get(total_tokens, Usage, undefined),
    require(is_integer(Total) andalso Total >= 0, token_usage_unavailable),
    require(Total =< Limit, token_limit_exceeded), C;
action(dimensions, [Dimensions], C) ->
    R = last(C), require(maps:get(kind, R) =:= embedding, not_an_embedding),
    require(length(maps:get(value, R)) =:= integer(Dimensions), embedding_dimension_mismatch), C;
action(similarity, [Left, Right, Minimum], C) ->
    A = result(C, Left), B = result(C, Right),
    require(maps:get(kind, A) =:= embedding andalso maps:get(kind, B) =:= embedding,
            not_an_embedding),
    require(maps:get(model, A) =:= maps:get(model, B) andalso
            maps:get(profile, A) =:= maps:get(profile, B), embedding_model_mismatch),
    Threshold = number(Minimum),
    require(Threshold >= -1 andalso Threshold =< 1, invalid_similarity_threshold),
    Similarity = damage_ai:cosine(maps:get(value, A), maps:get(value, B)),
    require(Similarity >= Threshold, similarity_below_threshold), C.

set_input(C, Input) ->
    %% Coarse bound before profile-specific serialized request checks.
    require(byte_size(Input) =< 1048576, input_too_large),
    put_state(C, maps:remove(last, (state(C))#{input => Input})).
set_param(C, Key, Value) ->
    S = state(C), P = maps:get(params, S, #{}),
    put_state(C, maps:remove(last, S#{params => P#{Key => Value}})).
state(C) ->
    S = maps:get(ai, C, #{}), require(is_map(S), invalid_ai_state), S.
put_state(C, S) -> C#{ai => S}.
last(C) ->
    R = maps:get(last, state(C), undefined),
    require(is_map(R), no_ai_result), R.

%% Typed named result plus provenance; no need to deserialize output variables.
-spec result(map(), binary() | string()) -> map().
result(C, Name) ->
    R = maps:get(text(Name), maps:get(results, state(C), #{}), undefined),
    require(is_map(R), no_ai_result), R.
result_json(#{kind := json, value := V}) -> V;
result_json(#{kind := text, value := V}) -> damage_ai:json(V);
result_json(_) -> throw({ai_error, result_not_json}).

output_name(Name0) ->
    Name = text(Name0),
    %% Namespaced output avoids replacing runner/auth fields or interning atoms.
    require(re:run(Name, <<"^ai_[A-Za-z0-9_]{1,64}$">>, [{capture, none}]) =:= match,
            output_name_must_start_with_ai),
    binary_to_list(Name).
variable(C, Name0) ->
    Name = text(Name0),
    %% Credentials must not be used as inputs through this convenience step.
    require(not lists:member(string:lowercase(Name), [
        <<"access_token">>, <<"private_key">>, <<"password">>, <<"headers">>,
        <<"request_headers">>, <<"cookies">>, <<"account_context">>, <<"ai">>]),
        protected_input_variable),
    Keys = [binary_to_list(Name), Name] ++ existing_atom_key(Name),
    find_variable(C, Keys).
existing_atom_key(Name) ->
    try [binary_to_existing_atom(Name, utf8)] catch error:badarg -> [] end.
find_variable(_, []) -> throw({ai_error, input_variable_not_found});
find_variable(C, [K | Rest]) ->
    case maps:find(K, C) of {ok, V} -> V; error -> find_variable(C, Rest) end.
integer(V) when is_integer(V) -> V;
integer(V) ->
    try binary_to_integer(text(V)) catch _:_ -> throw({ai_error, invalid_integer}) end.
number(V) when is_number(V) -> V;
number(V) ->
    B = text(V),
    try binary_to_float(B) catch error:badarg -> integer(B) end.
unwrap({ok, V}) -> V;
unwrap({error, R}) -> throw({ai_error, R}).
failure(C, Reason) ->
    %% Deliberately omit provider bodies, prompt text, keys and stacktraces.
    S = case maps:get(ai, C, #{}) of
        M when is_map(M) -> maps:remove(last, M);
        _ -> #{}
    end,
    C1 = put_state(C, S),
    C1#{fail => iolist_to_binary(io_lib:format("AI step failed: ~p", [Reason]))}.
