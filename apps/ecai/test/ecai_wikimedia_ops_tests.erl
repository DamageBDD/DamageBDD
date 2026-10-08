-module(ecai_wikimedia_ops_tests).

-include_lib("eunit/include/eunit.hrl").

genesis_spec_is_normalizable_test() ->
    Spec0 = ecai_wikimedia_ops:genesis_spec(#{
        owner => <<"operator-test">>,
        pageview_months => [<<"2026-05">>, <<"2026-06">>],
        minimum_active_months => 1,
        limit => 1000,
        selection_shards => 8,
        content_release => <<"20260720">>,
        base_dir => <<"/tmp/ecai-wikimedia-ops-test">>,
        publish_ipfs => false,
        publish_activity_ipfs => false
    }),
    {ok, Spec} = ecai_index_job_codec:normalize_spec(Spec0),
    ?assertEqual(wikimedia_visibility, maps:get(kind, Spec)),
    ?assertEqual(<<"operator-test">>, maps:get(owner, Spec)),
    Source = maps:get(source, Spec),
    ?assertEqual(<<"enwiki">>, maps:get(project, Source)),
    ?assertEqual(<<"20260720">>, maps:get(content_release, Source)),
    ?assertEqual(
        [<<"2026-05">>, <<"2026-06">>],
        maps:get(pageview_months, Source)
    ),
    Options = maps:get(options, Spec),
    ?assertEqual(1000, maps:get(limit, Options)),
    ?assertEqual(1, maps:get(minimum_active_months, Options)),
    ?assertEqual(8, maps:get(selection_shards, Options)),
    ?assertEqual(false, maps:get(publish_activity_ipfs, Options)),
    Finalize = maps:get(finalize, Spec),
    ?assertEqual(false, maps:get(publish_ipfs, Finalize)),
    ?assertEqual(false, maps:get(auto_mint, Finalize)).

same_overrides_produce_same_spec_hash_test() ->
    Overrides = #{
        pageview_months => [<<"2026-05">>, <<"2026-06">>],
        minimum_active_months => 1,
        limit => 100,
        selection_shards => 8,
        content_release => <<"20260720">>,
        base_dir => <<"/tmp/ecai-wikimedia-ops-test">>,
        publish_ipfs => false,
        publish_activity_ipfs => false
    },
    {ok, Hash1} = ecai_index_job_codec:spec_hash(
        ecai_wikimedia_ops:genesis_spec(Overrides)
    ),
    {ok, Hash2} = ecai_index_job_codec:spec_hash(
        ecai_wikimedia_ops:genesis_spec(Overrides)
    ),
    ?assertEqual(Hash1, Hash2),
    ?assertEqual(32, byte_size(Hash1)).

minimum_active_months_cannot_exceed_window_test() ->
    Spec = ecai_wikimedia_ops:genesis_spec(#{
        pageview_months => [<<"2026-06">>],
        minimum_active_months => 2,
        selection_shards => 8,
        content_release => <<"20260720">>,
        publish_ipfs => false
    }),
    ?assertEqual(
        {error, {minimum_active_months_exceeds_window, 2, 1}},
        ecai_index_job_codec:normalize_spec(Spec)
    ).

invalid_override_type_is_rejected_test() ->
    ?assertError(badarg, ecai_wikimedia_ops:genesis_spec(not_a_map)).


custom_project_targets_are_isolated_test() ->
    En = ecai_wikimedia_ops:genesis_spec(#{project => <<"enwiki">>}),
    Fr = ecai_wikimedia_ops:genesis_spec(#{
        project => <<"frwiki">>,
        pageview_project => <<"fr.wikipedia">>,
        pageview_months => [<<"2026-06">>],
        minimum_active_months => 1
    }),
    EnTarget = maps:get(<<"target">>, En),
    FrTarget = maps:get(<<"target">>, Fr),
    ?assertNotEqual(maps:get(<<"base_dir">>, EnTarget), maps:get(<<"base_dir">>, FrTarget)),
    ?assertNotEqual(maps:get(<<"index_id">>, EnTarget), maps:get(<<"index_id">>, FrTarget)),
    ?assertNotEqual(maps:get(<<"namespace">>, EnTarget), maps:get(<<"namespace">>, FrTarget)),
    ?assertEqual(<<"frwiki">>, maps:get(<<"project">>, maps:get(<<"source">>, Fr))),
    FrDefault = ecai_wikimedia_ops:genesis_spec(#{project => <<"frwiki">>}),
    ?assertEqual(<<"fr.wikipedia">>,
                 maps:get(<<"pageview_project">>, maps:get(<<"source">>, FrDefault))),
    ?assertMatch({ok, _}, ecai_index_job_codec:normalize_spec(Fr)).

malformed_project_cannot_escape_output_directory_test() ->
    Invalid = ecai_wikimedia_ops:genesis_spec(#{project => <<"../outside">>}),
    En = ecai_wikimedia_ops:genesis_spec(#{}),
    ?assertEqual(maps:get(<<"base_dir">>, maps:get(<<"target">>, En)),
                 maps:get(<<"base_dir">>, maps:get(<<"target">>, Invalid))),
    ?assertMatch({error, _}, ecai_index_job_codec:normalize_spec(Invalid)),
    DotDot = ecai_wikimedia_ops:genesis_spec(#{project => <<"..">>}),
    ?assertEqual(maps:get(<<"base_dir">>, maps:get(<<"target">>, En)),
                 maps:get(<<"base_dir">>, maps:get(<<"target">>, DotDot))).
