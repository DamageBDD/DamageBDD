%%--------------------------------------------------------------------
%% Canonical validation and hashing for ECAI indexing job specifications.
%%
%% The HTTP boundary uses binary keys and values. This module converts those
%% values into a closed internal schema without creating atoms from user input.
%% The canonical encoder is deterministic and is used only for job-spec and
%% artifact identities; it is not Erlang external-term format.
%%--------------------------------------------------------------------
-module(ecai_index_job_codec).

-export([
    version/0,
    normalize_spec/1,
    spec_hash/1,
    canonical_binary/1,
    externalize/1,
    id_hex/1
]).

-define(SCHEMA, <<"ecai-index-job/v1">>).
-define(CANONICAL_VERSION, <<"ecai-canonical-term/v1">>).
-define(DEFAULT_NAMESPACE, <<"org.damagebdd.ecai">>).
-define(DEFAULT_INDEX_ID, <<"global-ecai">>).
-define(MAX_TEXT_BYTES, 1048576).
-define(MAX_PATH_BYTES, 16384).
-define(MAX_PATHS, 1000000).
-define(MAX_RETRIES, 100).
-define(MAX_BATCH_SIZE, 10000).

-spec version() -> binary().
version() ->
    ?SCHEMA.

-spec normalize_spec(map()) -> {ok, map()} | {error, term()}.
normalize_spec(Spec0) when is_map(Spec0) ->
    try
        Schema = optional_binary(schema, field(schema, Spec0, ?SCHEMA)),
        case Schema =:= ?SCHEMA of
            true -> ok;
            false -> validation_error({unsupported_schema, Schema})
        end,
        Kind = normalize_kind(field(kind, Spec0, undefined)),
        Owner = optional_binary(owner, field(owner, Spec0, <<>>)),
        Source0 = required_map(source, field(source, Spec0, undefined)),
        Target0 = optional_map(target, field(target, Spec0, #{})),
        Options0 = optional_map(options, field(options, Spec0, #{})),
        Finalize0 = optional_map(finalize, field(finalize, Spec0, #{})),
        Source = normalize_source(Kind, Source0),
        Target = normalize_target(Kind, Target0),
        Options = normalize_options(Kind, Options0),
        Finalize = normalize_finalize(Finalize0),
        ok = validate_kind_source_options(Kind, Source, Options),
        ok = validate_combination(Kind, Target, Finalize),
        {ok, #{
            schema => ?SCHEMA,
            kind => Kind,
            owner => Owner,
            source => Source,
            target => Target,
            pipeline => #{
                chunker => required_version(ecai_chunker, version),
                terms => required_version(ecai_terms, version),
                event => required_version(ecai_ingest_event, version)
            },
            options => Options,
            finalize => Finalize
        }}
    catch
        throw:{validation_error, Reason} ->
            {error, Reason};
        error:{badkey, Key} ->
            {error, {missing_field, Key}};
        error:badarg ->
            {error, badarg}
    end;
normalize_spec(_Other) ->
    {error, badarg}.

-spec spec_hash(map()) -> {ok, <<_:256>>} | {error, term()}.
spec_hash(Spec0) ->
    case normalize_spec(Spec0) of
        {ok, Spec} ->
            {ok, crypto:hash(sha256, canonical_binary(Spec))};
        {error, _Reason} = Error ->
            Error
    end.

-spec canonical_binary(term()) -> binary().
canonical_binary(Term) ->
    iolist_to_binary([
        <<"ECAI-CANONICAL", 0>>,
        encode_binary(?CANONICAL_VERSION),
        encode(Term)
    ]).

-spec externalize(term()) -> term().
externalize(true) ->
    true;
externalize(false) ->
    false;
externalize(undefined) ->
    null;
externalize(null) ->
    null;
externalize(Value) when is_binary(Value); is_integer(Value); is_float(Value) ->
    Value;
externalize(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
externalize(Map) when is_map(Map) ->
    maps:from_list([
        {external_key(Key), externalize(Value)}
     || {Key, Value} <- maps:to_list(Map)
    ]);
externalize(List) when is_list(List) ->
    [externalize(Value) || Value <- List];
externalize(Tuple) when is_tuple(Tuple) ->
    [externalize(Value) || Value <- tuple_to_list(Tuple)];
externalize(Value) ->
    %% Error reasons can contain PIDs, references, ports, functions, or other
    %% Erlang-only values. Convert those values to bounded printable binaries
    %% so every public job and event remains JSON encodable.
    printable_binary(Value).

-spec id_hex(binary()) -> binary().
id_hex(Bin) when is_binary(Bin) ->
    <<
        <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0F))>>
     || <<Byte:8>> <= Bin
    >>;
id_hex(_Other) ->
    erlang:error(badarg).

normalize_kind(yelp_ndjson) -> yelp_ndjson;
normalize_kind(wikipedia_jsonl) -> wikipedia_jsonl;
normalize_kind(ipfs_cid) -> ipfs_cid;
normalize_kind(ipfs_manifest) -> ipfs_manifest;
normalize_kind(wikimedia_visibility) -> wikimedia_visibility;
normalize_kind(<<"yelp_ndjson">>) -> yelp_ndjson;
normalize_kind(<<"wikipedia_jsonl">>) -> wikipedia_jsonl;
normalize_kind(<<"ipfs_cid">>) -> ipfs_cid;
normalize_kind(<<"ipfs_manifest">>) -> ipfs_manifest;
normalize_kind(<<"wikimedia_visibility">>) -> wikimedia_visibility;
normalize_kind("yelp_ndjson") -> yelp_ndjson;
normalize_kind("wikipedia_jsonl") -> wikipedia_jsonl;
normalize_kind("ipfs_cid") -> ipfs_cid;
normalize_kind("ipfs_manifest") -> ipfs_manifest;
normalize_kind("wikimedia_visibility") -> wikimedia_visibility;
normalize_kind(undefined) -> validation_error({missing_field, kind});
normalize_kind(Other) -> validation_error({unsupported_job_kind, Other}).

normalize_source(yelp_ndjson, Source) ->
    #{paths => normalize_paths(Source)};
normalize_source(wikipedia_jsonl, Source) ->
    #{paths => normalize_paths(Source)};
normalize_source(ipfs_cid, Source) ->
    Cid = required_binary(cid, field(cid, Source, undefined)),
    Title = optional_binary(title, field(title, Source, <<>>)),
    SourceKey = optional_binary(
        source_key,
        field(source_key, Source, <<"ipfs://", Cid/binary>>)
    ),
    #{cid => Cid, title => Title, source_key => SourceKey};
normalize_source(ipfs_manifest, Source) ->
    #{
        manifest_cid => required_binary(
            manifest_cid,
            field(manifest_cid, Source, undefined)
        )
    };
normalize_source(wikimedia_visibility, Source) ->
    Project = token_binary(project, field(project, Source, <<"enwiki">>)),
    PageviewProject = token_binary(
        pageview_project,
        field(pageview_project, Source, <<"en.wikipedia">>)
    ),
    Release = normalize_content_release(
        field(content_release, Source, <<"latest">>)
    ),
    Months = normalize_months(
        field(pageview_months, Source, ecai_wikimedia_catalog:default_months(12))
    ),
    CatalogCid = optional_reference(
        catalog_cid,
        field(catalog_cid, Source, undefined)
    ),
    CatalogPath =
        case field(catalog_path, Source, undefined) of
            undefined -> undefined;
            null -> undefined;
            Value -> optional_path(catalog_path, Value)
        end,
    #{
        project => Project,
        pageview_project => PageviewProject,
        content_release => Release,
        pageview_months => Months,
        catalog_cid => CatalogCid,
        catalog_path => CatalogPath
    }.

normalize_content_release(latest) ->
    <<"latest">>;
normalize_content_release(<<"latest">>) ->
    <<"latest">>;
normalize_content_release("latest") ->
    <<"latest">>;
normalize_content_release(Value) ->
    Release = required_binary(content_release, Value),
    case re:run(Release, <<"^[0-9]{8}$">>, [{capture, none}]) of
        match -> Release;
        _ -> validation_error({invalid_field, content_release, Release})
    end.

normalize_months(Months) when is_list(Months), Months =/= [], length(Months) =< 64 ->
    [normalize_month(Month) || Month <- Months];
normalize_months([]) ->
    validation_error({empty_field, pageview_months});
normalize_months(Months) when is_list(Months) ->
    validation_error({too_many_pageview_months, length(Months), 64});
normalize_months(_Other) ->
    validation_error({invalid_field, pageview_months}).

normalize_month(Value) ->
    Month = required_binary(pageview_month, Value),
    case re:run(Month, <<"^([0-9]{4})-([0-9]{2})$">>, [{capture, [1, 2], binary}]) of
        {match, [YearBin, MonthBin]} ->
            Year = binary_to_integer(YearBin),
            MonthNo = binary_to_integer(MonthBin),
            case Year >= 2015 andalso MonthNo >= 1 andalso MonthNo =< 12 of
                true -> Month;
                false -> validation_error({invalid_month, Month})
            end;
        _ ->
            validation_error({invalid_month, Month})
    end.

token_binary(Name, Value) ->
    Token = required_binary(Name, Value),
    case
        byte_size(Token) =< 128 andalso
            re:run(Token, <<"^[A-Za-z0-9._-]+$">>, [{capture, none}]) =:= match
    of
        true -> Token;
        false -> validation_error({invalid_field, Name})
    end.

normalize_paths(Source) ->
    Paths0 =
        case field(paths, Source, undefined) of
            undefined ->
                case field(path, Source, undefined) of
                    undefined -> validation_error({missing_field, paths});
                    Path -> [Path]
                end;
            Paths when is_list(Paths) -> Paths;
            _Other ->
                validation_error({invalid_field, paths})
        end,
    case length(Paths0) of
        0 -> validation_error({empty_field, paths});
        Count when Count =< ?MAX_PATHS -> ok;
        Count -> validation_error({too_many_paths, Count, ?MAX_PATHS})
    end,
    [normalize_path(Path) || Path <- Paths0].

normalize_target(Kind, Target) ->
    IndexId = optional_binary(index_id, field(index_id, Target, ?DEFAULT_INDEX_ID)),
    Namespace = optional_binary(
        namespace,
        field(namespace, Target, ?DEFAULT_NAMESPACE)
    ),
    BaseDir = optional_path(base_dir, field(base_dir, Target, default_base_dir())),
    Mode = normalize_index_mode(Kind, field(mode, Target, default_mode(Kind))),
    PreviousManifestCid = optional_reference(
        previous_manifest_cid,
        field(previous_manifest_cid, Target, undefined)
    ),
    #{
        index_id => IndexId,
        namespace => Namespace,
        base_dir => BaseDir,
        mode => Mode,
        previous_manifest_cid => PreviousManifestCid
    }.

normalize_options(Kind, Options) ->
    Priority = bounded_integer(
        priority,
        field(priority, Options, 100),
        -1000000,
        1000000
    ),
    MaxRetries = bounded_integer(
        max_retries,
        field(max_retries, Options, 3),
        0,
        ?MAX_RETRIES
    ),
    BatchSize = bounded_integer(
        batch_size,
        field(batch_size, Options, 1),
        1,
        ?MAX_BATCH_SIZE
    ),
    LimitPerChunk = normalize_limit(field(limit_per_chunk, Options, infinity)),
    Base = #{
        priority => Priority,
        max_retries => MaxRetries,
        batch_size => BatchSize,
        limit_per_chunk => LimitPerChunk
    },
    normalize_kind_options(Kind, Options, Base).

normalize_kind_options(wikimedia_visibility, Options, Base) ->
    Base#{
        limit => bounded_integer(
            limit,
            field(limit, Options, 250000),
            1,
            10000000
        ),
        minimum_active_months => bounded_integer(
            minimum_active_months,
            field(minimum_active_months, Options, 6),
            1,
            64
        ),
        selection_shards => bounded_integer(
            selection_shards,
            field(selection_shards, Options, 128),
            8,
            1024
        ),
        oversample_percent => bounded_integer(
            oversample_percent,
            field(oversample_percent, Options, 125),
            100,
            1000
        ),
        partition_buffer_bytes => bounded_integer(
            partition_buffer_bytes,
            field(partition_buffer_bytes, Options, 262144),
            4096,
            16777216
        ),
        abstract_max_bytes => bounded_integer(
            abstract_max_bytes,
            field(abstract_max_bytes, Options, 16384),
            1024,
            16777216
        ),
        cirrus_max_line_bytes => bounded_integer(
            cirrus_max_line_bytes,
            field(cirrus_max_line_bytes, Options, 67108864),
            1048576,
            268435456
        ),
        index_chunk_lines => bounded_integer(
            index_chunk_lines,
            field(index_chunk_lines, Options, 5000),
            100,
            100000
        ),
        keep_downloads => boolean_field(
            keep_downloads,
            field(keep_downloads, Options, false)
        ),
        keep_intermediates => boolean_field(
            keep_intermediates,
            field(keep_intermediates, Options, false)
        ),
        publish_activity_ipfs => boolean_field(
            publish_activity_ipfs,
            field(publish_activity_ipfs, Options, true)
        ),
        publish_extracted_ipfs => boolean_field(
            publish_extracted_ipfs,
            field(publish_extracted_ipfs, Options, false)
        )
    };
normalize_kind_options(_Kind, _Options, Base) ->
    Base.

validate_kind_source_options(wikimedia_visibility, Source, Options) ->
    MonthCount = length(maps:get(pageview_months, Source)),
    MinimumActiveMonths = maps:get(minimum_active_months, Options),
    case MinimumActiveMonths =< MonthCount of
        true ->
            ok;
        false ->
            validation_error({
                minimum_active_months_exceeds_window,
                MinimumActiveMonths,
                MonthCount
            })
    end;
validate_kind_source_options(_Kind, _Source, _Options) ->
    ok.

normalize_finalize(Finalize) ->
    BuildManifest = boolean_field(
        build_nft_manifest,
        field(build_nft_manifest, Finalize, true)
    ),
    PublishIpfs = boolean_field(
        publish_ipfs,
        field(publish_ipfs, Finalize, false)
    ),
    AutoMint = boolean_field(
        auto_mint,
        field(auto_mint, Finalize, false)
    ),
    case AutoMint of
        false ->
            #{
                build_nft_manifest => BuildManifest,
                publish_ipfs => PublishIpfs,
                auto_mint => false
            };
        true ->
            validation_error({unsupported_option, auto_mint, step4b_required})
    end.

validate_combination(_Kind, _Target, #{
    build_nft_manifest := false,
    publish_ipfs := true
}) ->
    validation_error({invalid_finalize_options, publish_requires_manifest});
validate_combination(Kind, #{mode := ledger_only}, #{build_nft_manifest := true}) when
    Kind =:= ipfs_cid;
    Kind =:= ipfs_manifest
->
    validation_error({unsupported_artifact_mode, ledger_only});
validate_combination(_Kind, _Target, _Finalize) ->
    ok.

normalize_index_mode(yelp_ndjson, live_search) -> live_search;
normalize_index_mode(wikipedia_jsonl, live_search) -> live_search;
normalize_index_mode(wikimedia_visibility, live_search) -> live_search;
normalize_index_mode(ipfs_cid, searchable_disk) -> searchable_disk;
normalize_index_mode(ipfs_manifest, searchable_disk) -> searchable_disk;
normalize_index_mode(ipfs_cid, ledger_only) -> ledger_only;
normalize_index_mode(ipfs_manifest, ledger_only) -> ledger_only;
normalize_index_mode(Kind, <<"live_search">>) -> normalize_index_mode(Kind, live_search);
normalize_index_mode(Kind, <<"searchable_disk">>) -> normalize_index_mode(Kind, searchable_disk);
normalize_index_mode(Kind, <<"ledger_only">>) -> normalize_index_mode(Kind, ledger_only);
normalize_index_mode(Kind, "live_search") -> normalize_index_mode(Kind, live_search);
normalize_index_mode(Kind, "searchable_disk") -> normalize_index_mode(Kind, searchable_disk);
normalize_index_mode(Kind, "ledger_only") -> normalize_index_mode(Kind, ledger_only);
normalize_index_mode(Kind, Mode) -> validation_error({invalid_index_mode, Kind, Mode}).

default_mode(yelp_ndjson) -> live_search;
default_mode(wikipedia_jsonl) -> live_search;
default_mode(wikimedia_visibility) -> live_search;
default_mode(ipfs_cid) -> searchable_disk;
default_mode(ipfs_manifest) -> searchable_disk.

default_base_dir() ->
    case application:get_env(ecai, ipfs_index_dir) of
        {ok, Value} -> Value;
        undefined -> <<"/var/lib/damage/ecai/ipfs-index">>
    end.

normalize_limit(infinity) -> infinity;
normalize_limit(<<"infinity">>) -> infinity;
normalize_limit(null) -> infinity;
normalize_limit(Value) when is_integer(Value), Value > 0 -> Value;
normalize_limit(Other) -> validation_error({invalid_field, limit_per_chunk, Other}).

required_map(_Name, Value) when is_map(Value) -> Value;
required_map(Name, undefined) -> validation_error({missing_field, Name});
required_map(Name, _Value) -> validation_error({invalid_field, Name}).

optional_map(_Name, Value) when is_map(Value) -> Value;
optional_map(Name, _Value) -> validation_error({invalid_field, Name}).

required_binary(Name, undefined) ->
    validation_error({missing_field, Name});
required_binary(Name, Value) ->
    Bin = optional_binary(Name, Value),
    case byte_size(Bin) > 0 of
        true -> Bin;
        false -> validation_error({empty_field, Name})
    end.

optional_binary(Name, Value) ->
    Bin = to_binary(Name, Value),
    case byte_size(Bin) =< ?MAX_TEXT_BYTES of
        true -> Bin;
        false -> validation_error({field_too_large, Name, byte_size(Bin)})
    end.

optional_reference(_Name, undefined) -> undefined;
optional_reference(_Name, null) -> undefined;
optional_reference(Name, Value) -> required_binary(Name, Value).

optional_path(Name, Value) ->
    Bin = to_binary(Name, Value),
    case byte_size(Bin) of
        0 -> validation_error({empty_field, Name});
        Size when Size =< ?MAX_PATH_BYTES -> Bin;
        Size -> validation_error({field_too_large, Name, Size})
    end.

normalize_path(#{path := Path}) -> normalize_path(Path);
normalize_path(#{<<"path">> := Path}) -> normalize_path(Path);
normalize_path({Path, _Metadata}) -> normalize_path(Path);
normalize_path(Path) -> optional_path(path, Path).

to_binary(_Name, Bin) when is_binary(Bin) -> Bin;
to_binary(_Name, List) when is_list(List) ->
    case unicode:characters_to_binary(List) of
        Bin when is_binary(Bin) -> Bin;
        _Invalid -> validation_error(invalid_unicode)
    end;
to_binary(Name, _Value) ->
    validation_error({invalid_field, Name}).

bounded_integer(_Name, Value, Min, Max) when
    is_integer(Value), Value >= Min, Value =< Max
->
    Value;
bounded_integer(Name, Value, _Min, _Max) ->
    validation_error({invalid_field, Name, Value}).

boolean_field(_Name, true) -> true;
boolean_field(_Name, false) -> false;
boolean_field(Name, Value) -> validation_error({invalid_field, Name, Value}).

field(Key, Map, Default) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> maps:get(atom_to_binary(Key, utf8), Map, Default)
    end.

required_version(Module, Function) ->
    try apply(Module, Function, []) of
        Bin when is_binary(Bin), byte_size(Bin) > 0 -> Bin;
        Other -> validation_error({invalid_pipeline_version, Module, Function, Other})
    catch
        Class:Reason ->
            validation_error({pipeline_version_unavailable, Module, Function, Class, Reason})
    end.

external_key(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
external_key(Key) when is_binary(Key) -> Key;
external_key(Key) when is_integer(Key) -> integer_to_binary(Key);
external_key(Key) -> printable_binary(Key).

printable_binary(Value) ->
    iolist_to_binary(io_lib:format("~P", [Value, 20])).

encode(undefined) ->
    <<0>>;
encode(null) ->
    <<1>>;
encode(false) ->
    <<2>>;
encode(true) ->
    <<3>>;
encode(Value) when is_integer(Value) ->
    Digits = integer_to_binary(Value),
    [<<4>>, encode_binary(Digits)];
encode(Value) when is_float(Value) ->
    Digits = float_to_binary(Value, [short]),
    [<<5>>, encode_binary(Digits)];
encode(Value) when is_binary(Value) ->
    [<<6>>, encode_binary(Value)];
encode(Value) when is_atom(Value) ->
    [<<7>>, encode_binary(atom_to_binary(Value, utf8))];
encode(Value) when is_list(Value) ->
    [<<8, (length(Value)):32/unsigned-big-integer>>, [encode(Item) || Item <- Value]];
encode(Value) when is_map(Value) ->
    EncodedPairs0 = [
        {iolist_to_binary(encode(Key)), encode(Key), encode(MapValue)}
     || {Key, MapValue} <- maps:to_list(Value)
    ],
    EncodedPairs = lists:keysort(1, EncodedPairs0),
    [
        <<9, (length(EncodedPairs)):32/unsigned-big-integer>>,
        [[EncodedKey, EncodedValue] || {_SortKey, EncodedKey, EncodedValue} <- EncodedPairs]
    ];
encode(Value) when is_tuple(Value) ->
    [<<10>>, encode(tuple_to_list(Value))];
encode(Other) ->
    validation_error({unsupported_canonical_type, Other}).

encode_binary(Bin) ->
    [<<(byte_size(Bin)):64/unsigned-big-integer>>, Bin].

validation_error(Reason) ->
    throw({validation_error, Reason}).

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + (N - 10).
