-module(ecai_wikimedia_presets_tests).

-include_lib("eunit/include/eunit.hrl").

builtins_are_small_public_descriptors_test() ->
    with_default_presets(fun() ->
        Presets = ecai_wikimedia_presets:list(),
        ?assert(length(Presets) >= 4),
        Smoke = lists:keyfind(<<"laptop-smoke">>, 1, [
            {maps:get(id, Preset), Preset} || Preset <- Presets
        ]),
        ?assertMatch({<<"laptop-smoke">>, _}, Smoke),
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
        ProductionPresets = [
            Preset
         || Preset <- ecai_wikimedia_presets:list(),
            maps:get(id, Preset) =/= <<"laptop-smoke">>
        ],
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
            ProductionPresets
        )
    end).

laptop_smoke_preset_expands_to_bundled_fixture_test() ->
    with_default_presets(fun() ->
        with_on_demand_fixture(fun() ->
            Presets = ecai_wikimedia_presets:list(),
            Smoke = hd([
                Preset
             || Preset <- Presets,
                maps:get(id, Preset) =:= <<"laptop-smoke">>
            ]),
            ?assertEqual(<<"Laptop smoke test (3 records)">>, maps:get(label, Smoke)),
            {ok, Spec0} = ecai_wikimedia_presets:spec(
                <<"laptop-smoke">>,
                <<"operator-test">>
            ),
            {ok, Spec} = ecai_index_job_codec:normalize_spec(Spec0),
            Source = maps:get(source, Spec),
            Target = maps:get(target, Spec),
            Options = maps:get(options, Spec),
            Finalize = maps:get(finalize, Spec),
            CatalogPath = maps:get(catalog_path, Source),
            ?assert(is_binary(CatalogPath)),
            ?assert(filelib:is_regular(binary_to_list(CatalogPath))),
            ?assertEqual(<<"enwiki">>, maps:get(project, Source)),
            ?assertEqual([<<"2026-06">>], maps:get(pageview_months, Source)),
            ?assertEqual(<<"20260720">>, maps:get(content_release, Source)),
            ?assertEqual(<<"ecai-wikimedia-laptop-smoke">>, maps:get(index_id, Target)),
            ?assertEqual(<<"org.damagebdd.wikimedia.smoke">>, maps:get(namespace, Target)),
            ?assertEqual(3, maps:get(limit, Options)),
            ?assertEqual(1, maps:get(minimum_active_months, Options)),
            ?assertEqual(8, maps:get(selection_shards, Options)),
            ?assertEqual(4096, maps:get(partition_buffer_bytes, Options)),
            ?assertEqual(100, maps:get(index_chunk_lines, Options)),
            ?assertEqual(false, maps:get(publish_activity_ipfs, Options)),
            ?assertEqual(false, maps:get(publish_ipfs, Finalize))
        end)
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

configured_presets_preserve_smoke_and_replace_production_builtins_test() ->
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
        Public = ecai_wikimedia_presets:list(),
        Ids = [maps:get(id, Preset) || Preset <- Public],
        ?assert(lists:member(<<"laptop-smoke">>, Ids)),
        ?assert(lists:member(<<"testwiki">>, Ids)),
        ?assertNot(lists:member(<<"enwiki">>, Ids)),
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

with_on_demand_fixture(Fun) ->
    case whereis(ecai_wikimedia_fixture_server) of
        Pid when is_pid(Pid) ->
            Fun();
        undefined ->
            PreviousPort = application:get_env(ecai, wikimedia_fixture_port),
            try
                ok = application:set_env(ecai, wikimedia_fixture_port, 0),
                {ok, Pid} = ecai_wikimedia_fixture_server:start_link(),
                unlink(Pid),
                try Fun()
                after
                    ok = ecai_wikimedia_fixture_server:stop(Pid)
                end
            after
                restore_env(wikimedia_fixture_port, PreviousPort)
            end
    end.

restore_env(Key, {ok, Value}) ->
    application:set_env(ecai, Key, Value);
restore_env(Key, undefined) ->
    application:unset_env(ecai, Key).
