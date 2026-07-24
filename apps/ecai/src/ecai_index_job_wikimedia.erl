%%--------------------------------------------------------------------
%% Recoverable Wikimedia visibility indexing adapter.
%%
%% The adapter deliberately executes one durable work unit at a time:
%%   catalog -> pageview months -> aggregate partitions -> selection ->
%%   Cirrus shards -> exact top-N normalization -> live-search indexing.
%%
%% Large downloads are resumable, completed work units are marked on disk,
%% and the Step 4A job checkpoint records only boundaries that are safe to
%% repeat. Repeating a unit is idempotent: files are content-addressed or
%% atomically published and live-search writes use stable Wikipedia IDs.
%%--------------------------------------------------------------------
-module(ecai_index_job_wikimedia).
-behaviour(ecai_index_job_adapter).

-export([prepare/1, run_batch/4, result/4]).

-define(PROGRESS_INTERVAL_MS, 2000).

-spec prepare(map()) ->
    {ok, map(), map()} | {error, term()}.
prepare(#{id := JobId, spec := Spec} = Job) ->
    try
        Source = maps:get(source, Spec),
        Target = maps:get(target, Spec),
        Options = maps:get(options, Spec),
        Finalize = maps:get(finalize, Spec),
        BaseDir = path_list(maps:get(base_dir, Target)),
        WorkDir = filename:join([BaseDir, "jobs", binary_to_list(JobId), "wikimedia"]),
        ok = filelib:ensure_dir(filename:join(WorkDir, "x")),
        case ensure_catalog(WorkDir, Source, Finalize) of
            {ok, Catalog, CatalogMeta} ->
                case ecai_wikimedia_selector:prepare(WorkDir, Catalog, Options) of
                    {ok, Selector} ->
                        case ecai_wikimedia_content:prepare(
                            WorkDir,
                            Catalog,
                            Selector,
                            Options
                        ) of
                            {ok, Content} ->
                                case search_context() of
                                    {ok, Ctx0} ->
                                        %% Bulk Wikimedia ingestion shares the search server's
                                        %% ETS tables but defers expensive Merkle-root rebuilds
                                        %% until artifact finalization.
                                        Ctx = ecai_search:set_opts(
                                            Ctx0,
                                            #{root_mode => deferred}
                                        ),
                                        ActivityDir = filename:join(WorkDir, "operator-stream"),
                                        ActivityOpts = #{
                                            publish_ipfs => maps:get(
                                                publish_activity_ipfs,
                                                Options,
                                                true
                                            ),
                                            stream_id => JobId,
                                            block_bytes => application:get_env(
                                                ecai,
                                                wikimedia_activity_block_bytes,
                                                1048576
                                            ),
                                            sync_every => 1
                                        },
                                        case ecai_ipfs_activity:open(ActivityDir, ActivityOpts) of
                                            {ok, Activity0} ->
                                                Checkpoint0 = maps:get(checkpoint, Job, #{}),
                                                RecoveryCheckpoint = recovery_checkpoint(
                                                    Checkpoint0
                                                ),
                                                case maybe_load_selection(
                                                    RecoveryCheckpoint,
                                                    Selector
                                                ) of
                                                    {ok, SelectionTab, SelectionCount} ->
                                                        Runtime = #{
                                                            job_id => JobId,
                                                            work_dir => WorkDir,
                                                            catalog => Catalog,
                                                            catalog_meta => CatalogMeta,
                                                            selector => Selector,
                                                            content => Content,
                                                            pageview_sources => maps:get(
                                                                pageview_sources,
                                                                Catalog
                                                            ),
                                                            content_shards => maps:get(
                                                                content_shards,
                                                                Catalog
                                                            ),
                                                            selection_tab => SelectionTab,
                                                            selection_count => SelectionCount,
                                                            activity => Activity0,
                                                            ctx => Ctx,
                                                            spec => Spec,
                                                            recovery_checkpoint => RecoveryCheckpoint
                                                        },
                                                        {ok,
                                                            Runtime,
                                                            progress(
                                                                Runtime,
                                                                RecoveryCheckpoint
                                                            )};
                                                    {error, _Reason} = Error -> Error
                                                end;
                                            {error, _Reason} = Error -> Error
                                        end;
                                    {error, _Reason} = Error -> Error
                                end;
                            {error, _Reason} = Error -> Error
                        end;
                    {error, _Reason} = Error -> Error
                end;
            {error, _Reason} = Error -> Error
        end
    catch
        error:badarg -> {error, badarg};
        Class:Reason:Stacktrace ->
            {error, {wikimedia_prepare_failed, Class, Reason, Stacktrace}}
    end;
prepare(_Job) ->
    {error, badarg}.

-spec run_batch(map(), map(), map(), pos_integer()) ->
    {continue, map(), map(), map()}
    | {complete, map(), map(), map()}
    | {error, term()}.
run_batch(Job, Runtime0, Checkpoint0, BatchSize) when
    is_map(Job),
    is_map(Runtime0),
    is_map(Checkpoint0),
    is_integer(BatchSize),
    BatchSize > 0
->
    %% prepare/1 may rewind only the live-search indexing stage after a
    %% worker or node restart. Upstream downloads, selection, and normalized
    %% files remain pinned and are not repeated.
    EffectiveCheckpoint = maps:get(
        recovery_checkpoint,
        Runtime0,
        normalize_checkpoint(Checkpoint0)
    ),
    Runtime1 = maps:remove(recovery_checkpoint, Runtime0),
    process_units(Job, Runtime1, EffectiveCheckpoint, BatchSize, 0);
run_batch(_Job, _Runtime, _Checkpoint, _BatchSize) ->
    {error, badarg}.

-spec result(map(), map(), map(), map()) -> {ok, map()} | {error, term()}.
result(_Job, Runtime0, Checkpoint, Result0) ->
    try
        Ctx = maps:get(ctx, Runtime0),
        _ = ecai_search:finalize_roots(Ctx),
        Runtime1 = close_selection(Runtime0),
        case ecai_ipfs_activity:close(maps:get(activity, Runtime1)) of
            {ok, Activity1} ->
                Catalog = maps:get(catalog, Runtime1),
                CatalogMeta = maps:get(catalog_meta, Runtime1),
                Selector = maps:get(selector, Runtime1),
                Content = maps:get(content, Runtime1),
                SelectionMeta = read_json_map(
                    maps:get(selection_meta_path, Selector),
                    #{}
                ),
                ContentMeta = read_json_map(
                    maps:get(index_complete_path, Content),
                    #{}
                ),
                MaterialFiles = material_files(CatalogMeta, Selector, Content),
                SourceIdentity = #{
                    schema => ecai_wikimedia_catalog:version(),
                    project => maps:get(project, Catalog),
                    pageview_project => maps:get(pageview_project, Catalog),
                    cirrus_release => maps:get(cirrus_release, Catalog),
                    pageview_months => maps:get(pageview_months, Catalog),
                    catalog_sha256 => maps:get(sha256, CatalogMeta),
                    catalog_cid => maps:get(cid, CatalogMeta, null),
                    selection_sha256 => field_value(sha256, SelectionMeta, undefined),
                    selected_candidate_count => field_value(
                        selected,
                        SelectionMeta,
                        maps:get(selection_count, Runtime1, 0)
                    )
                },
                SearchSize = ecai_search:size(Ctx),
                RecordsIndexed = maps:get(
                    records_indexed,
                    Checkpoint,
                    field_value(selected_records, ContentMeta, 0)
                ),
                {ok, Result0#{
                    kind => wikimedia_visibility,
                    source_identity => SourceIdentity,
                    catalog => ecai_wikimedia_catalog:summary(Catalog),
                    catalog_meta => CatalogMeta,
                    selection => SelectionMeta,
                    normalized_content => ContentMeta,
                    records_indexed => RecordsIndexed,
                    search_size => SearchSize,
                    material_files => MaterialFiles,
                    activity => ecai_ipfs_activity:status(Activity1),
                    operator_work_dir => unicode:characters_to_binary(
                        maps:get(work_dir, Runtime1)
                    )
                }};
            {error, _Reason} = Error -> Error
        end
    catch
        Class:Reason:Stacktrace ->
            {error, {wikimedia_result_failed, Class, Reason, Stacktrace}}
    end.

process_units(_Job, Runtime, Checkpoint, BatchSize, Processed) when
    Processed >= BatchSize
->
    {continue, Runtime, Checkpoint, progress(Runtime, Checkpoint)};
process_units(Job, Runtime0, Checkpoint0, BatchSize, Processed) ->
    case maps:get(stage, Checkpoint0, catalog) of
        done ->
            {complete, Runtime0, Checkpoint0, final_result(Runtime0, Checkpoint0)};
        Stage ->
            case run_one_unit(Job, Runtime0, Checkpoint0, Stage) of
                {ok, Runtime1, Checkpoint1} ->
                    case maps:get(stage, Checkpoint1, catalog) of
                        done ->
                            {complete,
                                Runtime1,
                                Checkpoint1,
                                final_result(Runtime1, Checkpoint1)};
                        _ ->
                            process_units(
                                Job,
                                Runtime1,
                                Checkpoint1,
                                BatchSize,
                                Processed + 1
                            )
                    end;
                {error, _Reason} = Error -> Error
            end
    end.

run_one_unit(_Job, Runtime0, Checkpoint0, catalog) ->
    Event = #{
        type => source_catalog_pinned,
        catalog => maps:get(catalog_meta, Runtime0),
        summary => ecai_wikimedia_catalog:summary(maps:get(catalog, Runtime0))
    },
    Checkpoint1 = Checkpoint0#{
        stage => pageviews,
        pageview_index => maps:get(pageview_index, Checkpoint0, 0),
        catalog_meta => maps:get(catalog_meta, Runtime0)
    },
    append_activity(Runtime0, Event, Checkpoint1);
run_one_unit(Job, Runtime0, Checkpoint0, pageviews) ->
    Sources = maps:get(pageview_sources, Runtime0),
    Index = maps:get(pageview_index, Checkpoint0, 0),
    case Index >= length(Sources) of
        true ->
            {ok, Runtime0, Checkpoint0#{stage => aggregating, partition_index => 0}};
        false ->
            Source = lists:nth(Index + 1, Sources),
            ProgressFun = live_progress_fun(Job, Runtime0, Checkpoint0),
            case ecai_wikimedia_selector:spool_month(
                maps:get(selector, Runtime0),
                Source,
                Index + 1,
                ProgressFun
            ) of
                {ok, Meta} ->
                    Checkpoint1 = Checkpoint0#{
                        stage => pageviews,
                        pageview_index => Index + 1,
                        current_source => maps:get(name, Source),
                        pageview_rows => maps:get(pageview_rows, Checkpoint0, 0) +
                            integer_value(field_value(project_rows, Meta, 0), 0),
                        pageview_total_views => maps:get(
                            pageview_total_views,
                            Checkpoint0,
                            0
                        ) + integer_value(field_value(total_views, Meta, 0), 0)
                    },
                    append_activity(
                        Runtime0,
                        #{
                            type => pageview_month_complete,
                            month => maps:get(month, Source),
                            source => maps:get(name, Source),
                            project_rows => field_value(project_rows, Meta, 0),
                            total_views => field_value(total_views, Meta, 0)
                        },
                        Checkpoint1
                    );
                {error, Reason} ->
                    {error, {pageview_month_failed, Index + 1, Reason}}
            end
    end;
run_one_unit(Job, Runtime0, Checkpoint0, aggregating) ->
    Selector = maps:get(selector, Runtime0),
    Partition = maps:get(partition_index, Checkpoint0, 0),
    Total = maps:get(partitions, Selector),
    case Partition >= Total of
        true -> {ok, Runtime0, Checkpoint0#{stage => selection}};
        false ->
            ProgressFun = live_progress_fun(Job, Runtime0, Checkpoint0),
            case ecai_wikimedia_selector:aggregate_partition(
                Selector,
                Partition,
                ProgressFun
            ) of
                {ok, Meta} ->
                    Checkpoint1 = Checkpoint0#{
                        stage => aggregating,
                        partition_index => Partition + 1,
                        current_partition => Partition,
                        aggregate_unique_pages => maps:get(
                            aggregate_unique_pages,
                            Checkpoint0,
                            0
                        ) + integer_value(field_value(unique_pages, Meta, 0), 0)
                    },
                    append_activity(
                        Runtime0,
                        #{
                            type => pageview_partition_complete,
                            partition => Partition,
                            unique_pages => field_value(unique_pages, Meta, 0),
                            top_records => field_value(top_records, Meta, 0)
                        },
                        Checkpoint1
                    );
                {error, Reason} ->
                    {error, {pageview_partition_failed, Partition, Reason}}
            end
    end;
run_one_unit(Job, Runtime0, Checkpoint0, selection) ->
    ProgressFun = live_progress_fun(Job, Runtime0, Checkpoint0),
    Selector = maps:get(selector, Runtime0),
    case ecai_wikimedia_selector:merge_selection(Selector, ProgressFun) of
        {ok, Meta} ->
            Runtime1 = close_selection(Runtime0),
            case ecai_wikimedia_selector:load_selection(
                maps:get(selection_path, Selector)
            ) of
                {ok, Tab, Count} ->
                    Runtime2 = Runtime1#{selection_tab => Tab, selection_count => Count},
                    Checkpoint1 = Checkpoint0#{
                        stage => content,
                        content_index => maps:get(content_index, Checkpoint0, 0),
                        selection_count => Count,
                        selection_sha256 => field_value(sha256, Meta, undefined)
                    },
                    append_activity(
                        Runtime2,
                        #{
                            type => visibility_selection_complete,
                            selected_candidates => Count,
                            selection_sha256 => field_value(sha256, Meta, undefined)
                        },
                        Checkpoint1
                    );
                {error, Reason} -> {error, {selection_load_failed, Reason}}
            end;
        {error, Reason} -> {error, {selection_merge_failed, Reason}}
    end;
run_one_unit(Job, Runtime0, Checkpoint0, content) ->
    Shards = maps:get(content_shards, Runtime0),
    Index = maps:get(content_index, Checkpoint0, 0),
    case Index >= length(Shards) of
        true -> {ok, Runtime0, Checkpoint0#{stage => rank_finalize}};
        false ->
            case ensure_selection(Runtime0) of
                {ok, Runtime1, SelectionTab} ->
                    Source = lists:nth(Index + 1, Shards),
                    ProgressFun = live_progress_fun(Job, Runtime1, Checkpoint0),
                    case ecai_wikimedia_content:extract_shard(
                        maps:get(content, Runtime1),
                        Source,
                        SelectionTab,
                        ProgressFun
                    ) of
                        {ok, Meta} ->
                            Checkpoint1 = Checkpoint0#{
                                stage => content,
                                content_index => Index + 1,
                                current_source => maps:get(name, Source),
                                content_candidates_found => maps:get(
                                    content_candidates_found,
                                    Checkpoint0,
                                    0
                                ) + integer_value(field_value(selected, Meta, 0), 0),
                                malformed_records => maps:get(
                                    malformed_records,
                                    Checkpoint0,
                                    0
                                ) + integer_value(field_value(malformed, Meta, 0), 0)
                            },
                            append_activity(
                                Runtime1,
                                #{
                                    type => content_shard_complete,
                                    shard => maps:get(name, Source),
                                    selected => field_value(selected, Meta, 0),
                                    output_sha256 => field_value(
                                        output_sha256,
                                        Meta,
                                        undefined
                                    ),
                                    output_cid => field_value(output_cid, Meta, null)
                                },
                                Checkpoint1
                            );
                        {error, Reason} ->
                            {error, {content_shard_failed, Index + 1, Reason}}
                    end;
                {error, _Reason} = Error -> Error
            end
    end;
run_one_unit(Job, Runtime0, Checkpoint0, rank_finalize) ->
    ProgressFun = live_progress_fun(Job, Runtime0, Checkpoint0),
    case ecai_wikimedia_content:finalize_ranked(
        maps:get(content, Runtime0),
        ProgressFun
    ) of
        {ok, Meta} ->
            Files = ecai_wikimedia_content:index_files(maps:get(content, Runtime0)),
            Checkpoint1 = Checkpoint0#{
                stage => indexing,
                index_file_index => maps:get(index_file_index, Checkpoint0, 0),
                index_file_count => length(Files),
                selected_records => field_value(selected_records, Meta, 0)
            },
            append_activity(
                Runtime0,
                #{
                    type => normalized_corpus_ready,
                    selected_records => field_value(selected_records, Meta, 0),
                    index_files => length(Files)
                },
                Checkpoint1
            );
        {error, Reason} -> {error, {rank_finalize_failed, Reason}}
    end;
run_one_unit(_Job, Runtime0, Checkpoint0, indexing) ->
    Files = ecai_wikimedia_content:index_files(maps:get(content, Runtime0)),
    Index = maps:get(index_file_index, Checkpoint0, 0),
    case Index >= length(Files) of
        true -> {ok, Runtime0, Checkpoint0#{stage => done}};
        false ->
            Path = lists:nth(Index + 1, Files),
            Opts = wikipedia_loader_opts(Runtime0),
            case ecai_wikipedia_loader:load(Path, Opts) of
                ok ->
                    Indexed = count_lines(path_list(Path)),
                    Checkpoint1 = Checkpoint0#{
                        stage => indexing,
                        index_file_index => Index + 1,
                        current_source => Path,
                        records_indexed => maps:get(records_indexed, Checkpoint0, 0) + Indexed
                    },
                    append_activity(
                        Runtime0,
                        #{
                            type => index_file_complete,
                            file => filename:basename(path_list(Path)),
                            records => Indexed
                        },
                        Checkpoint1
                    );
                {error, Reason} -> {error, {search_index_failed, Path, Reason}};
                Other -> {error, {unexpected_wikipedia_loader_result, Path, Other}}
            end
    end;
run_one_unit(_Job, _Runtime, _Checkpoint, Stage) ->
    {error, {unknown_wikimedia_stage, Stage}}.

ensure_catalog(WorkDir, Source, Finalize) ->
    LocalPath = filename:join([WorkDir, "catalog", "wikimedia-catalog.json"]),
    Publish = maps:get(publish_ipfs, Finalize, false),
    case filelib:is_regular(LocalPath) of
        true ->
            case ecai_wikimedia_catalog:read(LocalPath) of
                {ok, Catalog} ->
                    case ecai_wikimedia_catalog:write(
                        WorkDir,
                        Catalog,
                        #{publish_ipfs => Publish}
                    ) of
                        {ok, Meta} -> {ok, Catalog, Meta};
                        {error, _Reason} = Error -> Error
                    end;
                {error, _Reason} = Error -> Error
            end;
        false ->
            case ecai_wikimedia_catalog:resolve(Source) of
                {ok, Catalog} ->
                    case ecai_wikimedia_catalog:write(
                        WorkDir,
                        Catalog,
                        #{publish_ipfs => Publish}
                    ) of
                        {ok, Meta} -> {ok, Catalog, Meta};
                        {error, _Reason} = Error -> Error
                    end;
                {error, _Reason} = Error -> Error
            end
    end.

maybe_load_selection(Checkpoint, Selector) ->
    Stage = maps:get(stage, normalize_checkpoint(Checkpoint), catalog),
    case stage_requires_selection(Stage) andalso
        filelib:is_regular(maps:get(selection_path, Selector))
    of
        true ->
            case ecai_wikimedia_selector:load_selection(
                maps:get(selection_path, Selector)
            ) of
                {ok, Tab, Count} -> {ok, Tab, Count};
                {error, _Reason} = Error -> Error
            end;
        false -> {ok, undefined, 0}
    end.

ensure_selection(Runtime = #{selection_tab := Tab}) when Tab =/= undefined ->
    {ok, Runtime, Tab};
ensure_selection(Runtime) ->
    Selector = maps:get(selector, Runtime),
    case ecai_wikimedia_selector:load_selection(maps:get(selection_path, Selector)) of
        {ok, Tab, Count} ->
            {ok, Runtime#{selection_tab => Tab, selection_count => Count}, Tab};
        {error, _Reason} = Error -> Error
    end.

stage_requires_selection(content) -> true;
stage_requires_selection(rank_finalize) -> true;
stage_requires_selection(indexing) -> true;
stage_requires_selection(done) -> true;
stage_requires_selection(_) -> false.

append_activity(Runtime0, Event, Checkpoint) ->
    Event1 = Event#{
        job_id => maps:get(job_id, Runtime0),
        checkpoint_stage => maps:get(stage, Checkpoint),
        checkpoint => public_checkpoint(Checkpoint)
    },
    case ecai_ipfs_activity:append(maps:get(activity, Runtime0), Event1) of
        {ok, Activity1} -> {ok, Runtime0#{activity => Activity1}, Checkpoint};
        {error, Reason} -> {error, {activity_append_failed, Reason}}
    end.

live_progress_fun(#{id := JobId}, Runtime, Checkpoint) ->
    fun(Delta) ->
        Key = {?MODULE, JobId, last_progress_ms},
        Now = erlang:monotonic_time(millisecond),
        Last = case get(Key) of undefined -> 0; Value -> Value end,
        case Now - Last >= ?PROGRESS_INTERVAL_MS of
            true ->
                put(Key, Now),
                Progress = maps:merge(progress(Runtime, Checkpoint), normalize_progress(Delta)),
                _ = try ecai_index_jobs_srv:checkpoint(JobId, Checkpoint, Progress) of
                    _ -> ok
                catch
                    _:_ -> ok
                end,
                ok;
            false -> ok
        end
    end.

progress(Runtime, Checkpoint) ->
    Stage = maps:get(stage, normalize_checkpoint(Checkpoint), catalog),
    PageviewsDone = maps:get(pageview_index, Checkpoint, 0),
    PageviewsTotal = length(maps:get(pageview_sources, Runtime, [])),
    PartitionsDone = maps:get(partition_index, Checkpoint, 0),
    PartitionsTotal = maps:get(partitions, maps:get(selector, Runtime), 0),
    ContentDone = maps:get(content_index, Checkpoint, 0),
    ContentTotal = length(maps:get(content_shards, Runtime, [])),
    IndexDone = maps:get(index_file_index, Checkpoint, 0),
    IndexTotal = maps:get(index_file_count, Checkpoint, 0),
    Completed = stage_completed_units(
        Stage,
        PageviewsDone,
        PartitionsDone,
        ContentDone,
        IndexDone,
        PageviewsTotal,
        PartitionsTotal,
        ContentTotal
    ),
    Total = PageviewsTotal + PartitionsTotal + ContentTotal + IndexTotal + 3,
    #{
        phase => phase(Stage),
        unit => work_units,
        completed => Completed,
        total => Total,
        pageview_files_completed => PageviewsDone,
        pageview_files_total => PageviewsTotal,
        partitions_completed => PartitionsDone,
        partitions_total => PartitionsTotal,
        content_shards_completed => ContentDone,
        content_shards_total => ContentTotal,
        index_files_completed => IndexDone,
        index_files_total => IndexTotal,
        selection_candidates => maps:get(selection_count, Checkpoint, 0),
        records_indexed => maps:get(records_indexed, Checkpoint, 0),
        current_source => maps:get(current_source, Checkpoint, undefined),
        checkpoint => public_checkpoint(Checkpoint),
        activity => ecai_ipfs_activity:status(maps:get(activity, Runtime))
    }.

stage_completed_units(catalog, _PV, _P, _C, _I, _PVT, _PT, _CT) -> 0;
stage_completed_units(pageviews, PV, _P, _C, _I, _PVT, _PT, _CT) -> 1 + PV;
stage_completed_units(aggregating, _PV, P, _C, _I, PVT, _PT, _CT) -> 1 + PVT + P;
stage_completed_units(selection, _PV, _P, _C, _I, PVT, PT, _CT) -> 1 + PVT + PT;
stage_completed_units(content, _PV, _P, C, _I, PVT, PT, _CT) -> 2 + PVT + PT + C;
stage_completed_units(rank_finalize, _PV, _P, _C, _I, PVT, PT, CT) ->
    2 + PVT + PT + CT;
stage_completed_units(indexing, _PV, _P, _C, I, PVT, PT, CT) ->
    3 + PVT + PT + CT + I;
stage_completed_units(done, _PV, _P, _C, I, PVT, PT, CT) ->
    3 + PVT + PT + CT + I;
stage_completed_units(_, _PV, _P, _C, _I, _PVT, _PT, _CT) -> 0.

phase(catalog) -> resolving_sources;
phase(pageviews) -> selecting_by_pageviews;
phase(aggregating) -> aggregating_pageviews;
phase(selection) -> merging_visibility_selection;
phase(content) -> extracting_selected_articles;
phase(rank_finalize) -> building_normalized_corpus;
phase(indexing) -> indexing_search;
phase(done) -> complete;
phase(Other) -> Other.

final_result(Runtime, Checkpoint) ->
    #{
        kind => wikimedia_visibility,
        sources_indexed => maps:get(content_index, Checkpoint, 0),
        pageview_files_processed => maps:get(pageview_index, Checkpoint, 0),
        partitions_processed => maps:get(partition_index, Checkpoint, 0),
        selected_records => maps:get(selected_records, Checkpoint, 0),
        records_indexed => maps:get(records_indexed, Checkpoint, 0),
        search_size => ecai_search:size(maps:get(ctx, Runtime))
    }.

wikipedia_loader_opts(Runtime) ->
    JobId = maps:get(job_id, Runtime),
    CheckpointDir = filename:join(
        maps:get(work_dir, Runtime),
        filename:join("loader-checkpoints", binary_to_list(JobId))
    ),
    #{
        auto_tune => true,
        %% The normalized files are intentionally small and bounded. Replaying
        %% one file is safer than trusting a loader offset that may be ahead of
        %% the last durable search snapshot after a node restart.
        checkpoint_enabled => false,
        ctx => maps:get(ctx, Runtime),
        mem_profile => application:get_env(
            ecai,
            wikimedia_mem_profile,
            conservative
        ),
        checkpoint_every => application:get_env(
            ecai,
            wikimedia_loader_checkpoint_every,
            100
        ),
        checkpoint_dir => CheckpointDir
    }.

material_files(CatalogMeta, Selector, Content) ->
    Base = [
        #{role => source_catalog, path => maps:get(path, CatalogMeta)},
        #{role => visibility_selection, path => unicode:characters_to_binary(
            maps:get(selection_path, Selector)
        )},
        #{role => visibility_selection_meta, path => unicode:characters_to_binary(
            maps:get(selection_meta_path, Selector)
        )}
    ],
    Base ++ [
        #{role => normalized_records, path => Path}
     || Path <- ecai_wikimedia_content:index_files(Content)
    ].

close_selection(Runtime = #{selection_tab := undefined}) -> Runtime;
close_selection(Runtime = #{selection_tab := Tab}) ->
    _ = ecai_wikimedia_selector:close_selection(Tab),
    Runtime#{selection_tab => undefined}.

search_context() ->
    try ecai_search_server:get_ctx() of
        undefined -> {error, search_index_not_ready};
        Ctx -> {ok, Ctx}
    catch
        Class:Reason -> {error, {search_context_failed, Class, Reason}}
    end.

recovery_checkpoint(Checkpoint0) ->
    Checkpoint = normalize_checkpoint(Checkpoint0),
    case maps:get(stage, Checkpoint, catalog) of
        indexing -> rewind_indexing_checkpoint(Checkpoint);
        done -> rewind_indexing_checkpoint(Checkpoint);
        _ -> Checkpoint
    end.

rewind_indexing_checkpoint(Checkpoint) ->
    maps:without(
        [current_source],
        Checkpoint#{
            stage => indexing,
            index_file_index => 0,
            records_indexed => 0
        }
    ).

normalize_checkpoint(Checkpoint) when map_size(Checkpoint) =:= 0 ->
    #{stage => catalog};
normalize_checkpoint(Checkpoint) -> Checkpoint.

public_checkpoint(Checkpoint) ->
    maps:without([catalog_meta], Checkpoint).

normalize_progress(Map) when is_map(Map) -> Map;
normalize_progress(_Other) -> #{}.

field_value(Key, Map, Default) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> maps:get(atom_to_binary(Key, utf8), Map, Default)
    end;
field_value(_Key, _Map, Default) -> Default.

read_json_map(Path, Default) ->
    case file:read_file(Path) of
        {ok, Bytes} ->
            try jsx:decode(Bytes, [return_maps]) of
                Map when is_map(Map) -> Map;
                _ -> Default
            catch
                _:_ -> Default
            end;
        {error, _Reason} -> Default
    end.

count_lines(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try count_lines_loop(Fd, 0) after ok = file:close(Fd) end;
        {error, _Reason} -> 0
    end.

count_lines_loop(Fd, Count) ->
    case file:read_line(Fd) of
        eof -> Count;
        {ok, _Line} -> count_lines_loop(Fd, Count + 1);
        {error, _Reason} -> Count
    end.

integer_value(Value, _Default) when is_integer(Value) -> Value;
integer_value(Value, _Default) when is_float(Value) -> trunc(Value);
integer_value(_Value, Default) -> Default.

path_list(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    unicode:characters_to_list(Bin);
path_list(List) when is_list(List), List =/= [] -> List;
path_list(_Other) -> erlang:error(badarg).
