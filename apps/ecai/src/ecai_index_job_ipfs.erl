-module(ecai_index_job_ipfs).
-behaviour(ecai_index_job_adapter).

-export([prepare/1, run_batch/4, result/4]).

-define(DEFAULT_MAX_MANIFEST_DOCS, 100000).
-define(DEFAULT_MAX_MANIFEST_BYTES, 67108864).

prepare(#{spec := Spec}) ->
    Kind = maps:get(kind, Spec),
    case source_documents(Kind, maps:get(source, Spec)) of
        {ok, Documents, SourceMeta} ->
            {ok,
                #{
                    documents => Documents,
                    total => length(Documents),
                    source_meta => SourceMeta
                },
                #{
                    phase => preparing,
                    unit => documents,
                    completed => 0,
                    total => length(Documents),
                    sources_completed => 0,
                    sources_total => length(Documents),
                    records_indexed => 0,
                    duplicates => 0
                }};
        {error, _Reason} = Error ->
            Error
    end.

run_batch(Job, Runtime, Checkpoint0, BatchSize) ->
    Index0 = maps:get(document_index, Checkpoint0, 0),
    Total = maps:get(total, Runtime),
    case Index0 >= Total of
        true ->
            {complete, Runtime, Checkpoint0, final_result(Job, Runtime, Checkpoint0)};
        false ->
            process_documents(Job, Runtime, Checkpoint0, BatchSize, 0)
    end.

result(_Job, _Runtime, _Checkpoint, Result) ->
    {ok, Result}.

process_documents(_Job, Runtime, Checkpoint, BatchSize, Processed) when
    Processed >= BatchSize
->
    {continue, Runtime, Checkpoint, progress(Runtime, Checkpoint)};
process_documents(Job, Runtime, Checkpoint0, BatchSize, Processed) ->
    Index0 = maps:get(document_index, Checkpoint0, 0),
    Total = maps:get(total, Runtime),
    case Index0 >= Total of
        true ->
            {complete, Runtime, Checkpoint0, final_result(Job, Runtime, Checkpoint0)};
        false ->
            Document = lists:nth(Index0 + 1, maps:get(documents, Runtime)),
            case ingest_document(Job, Document) of
                {ok, Stats} ->
                    Checkpoint1 = Checkpoint0#{
                        document_index => Index0 + 1,
                        current_source => maps:get(cid, Document),
                        documents_indexed =>
                            maps:get(documents_indexed, Checkpoint0, 0) +
                                maps:get(documents_indexed, Stats, 1),
                        records_indexed =>
                            maps:get(records_indexed, Checkpoint0, 0) +
                                maps:get(records_indexed, Stats, 0),
                        duplicates =>
                            maps:get(duplicates, Checkpoint0, 0) +
                                maps:get(duplicates, Stats, 0)
                    },
                    process_documents(
                        Job,
                        Runtime,
                        Checkpoint1,
                        BatchSize,
                        Processed + 1
                    );
                {error, Reason} ->
                    {error, {
                        ipfs_document_failed,
                        Index0 + 1,
                        maps:get(cid, Document),
                        Reason
                    }}
            end
    end.

ingest_document(#{spec := Spec}, Document) ->
    Target = maps:get(target, Spec),
    Mode = maps:get(mode, Target),
    SourceKey = maps:get(source_key, Document),
    Cid = maps:get(cid, Document),
    Title = maps:get(title, Document, <<>>),
    case Mode of
        searchable_disk ->
            BaseDir = maps:get(base_dir, Target),
            case ecai_ipfs_ingest:ingest_cid_result(
                path_list(BaseDir),
                SourceKey,
                Cid,
                Title
            ) of
                {ok, Stats} when is_map(Stats) -> {ok, Stats};
                {error, _Reason} = Error -> Error;
                Other -> {error, {unexpected_searchable_ingest_result, Other}}
            end;
        ledger_only ->
            case ecai_ipfs_ingest:ingest_live_cid(SourceKey, Cid, Title) of
                {ok, Ack} when is_map(Ack) ->
                    {ok, #{
                        records_indexed => maps:get(durable_new, Ack, 0),
                        duplicates => maps:get(duplicates, Ack, 0)
                    }};
                {error, _Reason} = Error -> Error;
                Other -> {error, {unexpected_ledger_ingest_result, Other}}
            end
    end.

source_documents(ipfs_cid, Source) ->
    Cid = maps:get(cid, Source),
    {ok,
        [#{
            cid => Cid,
            source_key => maps:get(source_key, Source, <<"ipfs://", Cid/binary>>),
            title => maps:get(title, Source, <<>>)
        }],
        #{cid => Cid}};
source_documents(ipfs_manifest, Source) ->
    ManifestCid = maps:get(manifest_cid, Source),
    case damage_ipfs:cat_binary(ManifestCid) of
        {ok, Bytes} ->
            case byte_size(Bytes) =< max_manifest_bytes() of
                true -> decode_manifest(ManifestCid, Bytes);
                false ->
                    {error, {
                        manifest_byte_limit_exceeded,
                        byte_size(Bytes),
                        max_manifest_bytes()
                    }}
            end;
        {error, Reason} ->
            {error, {manifest_fetch_failed, ManifestCid, Reason}}
    end.

decode_manifest(ManifestCid, Bytes) ->
    try jsx:decode(Bytes, [return_maps]) of
        Manifest when is_map(Manifest) ->
            case maps:get(<<"docs">>, Manifest, undefined) of
                Documents0 when is_list(Documents0) ->
                    MaxDocs = max_manifest_documents(),
                    case length(Documents0) =< MaxDocs of
                        true ->
                            case normalize_documents(Documents0, 1, []) of
                                {ok, Documents} ->
                                    {ok, Documents, #{manifest_cid => ManifestCid}};
                                {error, _Reason} = Error ->
                                    Error
                            end;
                        false ->
                            {error, {
                                manifest_document_limit_exceeded,
                                length(Documents0),
                                MaxDocs
                            }}
                    end;
                undefined ->
                    {error, manifest_docs_missing};
                _Other ->
                    {error, manifest_docs_not_list}
            end;
        _Other ->
            {error, manifest_not_map}
    catch
        error:Reason -> {error, {invalid_manifest_json, Reason}}
    end.

normalize_documents([], _Ordinal, Acc) ->
    {ok, lists:reverse(Acc)};
normalize_documents([Document0 | Rest], Ordinal, Acc) when is_map(Document0) ->
    case normalize_document(Document0) of
        {ok, Document} ->
            normalize_documents(Rest, Ordinal + 1, [Document | Acc]);
        {error, Reason} ->
            {error, {invalid_manifest_document, Ordinal, Reason}}
    end;
normalize_documents([_Other | _Rest], Ordinal, _Acc) ->
    {error, {invalid_manifest_document, Ordinal, not_map}}.

normalize_document(Document) ->
    case required_binary(cid, maps:get(<<"cid">>, Document, undefined)) of
        {ok, Cid} ->
            case optional_binary(title, maps:get(<<"title">>, Document, <<>>)) of
                {ok, Title} ->
                    SourceKey0 = maps:get(
                        <<"source_key">>,
                        Document,
                        <<"ipfs://", Cid/binary>>
                    ),
                    case required_binary(source_key, SourceKey0) of
                        {ok, SourceKey} ->
                            {ok, #{cid => Cid, source_key => SourceKey, title => Title}};
                        {error, _Reason} = Error -> Error
                    end;
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end.

required_binary(Name, undefined) -> {error, {missing_field, Name}};
required_binary(Name, Value) ->
    case optional_binary(Name, Value) of
        {ok, <<>>} -> {error, {empty_field, Name}};
        {ok, Bin} -> {ok, Bin};
        {error, _Reason} = Error -> Error
    end.

optional_binary(_Name, Bin) when is_binary(Bin) -> {ok, Bin};
optional_binary(Name, List) when is_list(List) ->
    try unicode:characters_to_binary(List) of
        Bin when is_binary(Bin) -> {ok, Bin}
    catch
        _Class:_Reason -> {error, {invalid_field, Name}}
    end;
optional_binary(Name, _Value) -> {error, {invalid_field, Name}}.

progress(Runtime, Checkpoint) ->
    Completed = maps:get(document_index, Checkpoint, 0),
    Total = maps:get(total, Runtime),
    #{
        phase => indexing,
        unit => documents,
        completed => Completed,
        total => Total,
        sources_completed => Completed,
        sources_total => Total,
        current_source => maps:get(current_source, Checkpoint, undefined),
        documents_indexed => maps:get(documents_indexed, Checkpoint, Completed),
        records_indexed => maps:get(records_indexed, Checkpoint, 0),
        duplicates => maps:get(duplicates, Checkpoint, 0)
    }.

final_result(#{spec := Spec}, Runtime, Checkpoint) ->
    Target = maps:get(target, Spec),
    #{
        kind => maps:get(kind, Spec),
        index_mode => maps:get(mode, Target),
        base_dir => maps:get(base_dir, Target),
        documents_indexed => maps:get(
            documents_indexed,
            Checkpoint,
            maps:get(document_index, Checkpoint, 0)
        ),
        records_indexed => maps:get(records_indexed, Checkpoint, 0),
        duplicates => maps:get(duplicates, Checkpoint, 0),
        source_meta => maps:get(source_meta, Runtime)
    }.

max_manifest_documents() ->
    positive_env(index_job_max_manifest_documents, ?DEFAULT_MAX_MANIFEST_DOCS).

max_manifest_bytes() ->
    positive_env(index_job_max_manifest_bytes, ?DEFAULT_MAX_MANIFEST_BYTES).

positive_env(Key, Default) ->
    case application:get_env(ecai, Key, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _Invalid -> Default
    end.

path_list(Bin) when is_binary(Bin) -> unicode:characters_to_list(Bin);
path_list(List) when is_list(List) -> List.
