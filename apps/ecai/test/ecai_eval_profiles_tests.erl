-module(ecai_eval_profiles_tests).
-include_lib("eunit/include/eunit.hrl").

spec() -> hd(ecai_eval_profiles:templates()).
recipe() -> #{<<"kind">> => <<"neurons">>, <<"hook">> => <<"mlp.down_proj.output">>,
    <<"token_scope">> => <<"generated">>, <<"normalization">> => <<"residual_norm">>,
    <<"neurons">> => [#{<<"layer">> => 3, <<"index">> => 42, <<"dose_milli">> => 250}]}.
normalize_recipe(R) -> ecai_eval_profiles:normalize((spec())#{<<"intervention">> => R}).
templates_are_unmeasured_test() ->
    lists:foreach(fun(S) ->
        N = ecai_eval_profiles:normalize(S),
        ?assertEqual(null, maps:get(<<"model_revision">>, N)),
        ?assertEqual(#{<<"kind">> => <<"unconfigured">>}, maps:get(<<"intervention">>, N))
    end, ecai_eval_profiles:templates()),
    ?assertEqual(false, maps:get(<<"activation_steering">>, ecai_eval_profiles:capabilities())).
caller_cannot_claim_verified_test() ->
    ?assertThrow({eval_error,unexpected_fields},ecai_eval_profiles:normalize((spec())#{<<"verified">> => true})).
caller_cannot_set_owner_test() ->
    ?assertThrow({eval_error,unexpected_fields},ecai_eval_profiles:normalize((spec())#{<<"owner">> => <<"bob">>})).
canonical_tags_test() ->
    A = ecai_eval_profiles:normalize((spec())#{<<"tags">> => [<<"a">>, <<"b">>, <<"a">>]}),
    B = ecai_eval_profiles:normalize((spec())#{<<"tags">> => [<<"b">>, <<"a">>]}),
    ?assertEqual(ecai_eval_util:hash(A), ecai_eval_util:hash(B)).
canonical_neurons_test() ->
    R = recipe(), [N] = maps:get(<<"neurons">>, R), M = N#{<<"layer">> => 1},
    ?assertEqual(normalize_recipe(R#{<<"neurons">> => [M,N]}), normalize_recipe(R#{<<"neurons">> => [N,M]})).
duplicate_neuron_test() ->
    R = recipe(), [N] = maps:get(<<"neurons">>, R),
    ?assertThrow({eval_error,duplicate_neuron},normalize_recipe(R#{<<"neurons">> => [N,N]})).
dose_bound_test() ->
    R = recipe(), [N] = maps:get(<<"neurons">>, R),
    ?assertThrow({eval_error,invalid_integer},normalize_recipe(R#{<<"neurons">> => [N#{<<"dose_milli">> => 4001}]})).
empty_neurons_test() -> ?assertThrow({eval_error,invalid_neurons},normalize_recipe((recipe())#{<<"neurons">> => []})).
unknown_hook_test() -> ?assertThrow({eval_error,invalid_enum},normalize_recipe((recipe())#{<<"hook">> => <<"arbitrary">>})).
vector_hash_test() ->
    R = #{<<"kind">> => <<"vector">>, <<"hook">> => <<"residual.post_layer">>, <<"token_scope">> => <<"generated">>,
        <<"normalization">> => <<"absolute">>, <<"layer">> => 2, <<"dose_milli">> => 100,
        <<"vector_sha256">> => binary:copy(<<"a">>,64)},
    ?assertEqual(R,maps:get(<<"intervention">>,normalize_recipe(R))),
    ?assertThrow({eval_error,invalid_vector_hash},normalize_recipe(R#{<<"vector_sha256">> => <<"not-a-digest">>})).
draft_cannot_smuggle_recipe_test() ->
    ?assertThrow({eval_error,unexpected_fields},normalize_recipe(#{<<"kind">> => <<"unconfigured">>, <<"layer">> => 9})).
no_verified_status_test() ->
    R = #{<<"id">> => <<"p">>, <<"spec">> => spec(), <<"comparisons">> => [#{}], <<"created_at_ms">> => 0},
    S = ecai_eval_profiles:summary(R), ?assertEqual(<<"comparison_linked">>,maps:get(<<"status">>,S)),
    ?assertEqual(false,maps:get(<<"steering_attested">>,S)).

fixtures() ->
    P = #{<<"spec">> => (spec())#{<<"model_revision">> => <<"weights-sha">>}},
    T = #{<<"id">> => <<"target">>, <<"model">> => <<"Qwen/Qwen3.5-4B">>, <<"model_revision">> => <<"weights-sha">>},
    A = #{<<"id">> => <<"a">>, <<"suite_id">> => <<"s">>, <<"split">> => <<"test">>,
        <<"targets">> => #{<<"target">> => T}, <<"config">> => #{<<"max_output_tokens">> => 256}},
    Row = #{<<"case_id">> => <<"case">>, <<"target_id">> => <<"target">>, <<"status">> => <<"pass">>},
    M = #{<<"complete">> => true, <<"pass_bps">> => 10000},
    Report = #{<<"suite_id">> => <<"s">>, <<"targets">> => #{<<"target">> => M}, <<"cases">> => [Row]},
    {P,A,Report,A#{<<"id">> => <<"b">>}}.
compare(P,A,R,B) -> ecai_eval_profiles:comparison(P,A,<<"target">>,R,B,<<"target">>,R).
comparison_is_observational_test() ->
    {P,A,R,B} = fixtures(), C = compare(P,A,R,B),
    ?assertEqual(false,maps:get(<<"steering_attested">>,C)),
    ?assertEqual(false,maps:get(<<"model_identity_attested">>,C)),
    ?assertEqual(0,maps:get(<<"pass_delta_bps">>,C)), ?assertEqual(true,maps:get(<<"settings_match">>,C)).
same_arm_test() ->
    {P,A,R,_} = fixtures(), ?assertThrow({eval_error,identical_comparison_arm},compare(P,A,R,A)).
split_mismatch_test() ->
    {P,A,R,B} = fixtures(), ?assertThrow({eval_error,incompatible_split},compare(P,A,R,B#{<<"split">> => <<"holdout">>})).
revision_required_test() ->
    {_,A,R,B} = fixtures(), ?assertThrow({eval_error,profile_revision_required},compare(#{<<"spec">> => spec()},A,R,B)).
revision_mismatch_test() ->
    {P,A,R,B} = fixtures(), T = maps:get(<<"target">>,maps:get(<<"targets">>,B)),
    Bad = B#{<<"targets">> => #{<<"target">> => T#{<<"model_revision">> => <<"different">>}}},
    ?assertThrow({eval_error,profile_revision_mismatch},compare(P,A,R,Bad)).
incomplete_not_linked_test() ->
    {P,A,R,B} = fixtures(), M = maps:get(<<"target">>,maps:get(<<"targets">>,R)),
    Bad = R#{<<"targets">> => #{<<"target">> => M#{<<"complete">> => false}}},
    ?assertThrow({eval_error,comparison_incomplete},compare(P,A,Bad,B)).
settings_difference_visible_test() ->
    {P,A,R,B} = fixtures(), C = compare(P,A,R,B#{<<"config">> => #{<<"max_output_tokens">> => 512}}),
    ?assertEqual(false,maps:get(<<"settings_match">>,C)).
