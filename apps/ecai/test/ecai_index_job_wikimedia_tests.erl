-module(ecai_index_job_wikimedia_tests).

-include_lib("eunit/include/eunit.hrl").

catalog_stage_records_activity_and_advances_test() ->
    with_runtime(fun(Job, Runtime0) ->
        {continue, Runtime1, Checkpoint1, Progress} =
            ecai_index_job_wikimedia:run_batch(
                Job,
                Runtime0,
                #{stage => catalog},
                1
            ),
        ?assertEqual(pageviews, maps:get(stage, Checkpoint1)),
        ?assertEqual(selecting_by_pageviews, maps:get(phase, Progress)),
        ActivityStatus = ecai_ipfs_activity:status(maps:get(activity, Runtime1)),
        ?assertEqual(1, maps:get(sequence, ActivityStatus)),
        ?assertEqual(1, maps:get(pending_events, ActivityStatus)),
        {ok, _} = ecai_ipfs_activity:close(maps:get(activity, Runtime1))
    end).

empty_source_boundaries_advance_without_network_test() ->
    with_runtime(fun(Job, Runtime0) ->
        {continue, Runtime1, Checkpoint1, Progress} =
            ecai_index_job_wikimedia:run_batch(
                Job,
                Runtime0,
                #{stage => pageviews, pageview_index => 0},
                2
            ),
        ?assertEqual(selection, maps:get(stage, Checkpoint1)),
        ?assertEqual(merging_visibility_selection, maps:get(phase, Progress)),
        ?assertEqual(0, maps:get(pageview_files_total, Progress)),
        ?assertEqual(0, maps:get(partitions_total, Progress)),
        {ok, _} = ecai_ipfs_activity:close(maps:get(activity, Runtime1))
    end).

unknown_stage_fails_closed_test() ->
    with_runtime(fun(Job, Runtime0) ->
        ?assertEqual(
            {error, {unknown_wikimedia_stage, impossible_stage}},
            ecai_index_job_wikimedia:run_batch(
                Job,
                Runtime0,
                #{stage => impossible_stage},
                1
            )
        ),
        {ok, _} = ecai_ipfs_activity:close(maps:get(activity, Runtime0))
    end).

result_builds_pinned_source_identity_test() ->
    with_tmp(fun(Dir) ->
        JobId = <<"wikimedia-result-test">>,
        Catalog = #{
            schema => ecai_wikimedia_catalog:version(),
            project => <<"enwiki">>,
            pageview_project => <<"en.wikipedia">>,
            cirrus_release => <<"20260720">>,
            pageview_months => [<<"2026-06">>],
            pageview_sources => [],
            content_shards => []
        },
        {ok, CatalogMeta} = ecai_wikimedia_catalog:write(
            Dir,
            Catalog,
            #{publish_ipfs => false}
        ),
        SelectionDir = filename:join(Dir, "selection"),
        SelectionPath = filename:join(SelectionDir, "selection.jsonl"),
        SelectionMetaPath = filename:join(SelectionDir, "selection-meta.json"),
        ok = filelib:ensure_dir(SelectionPath),
        ok = file:write_file(SelectionPath, <<>>, [write, raw, binary, sync]),
        ok = file:write_file(
            SelectionMetaPath,
            jsx:encode(#{selected => 0, sha256 => <<"selection-sha">>}),
            [write, raw, binary, sync]
        ),
        IndexDir = filename:join(Dir, "index-input"),
        IndexComplete = filename:join(IndexDir, "COMPLETE.json"),
        ok = filelib:ensure_dir(IndexComplete),
        ok = file:write_file(
            IndexComplete,
            jsx:encode(#{selected_records => 0}),
            [write, raw, binary, sync]
        ),
        {ok, Activity} = ecai_ipfs_activity:open(
            filename:join(Dir, "operator-stream"),
            #{publish_ipfs => false, stream_id => JobId}
        ),
        Ctx = ecai_search:new(),
        Spec = normalized_spec(Dir),
        Runtime = #{
            job_id => JobId,
            work_dir => Dir,
            catalog => Catalog,
            catalog_meta => CatalogMeta,
            selector => #{
                selection_path => SelectionPath,
                selection_meta_path => SelectionMetaPath
            },
            content => #{
                index_dir => IndexDir,
                index_complete_path => IndexComplete
            },
            selection_tab => undefined,
            selection_count => 0,
            activity => Activity,
            ctx => Ctx,
            spec => Spec
        },
        Checkpoint = #{
            stage => done,
            pageview_index => 0,
            partition_index => 0,
            content_index => 0,
            records_indexed => 0
        },
        try
            {ok, Result} = ecai_index_job_wikimedia:result(
                #{id => JobId, spec => Spec},
                Runtime,
                Checkpoint,
                #{}
            ),
            ?assertEqual(wikimedia_visibility, maps:get(kind, Result)),
            SourceIdentity = maps:get(source_identity, Result),
            ?assertEqual(<<"20260720">>, maps:get(cirrus_release, SourceIdentity)),
            ?assertEqual(
                maps:get(sha256, CatalogMeta),
                maps:get(catalog_sha256, SourceIdentity)
            ),
            MaterialFiles = maps:get(material_files, Result),
            MaterialRoles = [maps:get(role, Item) || Item <- MaterialFiles],
            RequiredRoles = [
                source_catalog,
                visibility_selection,
                visibility_selection_meta,
                search_snapshot,
                term_headers
            ],
            lists:foreach(
                fun(Role) ->
                    ?assert(lists:member(Role, MaterialRoles))
                end,
                RequiredRoles
            ),
            ?assert(length(MaterialFiles) >= length(RequiredRoles)),
            ?assertEqual(0, maps:get(records_indexed, Result))
        after
            ok = ecai_search:wipe(Ctx)
        end
    end).

bad_arguments_are_rejected_test() ->
    ?assertEqual(
        {error, badarg},
        ecai_index_job_wikimedia:run_batch(not_a_job, #{}, #{}, 1)
    ),
    ?assertEqual(
        {error, badarg},
        ecai_index_job_wikimedia:run_batch(#{}, #{}, #{}, 0)
    ).

with_runtime(Fun) ->
    with_tmp(fun(Dir) ->
        JobId = <<"wikimedia-job-test">>,
        {ok, Activity} = ecai_ipfs_activity:open(
            filename:join(Dir, "operator-stream"),
            #{
                publish_ipfs => false,
                stream_id => JobId,
                sync_every => 1,
                block_bytes => 1048576
            }
        ),
        Ctx = ecai_search:new(),
        Catalog = #{
            schema => ecai_wikimedia_catalog:version(),
            project => <<"enwiki">>,
            pageview_project => <<"en.wikipedia">>,
            cirrus_release => <<"20260720">>,
            pageview_months => [<<"2026-06">>],
            pageview_sources => [],
            content_shards => []
        },
        SelectorDir = filename:join(Dir, "selection"),
        ContentDir = filename:join(Dir, "content"),
        ok = filelib:ensure_dir(filename:join(SelectorDir, "x")),
        ok = filelib:ensure_dir(filename:join(ContentDir, "x")),
        Selector = #{
            partitions => 0,
            selection_path => filename:join(SelectorDir, "selection.jsonl"),
            selection_meta_path => filename:join(SelectorDir, "selection-meta.json"),
            top_dir => filename:join(SelectorDir, "top"),
            spool_dir => filename:join(SelectorDir, "spool"),
            limit => 1,
            candidate_limit => 1,
            minimum_active_months => 1,
            keep_intermediates => true
        },
        Content = #{
            index_dir => filename:join(ContentDir, "index-input"),
            index_complete_path => filename:join(ContentDir, "index-input/COMPLETE.json"),
            extract_dir => filename:join(ContentDir, "extracted")
        },
        Spec = normalized_spec(Dir),
        Job = #{id => JobId, spec => Spec},
        Runtime = #{
            job_id => JobId,
            work_dir => Dir,
            catalog => Catalog,
            catalog_meta => #{
                path => unicode:characters_to_binary(filename:join(Dir, "catalog.json")),
                sha256 => <<"test-catalog-sha">>,
                cid => null
            },
            selector => Selector,
            content => Content,
            pageview_sources => [],
            content_shards => [],
            selection_tab => undefined,
            selection_count => 0,
            activity => Activity,
            ctx => Ctx,
            spec => Spec
        },
        try
            Fun(Job, Runtime)
        after
            ok = ecai_search:wipe(Ctx)
        end
    end).

normalized_spec(Dir) ->
    Spec0 = #{
        <<"schema">> => <<"ecai-index-job/v1">>,
        <<"kind">> => <<"wikimedia_visibility">>,
        <<"owner">> => <<"test-operator">>,
        <<"source">> => #{
            <<"project">> => <<"enwiki">>,
            <<"pageview_project">> => <<"en.wikipedia">>,
            <<"content_release">> => <<"20260720">>,
            <<"pageview_months">> => [<<"2026-06">>]
        },
        <<"target">> => #{
            <<"index_id">> => <<"wikimedia-test">>,
            <<"namespace">> => <<"org.damagebdd.test.wikimedia">>,
            <<"base_dir">> => unicode:characters_to_binary(Dir),
            <<"mode">> => <<"live_search">>
        },
        <<"options">> => #{
            <<"limit">> => 1,
            <<"minimum_active_months">> => 1,
            <<"selection_shards">> => 8,
            <<"publish_activity_ipfs">> => false
        },
        <<"finalize">> => #{
            <<"build_nft_manifest">> => true,
            <<"publish_ipfs">> => false,
            <<"auto_mint">> => false
        }
    },
    {ok, Spec} = ecai_index_job_codec:normalize_spec(Spec0),
    Spec.

with_tmp(Fun) ->
    Dir = filename:join(
        temp_dir(),
        "ecai-index-job-wikimedia-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    try
        Fun(Dir)
    after
        remove_tree(Dir)
    end.

temp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Value -> Value
    end.

remove_tree(Path) ->
    case file:read_link_info(Path) of
        {ok, Info} when element(3, Info) =:= directory ->
            case file:list_dir(Path) of
                {ok, Names} ->
                    lists:foreach(
                        fun(Name) -> remove_tree(filename:join(Path, Name)) end,
                        Names
                    );
                _ ->
                    ok
            end,
            _ = file:del_dir(Path),
            ok;
        {ok, _Info} ->
            _ = file:delete(Path),
            ok;
        _ ->
            ok
    end.
