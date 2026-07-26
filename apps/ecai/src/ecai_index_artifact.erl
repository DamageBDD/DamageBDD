%%--------------------------------------------------------------------
%% Deterministic index-artifact finalization.
%%
%% The result is an immutable manifest suitable for later NFT minting. Local
%% filesystem paths and timestamps are deliberately excluded from manifest
%% identity. Optional IPFS publication happens before the final manifest is
%% encoded so referenced file CIDs are covered by the manifest hash.
%%--------------------------------------------------------------------
-module(ecai_index_artifact).

-export([finalize/2, nft_metadata/1]).

-define(MANIFEST_SCHEMA, <<"ecai-index-manifest/v1">>).

-spec finalize(map(), map()) -> {ok, map()} | {error, term()}.
finalize(#{id := JobId, spec := Spec} = Job, AdapterResult) ->
    Finalize = maps:get(finalize, Spec),
    case maps:get(build_nft_manifest, Finalize, true) of
        false ->
            {ok, #{ready_to_mint => false, result => AdapterResult}};
        true ->
            try
                OutputDir = artifact_dir(JobId),
                ok = filelib:ensure_dir(filename:join(OutputDir, "x")),
                PublishIpfs = maps:get(publish_ipfs, Finalize, false),
                {Counts, Files0, Logical} = collect_index_material(Job, AdapterResult, OutputDir),
                {ok, Files} = maybe_publish_files(Files0, PublishIpfs),
                SourceIdentity = source_identity(Spec, AdapterResult),
                Target = maps:get(target, Spec),
                PreviousManifestCid = maps:get(
                    previous_manifest_cid,
                    Target,
                    undefined
                ),
                SourceFrontierRoot = crypto:hash(
                    sha256,
                    ecai_index_job_codec:canonical_binary(#{
                        previous_manifest_cid => PreviousManifestCid,
                        source => SourceIdentity
                    })
                ),
                ContentSpec = #{
                    schema => maps:get(schema, Spec),
                    kind => maps:get(kind, Spec),
                    source => SourceIdentity,
                    target => maps:with(
                        [index_id, namespace, mode, previous_manifest_cid],
                        maps:get(target, Spec)
                    ),
                    pipeline => maps:get(pipeline, Spec)
                },
                ContentSpecHash = crypto:hash(
                    sha256,
                    ecai_index_job_codec:canonical_binary(ContentSpec)
                ),
                Identity0 = #{
                    schema => ?MANIFEST_SCHEMA,
                    index_id => maps:get(index_id, maps:get(target, Spec)),
                    namespace => maps:get(namespace, Target),
                    previous_manifest_cid => PreviousManifestCid,
                    source_frontier_root => ecai_index_job_codec:id_hex(
                        SourceFrontierRoot
                    ),
                    content_spec_sha256 => ecai_index_job_codec:id_hex(ContentSpecHash),
                    pipeline => maps:get(pipeline, Spec),
                    kind => maps:get(kind, Spec),
                    source => SourceIdentity,
                    counts => Counts,
                    logical => Logical,
                    files => [identity_file(File) || File <- Files]
                },
                IndexRoot = crypto:hash(
                    sha256,
                    ecai_index_job_codec:canonical_binary(Identity0)
                ),
                Manifest = Identity0#{
                    index_root => ecai_index_job_codec:id_hex(IndexRoot),
                    files => [manifest_file(File) || File <- Files]
                },
                ManifestBytes = ecai_index_job_codec:canonical_binary(Manifest),
                ManifestPath = filename:join(OutputDir, "index-manifest.ecai"),
                ok = atomic_write(ManifestPath, ManifestBytes),
                ManifestSha = crypto:hash(sha256, ManifestBytes),
                ManifestCid = maybe_publish_manifest(
                    ManifestPath,
                    ManifestBytes,
                    ManifestSha,
                    PublishIpfs
                ),
                ReadyToMint = PublishIpfs andalso is_binary(ManifestCid),
                {ok, #{
                    ready_to_mint => ReadyToMint,
                    schema => ?MANIFEST_SCHEMA,
                    manifest_path => unicode:characters_to_binary(ManifestPath),
                    manifest_sha256 => ecai_index_job_codec:id_hex(ManifestSha),
                    manifest_cid => ManifestCid,
                    index_root => ecai_index_job_codec:id_hex(IndexRoot),
                    previous_manifest_cid => PreviousManifestCid,
                    source_frontier_root => ecai_index_job_codec:id_hex(
                        SourceFrontierRoot
                    ),
                    counts => Counts,
                    files => Files,
                    result => AdapterResult
                }}
            catch
                throw:{artifact_error, Reason} ->
                    {error, Reason};
                Class:Reason:Stacktrace ->
                    {error, {artifact_finalize_failed, Class, Reason, Stacktrace}}
            end
    end.

-spec nft_metadata(map()) -> {ok, map()} | {error, term()}.
nft_metadata(#{artifact := Artifact, spec := Spec}) when is_map(Artifact) ->
    case maps:get(ready_to_mint, Artifact, false) of
        true ->
            {ok, #{
                schema => <<"ecai-index-nft/v1">>,
                manifest_cid => maps:get(manifest_cid, Artifact, null),
                manifest_sha256 => maps:get(manifest_sha256, Artifact),
                index_root => maps:get(index_root, Artifact),
                previous_manifest_cid => maps:get(
                    previous_manifest_cid,
                    Artifact,
                    undefined
                ),
                source_frontier_root => maps:get(source_frontier_root, Artifact),
                index_id => maps:get(index_id, maps:get(target, Spec)),
                namespace => maps:get(namespace, maps:get(target, Spec)),
                pipeline => maps:get(pipeline, Spec),
                counts => maps:get(counts, Artifact, #{})
            }};
        false ->
            {error, artifact_not_ready}
    end;
nft_metadata(_Other) ->
    {error, artifact_not_ready}.

source_identity(Spec, AdapterResult) ->
    Kind = maps:get(kind, Spec),
    Source = maps:get(source, Spec),
    case Kind of
        ipfs_cid ->
            Source;
        ipfs_manifest ->
            Source;
        yelp_ndjson ->
            verified_path_source_identity(Source, AdapterResult);
        wikipedia_jsonl ->
            verified_path_source_identity(Source, AdapterResult)
    end.

verified_path_source_identity(Source, AdapterResult) ->
    Paths = maps:get(paths, Source),
    case maps:get(source_identity, AdapterResult, undefined) of
        Expected when is_map(Expected) ->
            case ecai_index_source:verify_paths(Paths, Expected) of
                ok -> Expected;
                {error, Reason} -> artifact_error(Reason)
            end;
        undefined ->
            artifact_error(source_identity_missing);
        _Other ->
            artifact_error(invalid_source_identity)
    end.

collect_index_material(#{spec := Spec}, AdapterResult, OutputDir) ->
    Kind = maps:get(kind, Spec),
    Mode = maps:get(mode, maps:get(target, Spec)),
    case {Kind, Mode} of
        {ipfs_cid, searchable_disk} ->
            collect_disk_index(Spec, AdapterResult);
        {ipfs_manifest, searchable_disk} ->
            collect_disk_index(Spec, AdapterResult);
        {ipfs_cid, ledger_only} ->
            artifact_error(ledger_only_index_is_not_searchable);
        {ipfs_manifest, ledger_only} ->
            artifact_error(ledger_only_index_is_not_searchable);
        {yelp_ndjson, live_search} ->
            collect_live_search(OutputDir, AdapterResult);
        {wikipedia_jsonl, live_search} ->
            collect_live_search(OutputDir, AdapterResult);
        _ ->
            artifact_error({unsupported_artifact_mode, Kind, Mode})
    end.

collect_disk_index(Spec, AdapterResult) ->
    BaseDirBin = maps:get(base_dir, maps:get(target, Spec)),
    BaseDir = path_list(BaseDirBin),
    SegmentPaths = lists:sort(ecai_disk_manifest:list_segments(BaseDir)),
    %% The legacy manifest.term contains absolute local paths, so it must not
    %% participate in a portable NFT identity. The canonical ECAI manifest
    %% below replaces it with content hashes and optional CIDs.
    ExtraPaths = [
        filename:join([BaseDir, "docstore", "ecai_docstore.dets"])
    ],
    Existing = [Path || Path <- SegmentPaths ++ ExtraPaths, filelib:is_regular(Path)],
    case SegmentPaths of
        [] -> artifact_error({no_published_segments, BaseDirBin});
        _ -> ok
    end,
    Files = [file_descriptor(disk_index, Path) || Path <- lists:usort(Existing)],
    Counts = maps:with(
        [documents_indexed, records_indexed, duplicates],
        AdapterResult
    ),
    Logical = #{
        mode => searchable_disk,
        segment_count => length(SegmentPaths)
    },
    {Counts, Files, Logical}.

collect_live_search(OutputDir, AdapterResult) ->
    Ctx =
        try ecai_search_server:get_ctx() of
            undefined -> artifact_error(search_index_not_ready);
            Value -> Value
        catch
            Class:Reason -> artifact_error({search_context_failed, Class, Reason})
        end,
    _ = ecai_search:finalize_roots(Ctx),
    Headers0 = ecai_search:export_onchain_headers(Ctx),
    Headers = [
        Header
     || {_Encoded, Header} <- lists:keysort(
            1,
            [
                {ecai_index_job_codec:canonical_binary(Header), Header}
             || Header <- Headers0
            ]
        )
    ],
    HeaderBytes = ecai_index_job_codec:canonical_binary(Headers),
    HeaderPath = filename:join(OutputDir, "term-headers.ecai"),
    ok = atomic_write(HeaderPath, HeaderBytes),
    Size = ecai_search:size(Ctx),
    Counts = maps:merge(Size, maps:with([records_indexed], AdapterResult)),
    Files = [file_descriptor(term_headers, HeaderPath)],
    Logical = #{
        mode => live_search,
        headers_sha256 => ecai_index_job_codec:id_hex(
            crypto:hash(sha256, HeaderBytes)
        ),
        header_count => length(Headers)
    },
    {Counts, Files, Logical}.

file_descriptor(Role, Path) ->
    case hash_file(Path) of
        {ok, ByteCount, Digest} ->
            #{
                role => Role,
                name => unicode:characters_to_binary(filename:basename(Path)),
                local_path => unicode:characters_to_binary(Path),
                bytes => ByteCount,
                sha256 => ecai_index_job_codec:id_hex(Digest),
                cid => null
            };
        {error, Reason} ->
            artifact_error({artifact_file_read_failed, Path, Reason})
    end.

hash_file(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try
                hash_file_loop(Fd, crypto:hash_init(sha256), 0)
            after
                ok = file:close(Fd)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

hash_file_loop(Fd, Context, ByteCount) ->
    case file:read(Fd, 1048576) of
        eof ->
            {ok, ByteCount, crypto:hash_final(Context)};
        {ok, Chunk} ->
            hash_file_loop(
                Fd,
                crypto:hash_update(Context, Chunk),
                ByteCount + byte_size(Chunk)
            );
        {error, Reason} ->
            {error, Reason}
    end.

maybe_publish_files(Files, false) ->
    {ok, Files};
maybe_publish_files(Files, true) ->
    publish_files(Files, []).

publish_files([], Acc) ->
    {ok, lists:reverse(Acc)};
publish_files([File | Rest], Acc) ->
    Path = path_list(maps:get(local_path, File)),
    case normalize_add_response(damage_ipfs:add({file, Path})) of
        {ok, Cid} -> publish_files(Rest, [File#{cid => Cid} | Acc]);
        {error, Reason} -> artifact_error({ipfs_publish_failed, Path, Reason})
    end.

maybe_publish_manifest(_Path, _Bytes, _Digest, false) ->
    null;
maybe_publish_manifest(Path, Bytes, Digest, true) ->
    case normalize_add_response(damage_ipfs:add({file, Path})) of
        {ok, Cid} ->
            case verify_published_manifest(Cid, Bytes, Digest) of
                ok -> Cid;
                {error, Reason} -> artifact_error({manifest_ipfs_verification_failed, Cid, Reason})
            end;
        {error, Reason} ->
            artifact_error({manifest_ipfs_publish_failed, Reason})
    end.

verify_published_manifest(Cid, ExpectedBytes, ExpectedDigest) ->
    case damage_ipfs:cat_binary(Cid) of
        {ok, ExpectedBytes} ->
            ok;
        {ok, ActualBytes} ->
            ActualDigest = crypto:hash(sha256, ActualBytes),
            {error, {
                content_mismatch,
                ecai_index_job_codec:id_hex(ExpectedDigest),
                ecai_index_job_codec:id_hex(ActualDigest)
            }};
        {error, Reason} ->
            {error, {fetch_failed, Reason}}
    end.

identity_file(File) ->
    %% The semantic index root is independent of local paths and IPFS importer
    %% choices. Publication CIDs remain in the manifest for retrieval, while
    %% role/name/size/content hash define the immutable index contents.
    maps:without([local_path, cid], File).

manifest_file(File) ->
    maps:without([local_path], File).

normalize_add_response({ok, Value}) ->
    normalize_add_response(Value);
normalize_add_response([Value]) ->
    normalize_add_response(Value);
normalize_add_response(#{hash := Value}) ->
    normalize_add_response(Value);
normalize_add_response(#{<<"Hash">> := Value}) ->
    normalize_add_response(Value);
normalize_add_response(#{<<"hash">> := Value}) ->
    normalize_add_response(Value);
normalize_add_response(Bin) when is_binary(Bin), byte_size(Bin) > 0 -> {ok, Bin};
normalize_add_response(List) when is_list(List), List =/= [] ->
    try unicode:characters_to_binary(string:trim(List)) of
        <<>> -> {error, empty_cid};
        Bin -> {ok, Bin}
    catch
        _Class:_Reason -> {error, invalid_cid}
    end;
normalize_add_response({error, _Reason} = Error) ->
    Error;
normalize_add_response(Other) ->
    {error, {invalid_ipfs_add_response, Other}}.

artifact_dir(JobId) ->
    Root0 = application:get_env(
        ecai,
        index_jobs_artifact_dir,
        "/var/lib/damage/ecai/index-job-artifacts"
    ),
    filename:join(path_list(Root0), binary_to_list(JobId)).

atomic_write(Path, Bytes) ->
    Tmp = Path ++ ".tmp",
    case file:open(Tmp, [write, raw, binary]) of
        {ok, Fd} ->
            try
                ok = file:write(Fd, Bytes),
                ok = file:sync(Fd)
            after
                ok = file:close(Fd)
            end,
            ok = file:rename(Tmp, Path);
        {error, Reason} ->
            artifact_error({artifact_write_failed, Path, Reason})
    end.

path_list(Bin) when is_binary(Bin) -> unicode:characters_to_list(Bin);
path_list(List) when is_list(List) -> List.

artifact_error(Reason) ->
    throw({artifact_error, Reason}).
