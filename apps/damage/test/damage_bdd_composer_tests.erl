%% These tests require the full umbrella's Erlang/egherkin dependencies.
%% Compiler forms are parsed but never compiled/loaded/executed as step modules.
-module(damage_bdd_composer_tests).
-include_lib("eunit/include/eunit.hrl").

forms(Source) ->
    {ok, Tokens, _} = erl_scan:string(Source),
    {ok, Form} = erl_parse:parse_form(Tokens),
    [Form].

steps(Source) ->
    damage_bdd_catalog:from_forms(<<"steps_fixture">>, <<0:128>>, forms(Source)).

catalog() ->
    Ss = steps(
        "step(_C, Ctx, <<\"When\">>, _N, [\"I request\", Path], Body) -> erlang:error(should_not_execute);" ++
            "step(_C, Ctx, <<\"Then\">>, _N, [\"the status is\", Status], _B) -> erlang:error(should_not_execute)."
    ),
    #{revision => <<"test-revision">>, steps => Ss}.

ast(Steps) -> {1, [], <<"Fixture">>, <<>>, undefined, [{3, <<"Example">>, [], Steps}]}.

extraction_does_not_execute_body_test() ->
    ?assertEqual(2, length(maps:get(steps, catalog()))).

exact_keyword_test() ->
    C = catalog(),
    ?assertEqual(1, length(damage_bdd_catalog:matches(C, <<"When">>, ["I request", "/health"]))),
    ?assertEqual([], damage_bdd_catalog:matches(C, <<"Given">>, ["I request", "/health"])).

exact_literal_and_arity_test() ->
    C = catalog(),
    ?assertEqual([], damage_bdd_catalog:matches(C, <<"When">>, ["I Request", "/health"])),
    ?assertEqual([], damage_bdd_catalog:matches(C, <<"When">>, ["I request", "/health", "extra"])).

whole_parts_catchall_excluded_test() ->
    ?assertEqual([], steps("step(_C, Ctx, _K, _N, Anything, _B) -> Ctx.")).

all_variable_parts_excluded_test() ->
    ?assertEqual([], steps("step(_C, Ctx, _K, _N, [Anything], _B) -> Ctx.")).

documentation_clause_excluded_test() ->
    ?assertEqual([], steps("step(_C, _Ctx, documentation, _N, [\"I request\", Path], _B) -> ok.")).

literal_must_roundtrip_test() ->
    ?assertEqual([], steps("step(_C, Ctx, _K, _N, [\"I request \", Path], _B) -> Ctx.")).

repeated_parameter_test() ->
    Ss = steps("step(_C, Ctx, _K, _N, [\"I compare\", X, \"with\", X], _B) -> Ctx."),
    C = #{steps => Ss},
    ?assertEqual(
        1, length(damage_bdd_catalog:matches(C, <<"Given">>, ["I compare", "a", "with", "a"]))
    ),
    ?assertEqual([], damage_bdd_catalog:matches(C, <<"Given">>, ["I compare", "a", "with", "b"])).

aliased_parts_test() ->
    Ss = steps("step(_C, Ctx, _K, _N, [\"I request\", Path] = Parts, _B) -> Ctx."),
    ?assertMatch([#{template := <<"I request \"<Path>\"">>}], Ss).

runtime_checks_are_advisory_test() ->
    [S] = steps(
        "step(_C, #{response := R} = Ctx, _K, _N, [\"I request\", Path], Body) when is_list(Path) -> Ctx."
    ),
    ?assertEqual(true, maps:get(runtime_checks, S)),
    ?assertEqual(true, maps:get(body_hint, S)).

valid_ast_test() ->
    V = damage_bdd_validator:check_ast(
        ast([
            {4, <<"When">>, [<<"I request \"/health\"">>]},
            {5, <<"Then">>, [<<"the status is \"200\"">>]}
        ]),
        catalog()
    ),
    ?assertEqual(true, maps:get(valid, V)),
    ?assertEqual(2, maps:get(step_count, V)),
    ?assertEqual(<<"gherkin_syntax_and_step_signatures">>, maps:get(scope, V)).

unknown_step_has_line_test() ->
    V = damage_bdd_validator:check_ast(ast([{9, <<"When">>, [<<"I invent a step">>]}]), catalog()),
    ?assertEqual(false, maps:get(valid, V)),
    ?assertMatch([#{line := 9, code := <<"unknown_step">>}], maps:get(diagnostics, V)).

unresolved_marker_rejected_test() ->
    V = damage_bdd_validator:check_ast(
        ast([{4, <<"When">>, [<<"I request \"<Path>\"">>]}]), catalog()
    ),
    ?assertEqual(false, maps:get(valid, V)).

unbalanced_quotes_rejected_test() ->
    V = damage_bdd_validator:check_ast(
        ast([{4, <<"When">>, [<<"I request \"/health">>]}]), catalog()
    ),
    ?assertEqual(false, maps:get(valid, V)).

docstrings_are_data_not_steps_test() ->
    V = damage_bdd_validator:check_ast(
        ast([
            {4, <<"When">>, [
                <<"I request \"/health\"">>,
                {<<"\"\"\"">>, [<<"When I invent a step">>, <<"{{payload}}">>]}
            ]}
        ]),
        catalog()
    ),
    ?assertEqual(true, maps:get(valid, V)),
    ?assertEqual(1, maps:get(step_count, V)),
    ?assertEqual([<<"payload">>], maps:get(required_variables, V)).

context_variables_not_resolved_test() ->
    V = damage_bdd_validator:check_ast(
        ast([{4, <<"When">>, [<<"I request \"{{path}}\"">>]}]), catalog()
    ),
    ?assertEqual(true, maps:get(valid, V)),
    ?assertEqual([<<"path">>], maps:get(required_variables, V)).

empty_feature_rejected_test() ->
    V = damage_bdd_validator:check_ast(ast([]), catalog()),
    ?assertEqual(false, maps:get(valid, V)).

parser_integration_test() ->
    %% Real egherkin parser integration, not a handwritten AST fixture.
    Feature =
        <<"Feature: HTTP\n\n  Scenario: Health\n    When I request \"/health\"\n    Then the status is \"200\"\n">>,
    V = damage_bdd_validator:validate(Feature, catalog()),
    ?assertEqual(true, maps:get(valid, V)),
    ?assertEqual(2, maps:get(step_count, V)).

unsupported_outline_rejected_test() ->
    V = damage_bdd_validator:validate(<<"Feature: HTTP\nScenario Outline: Example\n">>, catalog()),
    ?assertMatch([#{code := <<"unsupported_structure">>}], maps:get(diagnostics, V)).

oversized_feature_rejected_test() ->
    V = damage_bdd_validator:validate(binary:copy(<<"x">>, 65537), catalog()),
    ?assertEqual(false, maps:get(valid, V)).

model_schema_is_strict_test() ->
    R = #{
        <<"feature">> => <<"Feature: Example">>, <<"assumptions">> => [], <<"missing_steps">> => []
    },
    ?assertMatch({ok, #{feature := _}}, damage_bdd_generator:normalize_reply(R)),
    ?assertEqual(error, damage_bdd_generator:normalize_reply(maps:remove(<<"missing_steps">>, R))),
    ?assertEqual(error, damage_bdd_generator:normalize_reply(R#{<<"missing_steps">> => false})),
    ?assertEqual(
        error, damage_bdd_generator:normalize_reply(R#{<<"assumptions">> => [#{<<"x">> => 1}]})
    ).

prompt_contains_actual_intent_and_authoritative_signatures_test() ->
    P = damage_bdd_generator:build_prompt(
        <<"Check inventory availability">>, maps:get(steps, catalog()), []
    ),
    ?assertNotEqual(nomatch, binary:match(P, <<"Check inventory availability">>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"ALLOWED_SIGNATURES_JSON">>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"I request">>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"missing_steps">>)).
