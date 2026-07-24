%%--------------------------------------------------------------------
%% Small operator facade for the Wikimedia visibility pipeline.
%%--------------------------------------------------------------------
-module(ecai_wikimedia_ops).

-export([
    list_sources/0,
    list_sources/1,
    plan/0,
    plan/1,
    genesis_spec/0,
    genesis_spec/1,
    enqueue_genesis/0,
    enqueue_genesis/1,
    status/1,
    list_jobs/0,
    pause/1,
    resume/1,
    cancel/1,
    retry/1,
    search/1,
    search/2,
    doctor/0
]).

-spec list_sources() -> {ok, map()} | {error, term()}.
list_sources() -> list_sources(#{}).

-spec list_sources(map()) -> {ok, map()} | {error, term()}.
list_sources(Opts) -> ecai_wikimedia_catalog:list_sources(Opts).

-spec plan() -> {ok, map()} | {error, term()}.
plan() -> plan(#{}).

-spec plan(map()) -> {ok, map()} | {error, term()}.
plan(Overrides) when is_map(Overrides) ->
    Spec0 = genesis_spec(Overrides),
    case ecai_index_job_codec:normalize_spec(Spec0) of
        {ok, Spec} ->
            Source = maps:get(source, Spec),
            Options = maps:get(options, Spec),
            case ecai_wikimedia_catalog:resolve(Source) of
                {ok, Catalog} ->
                    Limit = maps:get(limit, Options),
                    {ok, #{
                        spec => Spec,
                        catalog => ecai_wikimedia_catalog:summary(Catalog),
                        sources => #{
                            pageviews => maps:get(pageview_sources, Catalog),
                            content_shards => maps:get(content_shards, Catalog)
                        },
                        estimated_work_units => #{
                            pageview_files => length(maps:get(pageview_sources, Catalog)),
                            selection_partitions => maps:get(selection_shards, Options),
                            content_shards => length(maps:get(content_shards, Catalog)),
                            target_records => Limit
                        },
                        operator_notes => [
                            <<"The source catalog is pinned when the job starts.">>,
                            <<"Only one large Wikimedia download is retained at a time by default.">>,
                            <<"Pause and cancel take effect between recoverable work units.">>
                        ]
                    }};
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end;
plan(_Overrides) -> {error, badarg}.

-spec genesis_spec() -> map().
genesis_spec() -> genesis_spec(#{}).

-spec genesis_spec(map()) -> map().
genesis_spec(Overrides) when is_map(Overrides) ->
    Months = maps:get(pageview_months, Overrides, ecai_wikimedia_catalog:default_months(12)),
    Limit = maps:get(limit, Overrides, env_int(wikimedia_genesis_limit, 250000)),
    BaseDir = maps:get(
        base_dir,
        Overrides,
        env_binary(wikimedia_index_dir, <<"/var/lib/damage/ecai/wikimedia/enwiki">>)
    ),
    Owner = maps:get(owner, Overrides, <<>>),
    PublishIpfs = maps:get(publish_ipfs, Overrides, true),
    #{
        <<"schema">> => <<"ecai-index-job/v1">>,
        <<"kind">> => <<"wikimedia_visibility">>,
        <<"owner">> => Owner,
        <<"source">> => #{
            <<"project">> => maps:get(project, Overrides, <<"enwiki">>),
            <<"pageview_project">> => maps:get(
                pageview_project,
                Overrides,
                <<"en.wikipedia">>
            ),
            <<"content_release">> => maps:get(
                content_release,
                Overrides,
                <<"latest">>
            ),
            <<"pageview_months">> => Months
        },
        <<"target">> => #{
            <<"index_id">> => maps:get(
                index_id,
                Overrides,
                <<"ecai-open-knowledge-genesis">>
            ),
            <<"namespace">> => maps:get(
                namespace,
                Overrides,
                <<"org.damagebdd.wikimedia.en">>
            ),
            <<"base_dir">> => BaseDir,
            <<"mode">> => <<"live_search">>,
            <<"previous_manifest_cid">> => maps:get(
                previous_manifest_cid,
                Overrides,
                null
            )
        },
        <<"options">> => #{
            <<"priority">> => maps:get(priority, Overrides, 100),
            <<"max_retries">> => maps:get(max_retries, Overrides, 3),
            <<"batch_size">> => 1,
            <<"limit">> => Limit,
            <<"minimum_active_months">> => maps:get(
                minimum_active_months,
                Overrides,
                6
            ),
            <<"selection_shards">> => maps:get(selection_shards, Overrides, 128),
            <<"oversample_percent">> => maps:get(oversample_percent, Overrides, 125),
            <<"partition_buffer_bytes">> => maps:get(
                partition_buffer_bytes,
                Overrides,
                262144
            ),
            <<"abstract_max_bytes">> => maps:get(abstract_max_bytes, Overrides, 16384),
            <<"cirrus_max_line_bytes">> => maps:get(
                cirrus_max_line_bytes,
                Overrides,
                67108864
            ),
            <<"index_chunk_lines">> => maps:get(index_chunk_lines, Overrides, 5000),
            <<"keep_downloads">> => maps:get(keep_downloads, Overrides, false),
            <<"keep_intermediates">> => maps:get(
                keep_intermediates,
                Overrides,
                false
            ),
            <<"publish_activity_ipfs">> => maps:get(
                publish_activity_ipfs,
                Overrides,
                true
            ),
            <<"publish_extracted_ipfs">> => maps:get(
                publish_extracted_ipfs,
                Overrides,
                false
            )
        },
        <<"finalize">> => #{
            <<"build_nft_manifest">> => true,
            <<"publish_ipfs">> => PublishIpfs,
            <<"auto_mint">> => false
        }
    };
genesis_spec(_Overrides) -> erlang:error(badarg).

-spec enqueue_genesis() -> {ok, map()} | {error, term()}.
enqueue_genesis() -> enqueue_genesis(#{}).

-spec enqueue_genesis(map()) -> {ok, map()} | {error, term()}.
enqueue_genesis(Overrides) when is_map(Overrides) ->
    Spec = genesis_spec(Overrides),
    Key = maps:get(
        idempotency_key,
        Overrides,
        default_idempotency_key(Spec)
    ),
    ecai_index_jobs_srv:enqueue(Spec, #{idempotency_key => Key});
enqueue_genesis(_Overrides) -> {error, badarg}.

status(JobId) -> ecai_index_jobs_srv:get(JobId).
list_jobs() -> ecai_index_jobs_srv:list(#{kind => wikimedia_visibility, limit => 100}).
pause(JobId) -> ecai_index_jobs_srv:pause(JobId).
resume(JobId) -> ecai_index_jobs_srv:resume(JobId).
cancel(JobId) -> ecai_index_jobs_srv:cancel(JobId).
retry(JobId) -> ecai_index_jobs_srv:retry(JobId).
search(Query) -> ecai_wikimedia_search:search(Query).
search(Query, Opts) -> ecai_wikimedia_search:search(Query, Opts).

-spec doctor() -> map().
doctor() ->
    #{
        bzip2 => ecai_bzip2_stream:executable(),
        gun => module_status(gun),
        jsx => module_status(jsx),
        ipfs_pool => process_status(damage_ipfs),
        index_jobs => process_status(ecai_index_jobs_srv),
        search => ecai_wikimedia_search:status(),
        source_catalog => ecai_wikimedia_catalog:list_cirrus_releases(1)
    }.

default_idempotency_key(Spec) ->
    {ok, Hash} = ecai_index_job_codec:spec_hash(Spec),
    <<"wikimedia-genesis-", (ecai_index_job_codec:id_hex(Hash))/binary>>.

module_status(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} -> ready;
        {error, Reason} -> {error, Reason}
    end.

process_status(Name) ->
    case whereis(Name) of
        undefined -> not_running;
        Pid when is_pid(Pid) -> #{running => true, pid => list_to_binary(pid_to_list(Pid))}
    end.

env_int(Key, Default) ->
    case application:get_env(ecai, Key, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _ -> Default
    end.

env_binary(Key, Default) ->
    case application:get_env(ecai, Key, Default) of
        Bin when is_binary(Bin) -> Bin;
        List when is_list(List) -> unicode:characters_to_binary(List);
        _ -> Default
    end.
