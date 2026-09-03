-module(ecai_wikimedia_presets_tests).

-include_lib("eunit/include/eunit.hrl").

builtins_are_small_public_descriptors_test() ->
    with_default_presets(fun() ->
        Presets = ecai_wikimedia_presets:list(),
        ?assert(length(Presets) >= 3),
        Ids = [maps:get(id, Preset) || Preset <- Presets],
        ?assertEqual(length(Ids), length(lists:usort(Ids))),
        lists:foreach(
            fun(Preset) ->
                ?assert(maps:is_key(label, Preset)),
                ?assert(maps:is_key(project, Preset)),
                ?assertNot(maps:is_key(base_dir, Preset)),
                ?assertNot(maps:is_key(pageview_months, Preset)),
                ?assertNot(maps:is_key(content_release, Preset))
            end,
            Presets
        )
    end).

builtins_expand_to_normalizable_server_specs_test() ->
    with_default_presets(fun() ->
        Owner = <<"operator-test">>,
        lists:foreach(
            fun(Preset) ->
                Id = maps:get(id, Preset),
                {ok, Spec0} = ecai_wikimedia_presets:spec(Id, Owner),
                {ok, Spec} = ecai_index_job_codec:normalize_spec(Spec0),
                ?assertEqual(wikimedia_visibility, maps:get(kind, Spec)),
                ?assertEqual(Owner, maps:get(owner, Spec)),
                Source = maps:get(source, Spec),
                ?assertEqual(maps:get(project, Preset), maps:get(project, Source)),
                ?assertEqual(12, length(maps:get(pageview_months, Source))),
                Finalize = maps:get(finalize, Spec),
                ?assertEqual(false, maps:get(publish_ipfs, Finalize))
            end,
            ecai_wikimedia_presets:list()
        )
    end).

unknown_preset_is_rejected_test() ->
    with_default_presets(fun() ->
        ?assertEqual(
            {error, {unknown_wikimedia_preset, <<"missing">>}},
            ecai_wikimedia_presets:spec(<<"missing">>, <<"operator-test">>)
        )
    end).

empty_owner_is_rejected_test() ->
    with_default_presets(fun() ->
        ?assertEqual(
            {error, invalid_owner},
            ecai_wikimedia_presets:spec(<<"enwiki">>, <<>>)
        )
    end).


configured_presets_replace_builtins_test() ->
    Previous = application:get_env(ecai, wikimedia_index_presets),
    try
        ok = application:set_env(
            ecai,
            wikimedia_index_presets,
            [
                #{
                    id => <<"testwiki">>,
                    label => <<"Test Wikipedia">>,
                    description => <<"Fixture preset">>,
                    project => <<"testwiki">>,
                    pageview_project => <<"test.wikipedia">>,
                    namespace => <<"org.damagebdd.wikimedia.test">>,
                    limit => 1000,
                    minimum_active_months => 1,
                    publish_ipfs => false
                }
            ]
        ),
        [Public] = ecai_wikimedia_presets:list(),
        ?assertEqual(<<"testwiki">>, maps:get(id, Public)),
        {ok, Spec0} = ecai_wikimedia_presets:spec(<<"testwiki">>, <<"owner">>),
        {ok, Spec} = ecai_index_job_codec:normalize_spec(Spec0),
        ?assertEqual(1000, maps:get(limit, maps:get(options, Spec)))
    after
        restore_env(wikimedia_index_presets, Previous)
    end.

with_default_presets(Fun) ->
    Presets = application:get_env(ecai, wikimedia_index_presets),
    Publish = application:get_env(ecai, wikimedia_preset_publish_ipfs),
    try
        _ = application:unset_env(ecai, wikimedia_index_presets),
        ok = application:set_env(ecai, wikimedia_preset_publish_ipfs, false),
        Fun()
    after
        restore_env(wikimedia_index_presets, Presets),
        restore_env(wikimedia_preset_publish_ipfs, Publish)
    end.

restore_env(Key, {ok, Value}) ->
    application:set_env(ecai, Key, Value);
restore_env(Key, undefined) ->
    application:unset_env(ecai, Key).
