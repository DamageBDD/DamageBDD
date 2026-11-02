-module(damage_agent_draft_tests).
-include_lib("eunit/include/eunit.hrl").

templates() -> [#{id => <<"code-review">>}].
reply() -> #{<<"template">> => <<"code-review">>, <<"goal">> => <<"Review the approved snapshot.">>,
    <<"assumptions">> => [], <<"missing_steps">> => []}.

bounded_reply_test() ->
    ?assertMatch({ok,#{template := <<"code-review">>}},damage_agent_draft:normalize(reply(),templates())).
unknown_template_test() ->
    ?assertEqual(error,damage_agent_draft:normalize((reply())#{<<"template">> => <<"shell">>},templates())).
no_model_authority_fields_test_() ->
    [?_assertEqual(error,damage_agent_draft:normalize((reply())#{Key => Value},templates()))
        || {Key,Value} <- [{<<"max_cost_units">>,1000},{<<"feature">>,<<"arbitrary Gherkin">>},
                          {<<"provider">>,<<"arbitrary">>},{<<"approve">>,true}]].
invalid_objective_test_() ->
    [?_assertEqual(error,damage_agent_draft:normalize((reply())#{<<"goal">> => Goal},templates()))
        || Goal <- [<<>>,<<"   ">>,<<"break\"\"\"out">>,<<"CR\rline">>,<<0>>,<<255>>,binary:copy(<<"x">>,4097)]].
unsupported_requirements_remain_evidence_test() ->
    R = (reply())#{<<"missing_steps">> => [<<"No publishing capability">>]},
    ?assertMatch({ok,#{missing_steps := [<<"No publishing capability">>]}},damage_agent_draft:normalize(R,templates())).
feature_is_canonical_launch_only_test() ->
    F = damage_agent_draft:feature(<<"code-review">>,<<"Inspect source.\nExplain evidence.">>),
    ?assertNotEqual(nomatch,binary:match(F,<<"Given I use agent template \"code-review\"">>)),
    ?assertNotEqual(nomatch,binary:match(F,<<"      Inspect source.\n      Explain evidence.\n">>)),
    ?assertNotEqual(nomatch,binary:match(F,<<"should be accepted">>)),
    ?assertEqual(nomatch,binary:match(F,<<"should be completed">>)),
    ?assertException(error,_,damage_agent_draft:feature(<<"bad\"template">>,<<"Goal">>)).
private_inference_metadata_test() ->
    M = damage_bdd_inference:metadata(#{provider => ollama,model => <<"code">>,
        host => <<"private-host">>,auth => secret,prompt => <<"private-source">>}),
    ?assertEqual(#{provider => ollama,model => <<"code">>},M).
control_plane_requires_normal_identity_test_() ->
    [?_assert(damage_bdd_access:credential_allowed({access_token,<<"server-validated-later">>})),
     ?_assertNot(damage_bdd_access:credential_allowed({access_token,<<>>})),
     ?_assertNot(damage_bdd_access:credential_allowed({l402,<<"paid-proof">>})),
     ?_assertNot(damage_bdd_access:credential_allowed({nostr,<<"unsupported-here">>})),
     ?_assertNot(damage_bdd_access:credential_allowed({error,missing}))].
