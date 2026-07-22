%%--------------------------------------------------------------------
%% Canonical local storage record and bounded binary codec for one
%% deterministic ECAI ingest event.
%%
%% The event identity is defined by ecai_ingest_event. This module narrows the
%% WAL payload to a fixed, versioned schema. It deliberately does not use
%% term_to_binary/1 or binary_to_term/1.
%%--------------------------------------------------------------------
-module(ecai_ingest_record).

-export([
    format_version/0,
    allowed_fields/0,
    normalize/1,
    event_id/1,
    encode/1,
    encode_with_record/1,
    decode/1
]).

-export_type([ingest_record/0]).

-define(RECORD_MAGIC, <<"ECAIREC1">>).
-define(RECORD_FORMAT_VERSION, 1).
-define(FLAG_NO_CID, 0).
-define(FLAG_CID, 1).

%% 16 MiB
-define(MAX_TEXT_BYTES, 16777216).
%% 1 MiB
-define(MAX_FIELD_BYTES, 1048576).
-define(MAX_SOURCE_ID_BYTES, 4096).
-define(MAX_CHUNKER_BYTES, 256).
-define(MAX_SCHEMA_BYTES, 256).
-define(MAX_TAGS, 256).
-define(MAX_TAG_BYTES, 4096).

-type ingest_record() :: #{
    title := binary(),
    heading := binary(),
    text := binary(),
    tags := [binary()],
    type := binary(),
    chunk_ordinal := pos_integer(),
    chunk_byte_start := non_neg_integer(),
    chunk_byte_end := pos_integer(),
    chunker := binary(),
    event_schema := binary(),
    event_operation := binary(),
    event_pipeline := binary(),
    source_key := binary(),
    source_version := binary(),
    chunk_content_sha256 := <<_:256>>,
    index_fields_sha256 := <<_:256>>,
    chunk_id := <<_:256>>,
    event_id := <<_:256>>,
    cid => binary()
}.

-spec format_version() -> pos_integer().
format_version() ->
    ?RECORD_FORMAT_VERSION.

-spec allowed_fields() -> [atom()].
allowed_fields() ->
    [
        cid,
        title,
        heading,
        text,
        tags,
        type,
        chunk_ordinal,
        chunk_byte_start,
        chunk_byte_end,
        chunker,
        event_schema,
        event_operation,
        event_pipeline,
        source_key,
        source_version,
        chunk_content_sha256,
        index_fields_sha256,
        chunk_id,
        event_id
    ].

-spec normalize(map()) -> {ok, ingest_record()} | {error, term()}.
normalize(Record0) when is_map(Record0) ->
    case unsupported_fields(Record0) of
        [] -> normalize_supported(Record0);
        Unknown -> {error, {unsupported_record_fields, lists:sort(Unknown)}}
    end;
normalize(_Other) ->
    {error, invalid_record}.

-spec event_id(map()) -> {ok, <<_:256>>} | {error, term()}.
event_id(Record) ->
    case normalize(Record) of
        {ok, Normalized} -> {ok, maps:get(event_id, Normalized)};
        {error, _Reason} = Error -> Error
    end.

%% Encode after validating and canonicalizing the record.
-spec encode(map()) -> {ok, binary()} | {error, term()}.
encode(Record0) ->
    case encode_with_record(Record0) of
        {ok, _Record, Encoded} -> {ok, Encoded};
        {error, _Reason} = Error -> Error
    end.

%% The canonical record is returned so callers do not need to normalize it a
%% second time before deriving event IDs or appending a batch.
-spec encode_with_record(map()) ->
    {ok, ingest_record(), binary()} | {error, term()}.
encode_with_record(Record0) ->
    case normalize(Record0) of
        {ok, Record} ->
            {Flags, CidField} =
                case maps:find(cid, Record) of
                    {ok, Cid} -> {?FLAG_CID, encode_binary(Cid)};
                    error -> {?FLAG_NO_CID, []}
                end,
            Tags = maps:get(tags, Record),
            Encoded = iolist_to_binary([
                ?RECORD_MAGIC,
                <<
                    ?RECORD_FORMAT_VERSION:8/unsigned-integer,
                    Flags:8/unsigned-integer,
                    0:16/unsigned-big-integer
                >>,
                encode_binary(maps:get(title, Record)),
                encode_binary(maps:get(heading, Record)),
                encode_binary(maps:get(text, Record)),
                <<(length(Tags)):16/unsigned-big-integer>>,
                [encode_binary(Tag) || Tag <- Tags],
                encode_binary(maps:get(type, Record)),
                <<
                    (maps:get(chunk_ordinal, Record)):64/unsigned-big-integer,
                    (maps:get(chunk_byte_start, Record)):64/unsigned-big-integer,
                    (maps:get(chunk_byte_end, Record)):64/unsigned-big-integer
                >>,
                encode_binary(maps:get(chunker, Record)),
                encode_binary(maps:get(event_schema, Record)),
                encode_binary(maps:get(event_operation, Record)),
                encode_binary(maps:get(event_pipeline, Record)),
                encode_binary(maps:get(source_key, Record)),
                encode_binary(maps:get(source_version, Record)),
                maps:get(chunk_content_sha256, Record),
                maps:get(index_fields_sha256, Record),
                maps:get(chunk_id, Record),
                maps:get(event_id, Record),
                CidField
            ]),
            {ok, Record, Encoded};
        {error, _Reason} = Error ->
            Error
    end.

-spec decode(binary()) -> {ok, ingest_record()} | {error, term()}.
decode(Bin) when is_binary(Bin) ->
    try
        {Flags, Rest0} = decode_header(Bin),
        {Title, Rest1} = take_binary(title, Rest0, ?MAX_FIELD_BYTES),
        {Heading, Rest2} = take_binary(heading, Rest1, ?MAX_FIELD_BYTES),
        {Text, Rest3} = take_binary(text, Rest2, ?MAX_TEXT_BYTES),
        {Tags, Rest4} = take_tags(Rest3),
        {Type, Rest5} = take_binary(type, Rest4, ?MAX_FIELD_BYTES),
        {Ordinal, ByteStart, ByteEnd, Rest6} = take_chunk_numbers(Rest5),
        {Chunker, Rest7} = take_binary(chunker, Rest6, ?MAX_CHUNKER_BYTES),
        {EventSchema, Rest8} = take_binary(
            event_schema,
            Rest7,
            ?MAX_SCHEMA_BYTES
        ),
        {EventOperation, Rest9} = take_binary(
            event_operation,
            Rest8,
            ?MAX_SCHEMA_BYTES
        ),
        {EventPipeline, Rest10} = take_binary(
            event_pipeline,
            Rest9,
            ?MAX_SCHEMA_BYTES
        ),
        {SourceKey, Rest11} = take_binary(
            source_key,
            Rest10,
            ?MAX_SOURCE_ID_BYTES
        ),
        {SourceVersion, Rest12} = take_binary(
            source_version,
            Rest11,
            ?MAX_SOURCE_ID_BYTES
        ),
        {ChunkContentSha256, Rest13} = take_fixed(
            chunk_content_sha256,
            Rest12,
            32
        ),
        {IndexFieldsSha256, Rest14} = take_fixed(
            index_fields_sha256,
            Rest13,
            32
        ),
        {ChunkId, Rest15} = take_fixed(chunk_id, Rest14, 32),
        {EventId, Rest16} = take_fixed(event_id, Rest15, 32),
        {CidValue, Rest17} = take_optional_cid(Flags, Rest16),
        require_empty(Rest17),
        Record0 = #{
            title => Title,
            heading => Heading,
            text => Text,
            tags => Tags,
            type => Type,
            chunk_ordinal => Ordinal,
            chunk_byte_start => ByteStart,
            chunk_byte_end => ByteEnd,
            chunker => Chunker,
            event_schema => EventSchema,
            event_operation => EventOperation,
            event_pipeline => EventPipeline,
            source_key => SourceKey,
            source_version => SourceVersion,
            chunk_content_sha256 => ChunkContentSha256,
            index_fields_sha256 => IndexFieldsSha256,
            chunk_id => ChunkId,
            event_id => EventId
        },
        Record =
            case CidValue of
                none -> Record0;
                {some, Cid} -> Record0#{cid => Cid}
            end,
        case normalize(Record) of
            {ok, Normalized} -> {ok, Normalized};
            {error, Reason} -> {error, {invalid_decoded_record, Reason}}
        end
    catch
        throw:{decode_error, Reason0} ->
            {error, Reason0};
        error:Reason1 ->
            {error, {record_decode_failed, Reason1}}
    end;
decode(_Other) ->
    {error, invalid_record_binary}.

normalize_supported(Record0) ->
    case ecai_ingest_event:verify_record(Record0) of
        ok ->
            case validate_optional_cid(Record0) of
                ok -> {ok, canonical_record(Record0)};
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

canonical_record(Record0) ->
    Record1 = #{
        title => maps:get(title, Record0, <<>>),
        heading => maps:get(heading, Record0, <<>>),
        text => maps:get(text, Record0),
        tags => lists:usort(maps:get(tags, Record0, [])),
        type => maps:get(type, Record0, <<>>),
        chunk_ordinal => maps:get(chunk_ordinal, Record0),
        chunk_byte_start => maps:get(chunk_byte_start, Record0),
        chunk_byte_end => maps:get(chunk_byte_end, Record0),
        chunker => maps:get(chunker, Record0),
        event_schema => maps:get(event_schema, Record0),
        event_operation => maps:get(event_operation, Record0),
        event_pipeline => maps:get(event_pipeline, Record0),
        source_key => maps:get(source_key, Record0),
        source_version => maps:get(source_version, Record0),
        chunk_content_sha256 => maps:get(chunk_content_sha256, Record0),
        index_fields_sha256 => maps:get(index_fields_sha256, Record0),
        chunk_id => maps:get(chunk_id, Record0),
        event_id => maps:get(event_id, Record0)
    },
    case maps:find(cid, Record0) of
        {ok, Cid} -> Record1#{cid => Cid};
        error -> Record1
    end.

validate_optional_cid(Record) ->
    case maps:find(cid, Record) of
        error ->
            case maps:get(type, Record, <<>>) of
                <<"ipfs">> -> {error, missing_ipfs_cid};
                _ -> ok
            end;
        {ok, Cid} when
            is_binary(Cid),
            byte_size(Cid) > 0,
            byte_size(Cid) =< ?MAX_SOURCE_ID_BYTES
        ->
            SourceVersion = maps:get(source_version, Record),
            case Cid =:= SourceVersion of
                true ->
                    ok;
                false ->
                    {error, {
                        cid_source_version_mismatch,
                        Cid,
                        SourceVersion
                    }}
            end;
        {ok, _Invalid} ->
            {error, invalid_cid}
    end.

unsupported_fields(Record) ->
    Allowed = allowed_fields(),
    [Key || Key <- maps:keys(Record), not lists:member(Key, Allowed)].

encode_binary(Bin) ->
    <<(byte_size(Bin)):32/unsigned-big-integer, Bin/binary>>.

decode_header(<<
    Magic:8/binary,
    ?RECORD_FORMAT_VERSION:8/unsigned-integer,
    Flags:8/unsigned-integer,
    0:16/unsigned-big-integer,
    Rest/binary
>>) when
    Magic =:= ?RECORD_MAGIC,
    (Flags =:= ?FLAG_NO_CID orelse Flags =:= ?FLAG_CID)
->
    {Flags, Rest};
decode_header(<<
    Magic:8/binary,
    Version:8/unsigned-integer,
    _/binary
>>) when
    Magic =:= ?RECORD_MAGIC,
    Version =/= ?RECORD_FORMAT_VERSION
->
    decode_error({unsupported_record_version, Version});
decode_header(_Bin) ->
    decode_error(invalid_record_header).

take_binary(_Name, <<Length:32/unsigned-big-integer, Rest/binary>>, MaxBytes) when
    Length =< MaxBytes, byte_size(Rest) >= Length
->
    <<Value:Length/binary, Tail/binary>> = Rest,
    {Value, Tail};
take_binary(Name, <<Length:32/unsigned-big-integer, _/binary>>, MaxBytes) when
    Length > MaxBytes
->
    decode_error({field_too_large, Name, Length, MaxBytes});
take_binary(Name, _Bin, _MaxBytes) ->
    decode_error({truncated_field, Name}).

take_tags(<<Count:16/unsigned-big-integer, Rest/binary>>) when
    Count =< ?MAX_TAGS
->
    take_tags(Count, Rest, []);
take_tags(<<Count:16/unsigned-big-integer, _/binary>>) when
    Count > ?MAX_TAGS
->
    decode_error({too_many_tags, Count, ?MAX_TAGS});
take_tags(_Bin) ->
    decode_error(truncated_tag_count).

take_tags(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
take_tags(Count, Bin, Acc) ->
    {Tag, Rest} = take_binary(tag, Bin, ?MAX_TAG_BYTES),
    take_tags(Count - 1, Rest, [Tag | Acc]).

take_chunk_numbers(<<
    Ordinal:64/unsigned-big-integer,
    ByteStart:64/unsigned-big-integer,
    ByteEnd:64/unsigned-big-integer,
    Rest/binary
>>) ->
    {Ordinal, ByteStart, ByteEnd, Rest};
take_chunk_numbers(_Bin) ->
    decode_error(truncated_chunk_numbers).

take_fixed(_Name, Bin, Bytes) when byte_size(Bin) >= Bytes ->
    <<Value:Bytes/binary, Rest/binary>> = Bin,
    {Value, Rest};
take_fixed(Name, _Bin, _Bytes) ->
    decode_error({truncated_field, Name}).

take_optional_cid(?FLAG_CID, Bin) ->
    {Cid, Rest} = take_binary(cid, Bin, ?MAX_SOURCE_ID_BYTES),
    {{some, Cid}, Rest};
take_optional_cid(?FLAG_NO_CID, Bin) ->
    {none, Bin}.

require_empty(<<>>) ->
    ok;
require_empty(Rest) ->
    decode_error({trailing_record_bytes, byte_size(Rest)}).

decode_error(Reason) ->
    throw({decode_error, Reason}).
