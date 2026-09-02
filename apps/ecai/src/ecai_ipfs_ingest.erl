%%--------------------------------------------------------------------
%% IPFS source adapter for the durable ECAI ingest writer.
%%
%% Production callers use ingest_live_* or ingest_*_to with the long-lived
%% supervised writer. The BaseDir APIs remain one-shot compatibility wrappers.
%%--------------------------------------------------------------------
-module(ecai_ipfs_ingest).

-export([
    ingest_cid/3,
    ingest_cid/4,
    ingest_cid_result/4,
    ingest_manifest/2,
    ingest_live_cid/2,
    ingest_live_cid/3,
    ingest_live_manifest/1,
    ingest_cid_to/4,
    ingest_manifest_to/2,
    build_records/4,
    build_records/5
]).

-define(CHUNK_SIZE_CODEPOINTS, 1100).
-define(DEFAULT_MAX_SOURCE_CHUNKS, 4096).
-define(DEFAULT_MAX_SOURCE_BYTES, 67108864).
-define(CHUNK_OVERLAP_CODEPOINTS, 140).

%% Backward-compatible one-shot immutable-CID ingest.

%% Backward-compatible one-shot ingest under a stable source key.

%% Backward-compatible one-shot manifest ingest.

%% Use the long-lived writer registered by ecai_ingest_sup.
%% Backward-compatible one-shot immutable-CID ingest. BaseDir APIs retain
%% their historical searchable-disk semantics; durable WAL ingestion uses
%% ingest_live_* and ingest_*_to.

%% Explicit searchable result used by ecai_index_job_ipfs for searchable_disk.

%% Historical one-shot manifest ingest remains searchable and uses one locked
%% index transaction for the whole manifest instead of opening an index per doc.

%% Backward-compatible one-shot immutable-CID ingest. BaseDir APIs retain
%% their historical searchable-disk semantics; durable WAL ingestion uses
%% ingest_live_* and ingest_*_to.
ingest_cid(BaseDir, Cid0, Title0) ->
    try
        Cid = to_bin(Cid0),
        ingest_cid(BaseDir, default_source_key(Cid), Cid, Title0)
    catch
        error:badarg -> {error, invalid_argument}
    end.

ingest_cid(BaseDir, SourceKey0, Cid0, Title0) ->
    case ingest_cid_result(BaseDir, SourceKey0, Cid0, Title0) of
        {ok, _Stats} -> ok;
        {error, _Reason} = Error -> Error
    end.

%% Explicit searchable result used by ecai_index_job_ipfs for searchable_disk.
ingest_cid_result(BaseDir, SourceKey0, Cid0, Title0) ->
    with_searchable_index_lock(BaseDir, fun(AbsoluteBaseDir) ->
        case normalize_source_args(SourceKey0, Cid0, Title0) of
            {ok, SourceKey, Cid, Title} ->
                case fetch_and_build(SourceKey, Cid, Title, configured_max_source_chunks()) of
                    {ok, Records} -> persist_searchable_records(AbsoluteBaseDir, Records);
                    {error, _Reason} = Error -> Error
                end;
            {error, _Reason} = Error ->
                Error
        end
    end).

%% Historical one-shot manifest ingest remains searchable and uses one locked
%% index transaction for the whole manifest instead of opening an index per doc.
ingest_manifest(BaseDir, ManifestCid0) ->
    with_searchable_index_lock(BaseDir, fun(AbsoluteBaseDir) ->
        case normalize_binary(manifest_cid, ManifestCid0) of
            {ok, ManifestCid} ->
                case fetch_ipfs_bytes(ManifestCid) of
                    {ok, ManifestBytes} ->
                        case check_source_size(ManifestBytes) of
                            ok ->
                                case decode_manifest_docs(ManifestBytes) of
                                    {ok, Docs} ->
                                        persist_searchable_manifest(AbsoluteBaseDir, Docs);
                                    {error, _Reason} = Error ->
                                        Error
                                end;
                            {error, _Reason} = Error ->
                                Error
                        end;
                    {error, _Reason} = Error ->
                        Error
                end;
            {error, _Reason} = Error ->
                Error
        end
    end).

persist_searchable_records(BaseDir, Records) ->
    try ecai_disk_indexer:new(BaseDir) of
        Index0 ->
            case safe_add_records(Index0, Records) of
                {ok, Index1} ->
                    case safe_close_index(Index1) of
                        ok ->
                            {ok, #{
                                documents_indexed => 1,
                                records_indexed => length(Records),
                                duplicates => 0
                            }};
                        {error, _Reason} = Error ->
                            Error
                    end;
                {error, _Reason} = Error ->
                    _ = ecai_disk_indexer:abort(Index0),
                    Error
            end
    catch
        Class:Reason:Stacktrace ->
            {error, {searchable_ingest_failed, Class, Reason, Stacktrace}}
    end.

persist_searchable_manifest(BaseDir, Docs) ->
    try ecai_disk_indexer:new(BaseDir) of
        Index0 ->
            case add_manifest_docs_to_index(Index0, Docs, 1, 0) of
                {ok, Index1, _RecordsIndexed} ->
                    safe_close_index(Index1);
                {error, Reason, Index1} ->
                    _ = ecai_disk_indexer:abort(Index1),
                    {error, Reason}
            end
    catch
        Class:Reason:Stacktrace ->
            {error, {searchable_manifest_ingest_failed, Class, Reason, Stacktrace}}
    end.

add_manifest_docs_to_index(Index, [], _Ordinal, RecordsIndexed) ->
    {ok, Index, RecordsIndexed};
add_manifest_docs_to_index(Index0, [Doc | Rest], Ordinal, RecordsIndexed0) when is_map(Doc) ->
    case manifest_doc_fields(Doc) of
        {ok, SourceKey, Cid, Title} ->
            case fetch_and_build(SourceKey, Cid, Title, configured_max_source_chunks()) of
                {ok, Records} ->
                    case safe_add_records(Index0, Records) of
                        {ok, Index1} ->
                            add_manifest_docs_to_index(
                                Index1,
                                Rest,
                                Ordinal + 1,
                                RecordsIndexed0 + length(Records)
                            );
                        {error, Reason} ->
                            {error, {manifest_document_failed, Ordinal, Reason}, Index0}
                    end;
                {error, Reason} ->
                    {error, {manifest_document_failed, Ordinal, Reason}, Index0}
            end;
        {error, Reason} ->
            {error, {invalid_manifest_document, Ordinal, Reason}, Index0}
    end;
add_manifest_docs_to_index(Index, [_Invalid | _], Ordinal, _RecordsIndexed) ->
    {error, {invalid_manifest_document, Ordinal, not_map}, Index}.

safe_add_records(Index, Records) ->
    try ecai_disk_indexer:add_records(Index, Records) of
        Index1 -> {ok, Index1}
    catch
        Class:Reason:Stacktrace ->
            {error, {searchable_ingest_failed, Class, Reason, Stacktrace}}
    end.

safe_close_index(Index) ->
    try ecai_disk_indexer:close(Index) of
        ok -> ok;
        {error, Reason} -> {error, {index_close_failed, Reason}};
        Other -> {error, {unexpected_index_close_result, Other}}
    catch
        Class:Reason:Stacktrace ->
            {error, {index_close_failed, Class, Reason, Stacktrace}}
    end.

with_searchable_index_lock(BaseDir0, Fun) when is_function(Fun, 1) ->
    try
        AbsoluteBaseDir = filename:absname(path_list(BaseDir0)),
        LockId = {{?MODULE, AbsoluteBaseDir}, self()},
        case global:trans(LockId, fun() -> Fun(AbsoluteBaseDir) end) of
            aborted -> {error, searchable_index_lock_aborted};
            Result -> Result
        end
    catch
        error:badarg -> {error, invalid_base_dir}
    end.

ingest_live_cid(Cid0, Title0) ->
    try
        Cid = to_bin(Cid0),
        ingest_live_cid(default_source_key(Cid), Cid, Title0)
    catch
        error:badarg -> {error, invalid_argument}
    end.

ingest_live_cid(SourceKey0, Cid0, Title0) ->
    case ecai_ingest_sup:writer() of
        {ok, Writer} ->
            ingest_cid_to(Writer, SourceKey0, Cid0, Title0);
        {error, _Reason} = Error ->
            Error
    end.

ingest_live_manifest(ManifestCid0) ->
    case ecai_ingest_sup:writer() of
        {ok, Writer} -> ingest_manifest_to(Writer, ManifestCid0);
        {error, _Reason} = Error -> Error
    end.

%% Fetch, deterministically chunk, build validated records, and submit one
%% source version as one durable WAL batch.
ingest_cid_to(Writer, SourceKey0, Cid0, Title0) ->
    case normalize_source_args(SourceKey0, Cid0, Title0) of
        {ok, SourceKey, Cid, Title} ->
            case writer_batch_limit(Writer) of
                {ok, MaxChunks} ->
                    case fetch_and_build(SourceKey, Cid, Title, MaxChunks) of
                        {ok, Records} -> safe_submit_batch(Writer, Records);
                        {error, _Reason} = Error -> Error
                    end;
                {error, _Reason} = Error ->
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

%% Each manifest document is one atomic source-version batch. Step 3 does not
%% make the entire multi-document manifest one transaction.
ingest_manifest_to(Writer, ManifestCid0) ->
    case normalize_binary(manifest_cid, ManifestCid0) of
        {ok, ManifestCid} ->
            case fetch_ipfs_bytes(ManifestCid) of
                {ok, ManifestBytes} ->
                    case check_source_size(ManifestBytes) of
                        ok ->
                            case decode_manifest_docs(ManifestBytes) of
                                {ok, Docs} ->
                                    ingest_manifest_docs(Writer, ManifestCid, Docs, 1, []);
                                {error, _Reason} = Error ->
                                    Error
                            end;
                        {error, _Reason} = Error ->
                            Error
                    end;
                {error, _Reason} = Error ->
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

-spec build_records(binary(), binary(), binary(), binary()) ->
    {ok, [map()]} | {error, term()}.
build_records(SourceKey, Cid, Title, Bin) ->
    build_records(
        SourceKey,
        Cid,
        Title,
        Bin,
        ?DEFAULT_MAX_SOURCE_CHUNKS
    ).

-spec build_records(binary(), binary(), binary(), binary(), pos_integer()) ->
    {ok, [map()]} | {error, term()}.
build_records(SourceKey, Cid, Title, Bin, MaxChunks) when
    is_binary(SourceKey),
    byte_size(SourceKey) > 0,
    is_binary(Cid),
    byte_size(Cid) > 0,
    is_binary(Title),
    is_binary(Bin),
    is_integer(MaxChunks),
    MaxChunks > 0
->
    Result = ecai_chunker:fold_utf8(
        Bin,
        ?CHUNK_SIZE_CODEPOINTS,
        ?CHUNK_OVERLAP_CODEPOINTS,
        fun
            (ChunkInfo, {Count, RecordsRev}) when Count < MaxChunks ->
                case build_record(SourceKey, Cid, Title, ChunkInfo) of
                    {ok, Record} -> {ok, {Count + 1, [Record | RecordsRev]}};
                    {error, _Reason} = Error -> Error
                end;
            (_ChunkInfo, {Count, _RecordsRev}) ->
                {error, {source_chunk_limit_exceeded, Count + 1, MaxChunks}}
        end,
        {0, []}
    ),
    reverse_fold_result(Result);
build_records(_SourceKey, _Cid, _Title, _Bin, _MaxChunks) ->
    {error, badarg}.

build_record(SourceKey, Cid, Title, ChunkInfo) ->
    IndexFields0 = #{
        title => Title,
        heading => <<>>,
        type => <<"ipfs">>,
        tags => []
    },
    case
        ecai_ingest_event:new_upsert_chunk(
            SourceKey,
            Cid,
            ChunkInfo,
            IndexFields0
        )
    of
        {ok, Event} ->
            IndexFields = maps:get(index_fields, Event),
            Record0 = #{
                cid => Cid,
                title => maps:get(title, IndexFields),
                heading => maps:get(heading, IndexFields),
                text => maps:get(text, ChunkInfo),
                type => maps:get(type, IndexFields),
                tags => maps:get(tags, IndexFields),
                chunk_ordinal => maps:get(ordinal, ChunkInfo),
                chunk_byte_start => maps:get(byte_start, ChunkInfo),
                chunk_byte_end => maps:get(byte_end, ChunkInfo),
                chunker => maps:get(chunker, ChunkInfo)
            },
            Record1 = maps:merge(
                Record0,
                ecai_ingest_event:record_fields(Event)
            ),
            ecai_ingest_record:normalize(Record1);
        {error, Reason} ->
            {error, {invalid_ingest_event, Reason}}
    end.

reverse_fold_result({ok, {0, []}}) ->
    {error, empty_source};
reverse_fold_result({ok, {_Count, RecordsRev}}) ->
    {ok, lists:reverse(RecordsRev)};
reverse_fold_result({error, _Reason} = Error) ->
    Error.

fetch_and_build(SourceKey, Cid, Title, MaxChunks) ->
    case fetch_ipfs_bytes(Cid) of
        {ok, Bytes} ->
            case check_source_size(Bytes) of
                ok -> build_records(SourceKey, Cid, Title, Bytes, MaxChunks);
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

fetch_ipfs_bytes(Cid) ->
    case damage_ipfs:cat_binary(Cid) of
        {ok, Bytes} when is_binary(Bytes) -> {ok, Bytes};
        {ok, _Other} -> {error, invalid_ipfs_response};
        {error, Reason} -> {error, {ipfs_fetch_failed, Reason}}
    end.

check_source_size(Bytes) ->
    MaxBytes = configured_max_source_bytes(),
    case byte_size(Bytes) =< MaxBytes of
        true -> ok;
        false -> {error, {source_byte_limit_exceeded, byte_size(Bytes), MaxBytes}}
    end.

decode_manifest_docs(Bytes) ->
    try jsx:decode(Bytes, [return_maps]) of
        Manifest when is_map(Manifest) ->
            case maps:find(<<"docs">>, Manifest) of
                {ok, Docs} when is_list(Docs) -> {ok, Docs};
                {ok, _InvalidDocs} -> {error, manifest_docs_not_list};
                error -> {error, manifest_docs_missing}
            end;
        _ ->
            {error, manifest_not_map}
    catch
        error:Reason -> {error, {invalid_manifest_json, Reason}}
    end.

normalize_source_args(SourceKey0, Cid0, Title0) ->
    case normalize_binary(source_key, SourceKey0) of
        {ok, SourceKey} ->
            case normalize_binary(cid, Cid0) of
                {ok, Cid} ->
                    case normalize_optional_binary(title, Title0) of
                        {ok, Title} -> {ok, SourceKey, Cid, Title};
                        {error, _Reason} = Error -> Error
                    end;
                {error, _Reason} = Error ->
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

normalize_binary(Name, Value) ->
    try to_bin(Value) of
        <<>> -> {error, {empty_field, Name}};
        Bin -> {ok, Bin}
    catch
        error:badarg -> {error, {invalid_field, Name}}
    end.

normalize_optional_binary(Name, Value) ->
    try to_bin(Value) of
        Bin -> {ok, Bin}
    catch
        error:badarg -> {error, {invalid_field, Name}}
    end.

safe_submit_batch(Writer, Records) ->
    try ecai_ingest_writer:submit_batch(Writer, Records) of
        {ok, Ack} when is_map(Ack) -> {ok, Ack};
        {error, _Reason} = Error -> Error;
        Other -> {error, {unexpected_ingest_writer_response, Other}}
    catch
        exit:Reason -> {error, {ingest_writer_unavailable, Reason}};
        Class:Reason:Stacktrace -> {error, {ingest_writer_failed, Class, Reason, Stacktrace}}
    end.

sum_ack_field(Acks, Key) ->
    lists:sum([maps:get(Key, Ack, 0) || Ack <- Acks]).

configured_max_source_chunks() ->
    positive_env(ingest_max_source_chunks, ?DEFAULT_MAX_SOURCE_CHUNKS).

configured_max_source_bytes() ->
    positive_env(ingest_max_source_bytes, ?DEFAULT_MAX_SOURCE_BYTES).

positive_env(Key, Default) ->
    case application:get_env(ecai, Key, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _Invalid -> Default
    end.

ingest_manifest_docs(_Writer, ManifestCid, [], _Ordinal, AcksRev) ->
    Acks = lists:reverse(AcksRev),
    {ok, #{
        manifest_cid => ManifestCid,
        documents => length(Acks),
        submitted => sum_ack_field(Acks, submitted),
        durable_new => sum_ack_field(Acks, durable_new),
        duplicates => sum_ack_field(Acks, duplicates),
        document_acks => Acks
    }};
ingest_manifest_docs(Writer, ManifestCid, [Doc | Rest], Ordinal, AcksRev) when
    is_map(Doc)
->
    case manifest_doc_fields(Doc) of
        {ok, SourceKey, Cid, Title} ->
            case ingest_cid_to(Writer, SourceKey, Cid, Title) of
                {ok, Ack} ->
                    ingest_manifest_docs(
                        Writer,
                        ManifestCid,
                        Rest,
                        Ordinal + 1,
                        [Ack | AcksRev]
                    );
                {error, Reason} ->
                    {error, {manifest_document_failed, Ordinal, Reason}}
            end;
        {error, Reason} ->
            {error, {invalid_manifest_document, Ordinal, Reason}}
    end;
ingest_manifest_docs(_Writer, _ManifestCid, [_Invalid | _], Ordinal, _AcksRev) ->
    {error, {invalid_manifest_document, Ordinal, not_map}}.

manifest_doc_fields(Doc) ->
    case normalize_binary(cid, maps:get(<<"cid">>, Doc, undefined)) of
        {ok, Cid} ->
            case normalize_optional_binary(title, maps:get(<<"title">>, Doc, <<>>)) of
                {ok, Title} ->
                    SourceKey0 = maps:get(<<"source_key">>, Doc, default_source_key(Cid)),
                    case normalize_binary(source_key, SourceKey0) of
                        {ok, SourceKey} -> {ok, SourceKey, Cid, Title};
                        {error, _Reason} = Error -> Error
                    end;
                {error, _Reason} = Error ->
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

path_list(Bin) when is_binary(Bin) ->
    case unicode:characters_to_list(Bin) of
        List when is_list(List) -> List;
        _Invalid -> erlang:error(badarg)
    end;
path_list(List) when is_list(List), List =/= [] ->
    List;
path_list(_Other) ->
    erlang:error(badarg).

writer_batch_limit(Writer) ->
    try ecai_ingest_writer:status(Writer) of
        Status ->
            case maps:get(max_batch_events, Status, undefined) of
                Max when is_integer(Max), Max > 0 -> {ok, Max};
                Invalid -> {error, {invalid_writer_batch_limit, Invalid}}
            end
    catch
        exit:Reason -> {error, {ingest_writer_unavailable, Reason}}
    end.

default_source_key(Cid) ->
    <<"ipfs://", Cid/binary>>.

to_bin(Bin) when is_binary(Bin) -> Bin;
to_bin(List) when is_list(List) -> unicode:characters_to_binary(List);
to_bin(_Other) -> erlang:error(badarg).
