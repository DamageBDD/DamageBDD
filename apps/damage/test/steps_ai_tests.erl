%% Unit tests run without a model server, credentials or paid inference.
-module(steps_ai_tests).
-include_lib("eunit/include/eunit.hrl").

ai_skills_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun(_) -> fun summarization/0 end,
        fun(_) -> fun classification/0 end,
        fun(_) -> fun classification_rejected/0 end,
        fun(_) -> fun extraction/0 end,
        fun(_) -> fun extraction_types/0 end,
        fun(_) -> fun profile_access/0 end,
        fun(_) -> fun skill_access/0 end,
        fun(_) -> fun custom_skill/0 end,
        fun(_) -> fun dry_run/0 end,
        fun(_) -> fun unknown_step/0 end,
        fun(_) -> fun namespace/0 end,
        fun(_) -> fun no_context_forwarding/0 end,
        fun(_) -> fun protected_variables/0 end,
        fun(_) -> fun call_limit/0 end,
        fun(_) -> fun timeout/0 end,
        fun(_) -> fun cancelled_runner/0 end,
        fun(_) -> fun stale_result/0 end,
        fun(_) -> fun missing_usage/0 end,
        fun(_) -> fun embeddings/0 end,
        fun(_) -> fun malformed_state/0 end,
        fun(_) -> fun request_limits/0 end,
        fun(_) -> fun tokenizer_patterns/0 end
    ]}.

setup() ->
    Saved = [{K, application:get_env(damage, K)} || K <- [ai_profiles, ai_skills]],
    set_profile([]),
    application:set_env(damage, ai_skills, []),
    Saved.
cleanup(Saved) ->
    lists:foreach(fun
        ({K, undefined}) -> application:unset_env(damage, K);
        ({K, {ok, V}}) -> application:set_env(damage, K, V)
    end, Saved),
    drain().
drain() -> receive {ai_test_request, _, _} -> drain() after 0 -> ok end.
set_profile(Overrides) ->
    Base = [{backend, damage_ai_test_backend}, {allowed_accounts, [<<"ak_test">>]},
            {allowed_skills, [<<"summarize">>, <<"classify">>, <<"extract">>,
                              <<"translate">>, <<"rewrite">>, <<"answer">>,
                              <<"prompt">>, <<"embed">>, <<"triage-v1">>]},
            {observer, self()}, {timeout_ms, 500}, {max_calls, 10}],
    application:set_env(damage, ai_profiles, [{<<"test">>, Overrides ++ Base}]).
step(C, Parts) -> step(C, Parts, <<>>).
step(C, Parts, Body) -> steps_ai:step([], C, <<"And">>, 1, Parts, Body).
context() ->
    C = step(#{public_key => <<"ak_test">>}, ["I use AI profile", "test"]),
    step(C, ["I set the AI input to"], <<"I was charged twice for my order.">>).
run(C, Skill) -> step(C, ["I run AI skill", Skill, "and store result in", "ai_output"]).
ok_context(C) -> ?assertEqual(false, maps:is_key(fail, C)).
fails(C, Fragment) ->
    ?assertMatch(#{fail := _}, C),
    ?assertNotEqual(nomatch, binary:match(maps:get(fail, C), Fragment)).

summarization() ->
    set_profile([{reply, <<"The customer reports duplicate billing.">>}]),
    C = run(context(), "summarize"), ok_context(C),
    ?assertEqual(<<"The customer reports duplicate billing.">>, maps:get("ai_output", C)),
    R = steps_ai:result(C, "ai_output"),
    ?assertEqual(<<"1">>, maps:get(skill_version, R)),
    ?assertEqual(64, byte_size(maps:get(task_sha256, R))),
    ok_context(step(C, ["the AI result should contain", "duplicate"])),
    ok_context(step(C, ["the AI token usage should not exceed", "12"])),
    fails(step(C, ["the AI token usage should not exceed", "11"]), <<"token_limit_exceeded">>).

classification() ->
    set_profile([{reply, <<"{\"label\":\"billing\"}">>}]),
    C0 = step(context(), ["I set the AI labels to"], <<"[\"billing\",\"technical\"]">>),
    C = run(C0, "classify"), ok_context(C),
    ok_context(step(C, ["the AI result should equal", "billing"])).
classification_rejected() ->
    set_profile([{reply, <<"{\"label\":\"unlisted\"}">>}]),
    C0 = step(context(), ["I set the AI labels to"], <<"[\"billing\"]">>),
    fails(run(C0, "classify"), <<"invalid_classification">>),
    ?assertEqual({error, invalid_classification}, damage_ai:safe(fun() ->
        damage_ai:validate({classify, [<<"billing">>]},
                           #{text => <<"{\"label\":\"billing\",\"extra\":1}">>}) end)).

extraction() ->
    set_profile([{reply, <<"{\"id\":\"A123\",\"amount\":9.5,\"missing\":null}">>}]),
    C0 = step(context(), ["I set the AI fields to"],
              <<"{\"id\":\"string\",\"amount\":\"number\",\"missing\":\"integer\"}">>),
    C = run(C0, "extract"), ok_context(C),
    ok_context(step(C, ["the AI result at pointer", "/amount", "should equal JSON"], <<"9.5">>)),
    ok_context(step(C, ["the AI result at pointer", "/missing", "should equal JSON"], <<"null">>)).
extraction_types() ->
    Fields = #{<<"amount">> => <<"integer">>},
    lists:foreach(fun(Bad) ->
        ?assertEqual({error, invalid_extraction}, damage_ai:safe(fun() ->
            damage_ai:validate({extract, Fields}, #{text => Bad}) end))
    end, [<<"{\"amount\":\"9\"}">>, <<"{}">>, <<"{\"amount\":9,\"extra\":1}">>]).

profile_access() ->
    ?assertEqual({error, profile_not_authorized}, damage_ai:profile(<<"test">>, #{})),
    ?assertEqual({error, profile_not_authorized},
                 damage_ai:profile(<<"test">>, #{public_key => <<"ak_other">>})),
    ?assertEqual({error, unknown_profile},
                 damage_ai:profile(<<"unknown">>, #{public_key => <<"ak_test">>})),
    C = context(), set_profile([{allowed_accounts, []}]),
    fails(run(C, "summarize"), <<"profile_not_authorized">>).
skill_access() ->
    set_profile([{allowed_skills, [<<"summarize">>]}]),
    fails(run(context(), "prompt"), <<"skill_not_allowed">>).
custom_skill() ->
    application:set_env(damage, ai_skills, [{<<"triage-v1">>, [
        {version, <<"2026-10-22">>}, {instruction, <<"Return a triage JSON object.">>},
        {output, json_object}]}]),
    set_profile([{reply, <<"{\"priority\":\"high\"}">>}]),
    C = run(context(), "triage-v1"), ok_context(C),
    ?assertEqual(<<"2026-10-22">>, maps:get(skill_version, steps_ai:result(C, "ai_output"))),
    ok_context(step(C, ["the AI result at pointer", "/priority", "should equal JSON"], <<"\"high\"">>)).

dry_run() ->
    application:unset_env(damage, ai_profiles),
    C = steps_ai:step_dry([], #{}, <<"When">>, 1,
         ["I run AI skill", "summarize", "and store result in", "ai_summary"], <<>>),
    ?assertEqual(<<"__damage_ai_dry_run__">>, maps:get("ai_summary", C)),
    ?assertEqual(#{}, steps_ai:step([{dry_run, true}], #{}, <<"Given">>, 1,
                                 ["I use AI profile", "not-configured"], <<>>)),
    receive {ai_test_request, _, _} -> ?assert(false) after 0 -> ok end.
unknown_step() ->
    ?assertError(function_clause, steps_ai:step([], #{}, <<"Given">>, 1, ["unrelated step"], <<>>)),
    ?assertError(function_clause, steps_ai:step_dry([], #{}, <<"Given">>, 1, ["unrelated step"], <<>>)).
namespace() ->
    fails(step(context(), ["I run AI skill", "summarize", "and store result in", "public_key"]),
          <<"output_name_must_start_with_ai">>).
no_context_forwarding() ->
    set_profile([]),
    C = run((context())#{access_token => <<"SECRET_CANARY">>,
                         headers => [{<<"authorization">>, <<"SECRET_CANARY">>}]}, "summarize"),
    ok_context(C),
    receive {ai_test_request, _, Request} ->
        ?assertEqual(nomatch, binary:match(term_to_binary(Request), <<"SECRET_CANARY">>))
    after 100 -> ?assert(false) end.
protected_variables() ->
    fails(step((context())#{access_token => <<"secret">>},
               ["I use variable", "access_token", "as AI input"]), <<"protected_input_variable">>).

call_limit() ->
    set_profile([{max_calls, 1}]),
    C = run(context(), "summarize"), ok_context(C),
    C1 = step(C, ["I use AI profile", "test"]),
    C2 = step(C1, ["I set the AI input to"], <<"second input">>),
    fails(run(C2, "summarize"), <<"call_limit_exceeded">>).
timeout() ->
    set_profile([{timeout_ms, 100}, {delay_ms, 1000}]),
    fails(run(context(), "summarize"), <<"timeout">>),
    receive {ai_test_request, Worker, _} -> ?assertNot(is_process_alive(Worker))
    after 100 -> ?assert(false) end.
cancelled_runner() ->
    set_profile([{delay_ms, 1000}]), C = context(),
    Pid = spawn(fun() -> run(C, "summarize") end),
    receive {ai_test_request, Worker, _} ->
        Mon = erlang:monitor(process, Worker), exit(Pid, kill),
        receive {'DOWN', Mon, process, Worker, _} -> ok
        after 500 -> ?assert(false) end
    after 200 -> ?assert(false) end.
stale_result() ->
    set_profile([]),
    C = run(context(), "summarize"), ok_context(C), drain(),
    set_profile([{test_error, {sensitive_provider_error, <<"SECRET_CANARY">>}}]),
    Failed = run(C, "summarize"),
    fails(Failed, <<"backend_failed">>),
    ?assertEqual(false, maps:is_key("ai_output", Failed)),
    ?assertEqual(nomatch, binary:match(term_to_binary(Failed), <<"SECRET_CANARY">>)),
    ?assertEqual(false, maps:is_key(last, maps:get(ai, Failed))).
missing_usage() ->
    set_profile([{usage, #{}}]), C = run(context(), "summarize"),
    fails(step(C, ["the AI token usage should not exceed", "100"]), <<"token_usage_unavailable">>).
embeddings() ->
    set_profile([{reply, [1.0, 0.0]}]),
    C = run(context(), "embed"), ok_context(C),
    ok_context(step(C, ["the AI embedding should have", "2", "dimensions"])),
    C2 = step(C, ["I run AI skill", "embed", "and store result in", "ai_second"]),
    ok_context(step(C2, ["AI embeddings in", "ai_output", "and", "ai_second",
                        "should have cosine similarity at least", "0.99"])),
    ?assertEqual(1.0, damage_ai:cosine([2, 0], [3, 0])),
    ?assertEqual(-1.0, damage_ai:cosine([1, 0], [-1, 0])),
    ?assertEqual({error, zero_embedding}, damage_ai:safe(fun() -> damage_ai:cosine([0], [1]) end)),
    ?assertEqual({error, embedding_dimension_mismatch},
                 damage_ai:safe(fun() -> damage_ai:cosine([1], [1, 2]) end)).
malformed_state() ->
    fails(step(#{ai => bad}, ["I set the AI input to"], <<"text">>), <<"invalid_ai_state">>).
request_limits() ->
    set_profile([{max_input_bytes, 10}]),
    fails(run(context(), "summarize"), <<"input_too_large">>),
    receive {ai_test_request, _, _} -> ?assert(false) after 0 -> ok end.

%% Use the actual project's tokenizer, not hand-constructed token expectations.
tokenizer_patterns() ->
    Lines = [
        "I use AI profile \"test\"",
        "I set the AI input to",
        "I use variable \"ticket\" as AI input",
        "I set the AI labels to",
        "I set the AI fields to",
        "I run AI skill \"summarize\" and store result in \"ai_summary\"",
        "the AI request should finish within \"5000\" milliseconds",
        "the AI result at pointer \"/amount\" should equal JSON",
        "AI embeddings in \"ai_a\" and \"ai_b\" should have cosine similarity at least \"0.8\""
    ],
    lists:foreach(fun(Line) ->
        Parts = damage_step_tokenizer:tokenize(Line),
        C = steps_ai:step_dry([], #{}, <<"And">>, 1, Parts, <<>>),
        ok_context(C)
    end, Lines).

json_pointer_test() ->
    J = #{<<"a/b">> => [#{<<"~key">> => 42}]},
    ?assertEqual(42, damage_ai:pointer(J, <<"/a~1b/0/~0key">>)),
    ?assertEqual(J, damage_ai:pointer(J, <<>>)),
    ?assertEqual({error, invalid_json_pointer},
                 damage_ai:safe(fun() -> damage_ai:pointer([1], <<"/01">>) end)),
    ?assertEqual({error, json_pointer_not_found},
                 damage_ai:safe(fun() -> damage_ai:pointer(#{}, <<"/missing">>) end)).
