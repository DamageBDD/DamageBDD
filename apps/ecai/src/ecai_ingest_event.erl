%%--------------------------------------------------------------------
%% Deterministic identity envelope for ECAI ingest events.
%%
%% This module does not persist or deduplicate events. It defines the
%% byte-stable identity that the next WAL/replay step will use.
%%
%% Identity rules:
%%   * source_key is a stable, globally scoped logical source identity.
%%   * source_version is the immutable version being indexed (an IPFS CID
%%     for the current ingestion path).
%%   * chunk_id identifies one deterministic chunk within that source version.
%%   * event_id also binds index-relevant metadata and the term-pipeline
%%     version, so a replay cannot silently mean different indexed data.
%%--------------------------------------------------------------------
-module(ecai_ingest_event).

-export([
    version/0,
    pipeline_version/0,
    new_upsert_chunk/4,
    record_fields/1,
    verify_record/1,
    id_hex/1
]).

-export_type([event/0]).

-define(EVENT_SCHEMA, <<"ecai-ingest-event/v1">>).
-define(OP_UPSERT_CHUNK, <<"upsert_chunk">>).

-define(CHUNK_ID_DOMAIN, <<"ECAI-CHUNK-ID-V1">>).
-define(INDEX_FIELDS_DOMAIN, <<"ECAI-INDEX-FIELDS-V1">>).
-define(EVENT_ID_DOMAIN, <<"ECAI-EVENT-ID-V1">>).

-define(MAX_U64, 18446744073709551615).
-define(MAX_SOURCE_ID_BYTES, 4096).
-define(MAX_CHUNKER_BYTES, 256).
-define(MAX_TEXT_BYTES, 16777216).
-define(MAX_FIELD_BYTES, 1048576).
-define(MAX_TAGS, 256).
-define(MAX_TAG_BYTES, 4096).

-type event() :: #{
    schema := binary(),
    operation := binary(),
    pipeline := binary(),
    source_key := binary(),
    source_version := binary(),
    chunk := #{
        chunker := binary(),
        ordinal := pos_integer(),
        byte_start := non_neg_integer(),
        byte_end := pos_integer(),
        content_sha256 := <<_:256>>
    },
    index_fields := #{
        title := binary(),
        heading := binary(),
        type := binary(),
        tags := [binary()]
    },
    index_fields_sha256 := <<_:256>>,
    chunk_id := <<_:256>>,
    event_id := <<_:256>>
}.

-spec version() -> binary().
version() ->
    ?EVENT_SCHEMA.

%% This labels the current ecai_terms behavior. Any change that can alter
%% generated lookup terms must publish a new pipeline version.
-spec pipeline_version() -> binary().
pipeline_version() ->
    ecai_terms:version().

-spec new_upsert_chunk(binary(), binary(), map(), map()) ->
    {ok, event()} | {error, term()}.
new_upsert_chunk(SourceKey0, SourceVersion0, Chunk0, IndexFields0) ->
    try
        SourceKey = checked_nonempty_binary(
            source_key,
            SourceKey0,
            ?MAX_SOURCE_ID_BYTES
        ),
        SourceVersion = checked_nonempty_binary(
            source_version,
            SourceVersion0,
            ?MAX_SOURCE_ID_BYTES
        ),
        Chunk = checked_chunk(Chunk0),
        IndexFields = checked_index_fields(IndexFields0),
        build_event(SourceKey, SourceVersion, Chunk, IndexFields)
    catch
        throw:{validation_error, Reason} ->
            {error, Reason};
        error:{badkey, Key} ->
            {error, {missing_field, Key}}
    end.

-spec record_fields(event()) -> map().
record_fields(Event) when is_map(Event) ->
    Chunk = maps:get(chunk, Event),
    #{
        event_schema => maps:get(schema, Event),
        event_operation => maps:get(operation, Event),
        event_pipeline => maps:get(pipeline, Event),
        source_key => maps:get(source_key, Event),
        source_version => maps:get(source_version, Event),
        chunk_content_sha256 => maps:get(content_sha256, Chunk),
        index_fields_sha256 => maps:get(index_fields_sha256, Event),
        chunk_id => maps:get(chunk_id, Event),
        event_id => maps:get(event_id, Event)
    }.

%% Recompute identity from a stored record and compare every persisted
%% identity field. This will be used during recovery and operator verification.
-spec verify_record(map()) -> ok | {error, term()}.
verify_record(Record) when is_map(Record) ->
    try
        Chunk = #{
            chunker => maps:get(chunker, Record),
            ordinal => maps:get(chunk_ordinal, Record),
            byte_start => maps:get(chunk_byte_start, Record),
            byte_end => maps:get(chunk_byte_end, Record),
            text => maps:get(text, Record)
        },
        IndexFields = #{
            title => maps:get(title, Record, <<>>),
            heading => maps:get(heading, Record, <<>>),
            type => maps:get(type, Record, <<>>),
            tags => maps:get(tags, Record, [])
        },
        case
            new_upsert_chunk(
                maps:get(source_key, Record),
                maps:get(source_version, Record),
                Chunk,
                IndexFields
            )
        of
            {ok, Event} ->
                compare_record_fields(record_fields(Event), Record);
            {error, _Reason} = Error ->
                Error
        end
    catch
        error:{badkey, Key} ->
            {error, {missing_field, Key}}
    end;
verify_record(_Other) ->
    {error, badarg}.

-spec id_hex(binary()) -> binary().
id_hex(Bin) when is_binary(Bin) ->
    <<
        <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0F))>>
     || <<Byte:8>> <= Bin
    >>;
id_hex(_Other) ->
    erlang:error(badarg).

build_event(SourceKey, SourceVersion, Chunk, IndexFields) ->
    Text = maps:get(text, Chunk),
    Chunker = maps:get(chunker, Chunk),
    Ordinal = maps:get(ordinal, Chunk),
    ByteStart = maps:get(byte_start, Chunk),
    ByteEnd = maps:get(byte_end, Chunk),
    Pipeline = pipeline_version(),

    ContentSha256 = sha256(Text),
    IndexFieldsSha256 = sha256(
        canonical_index_fields(Pipeline, IndexFields)
    ),
    ChunkId = sha256(
        canonical_chunk_identity(
            SourceKey,
            SourceVersion,
            Chunker,
            Ordinal,
            ByteStart,
            ByteEnd,
            ContentSha256
        )
    ),
    EventId = sha256(
        canonical_event_identity(
            Pipeline,
            SourceKey,
            SourceVersion,
            ChunkId,
            IndexFieldsSha256
        )
    ),

    {ok, #{
        schema => ?EVENT_SCHEMA,
        operation => ?OP_UPSERT_CHUNK,
        pipeline => Pipeline,
        source_key => SourceKey,
        source_version => SourceVersion,
        chunk => #{
            chunker => Chunker,
            ordinal => Ordinal,
            byte_start => ByteStart,
            byte_end => ByteEnd,
            content_sha256 => ContentSha256
        },
        index_fields => IndexFields,
        index_fields_sha256 => IndexFieldsSha256,
        chunk_id => ChunkId,
        event_id => EventId
    }}.

checked_chunk(Chunk) when is_map(Chunk) ->
    Chunker = checked_nonempty_binary(
        chunker,
        maps:get(chunker, Chunk),
        ?MAX_CHUNKER_BYTES
    ),
    Ordinal = checked_positive_u64(ordinal, maps:get(ordinal, Chunk)),
    ByteStart = checked_u64(byte_start, maps:get(byte_start, Chunk)),
    ByteEnd = checked_positive_u64(byte_end, maps:get(byte_end, Chunk)),
    Text = checked_utf8_binary(text, maps:get(text, Chunk), ?MAX_TEXT_BYTES),
    case ByteEnd > ByteStart of
        true -> ok;
        false -> validation_error({invalid_range, ByteStart, ByteEnd})
    end,
    case byte_size(Text) =:= ByteEnd - ByteStart of
        true ->
            ok;
        false ->
            validation_error(
                {
                    byte_range_mismatch,
                    #{
                        byte_start => ByteStart,
                        byte_end => ByteEnd,
                        text_bytes => byte_size(Text)
                    }
                }
            )
    end,
    #{
        chunker => Chunker,
        ordinal => Ordinal,
        byte_start => ByteStart,
        byte_end => ByteEnd,
        text => Text
    };
checked_chunk(_Other) ->
    validation_error({invalid_field, chunk}).

checked_index_fields(Fields) when is_map(Fields) ->
    Title = checked_utf8_binary(
        title,
        maps:get(title, Fields, <<>>),
        ?MAX_FIELD_BYTES
    ),
    Heading = checked_utf8_binary(
        heading,
        maps:get(heading, Fields, <<>>),
        ?MAX_FIELD_BYTES
    ),
    Type = checked_utf8_binary(
        type,
        maps:get(type, Fields, <<>>),
        ?MAX_FIELD_BYTES
    ),
    Tags = checked_tags(maps:get(tags, Fields, [])),
    #{
        title => Title,
        heading => Heading,
        type => Type,
        tags => Tags
    };
checked_index_fields(_Other) ->
    validation_error({invalid_field, index_fields}).

checked_tags(Tags) when is_list(Tags), length(Tags) =< ?MAX_TAGS ->
    %% Tags are set-like identity data. Sorting and de-duplicating prevents
    %% input order from producing a different event identity.
    lists:usort([
        checked_utf8_binary(tag, Tag, ?MAX_TAG_BYTES)
     || Tag <- Tags
    ]);
checked_tags(_Other) ->
    validation_error({invalid_field, tags}).

checked_nonempty_binary(Name, Value, MaxBytes) ->
    Bin = checked_binary(Name, Value, MaxBytes),
    case byte_size(Bin) > 0 of
        true -> Bin;
        false -> validation_error({empty_field, Name})
    end.

checked_binary(_Name, Value, MaxBytes) when
    is_binary(Value), byte_size(Value) =< MaxBytes
->
    Value;
checked_binary(Name, _Value, _MaxBytes) ->
    validation_error({invalid_field, Name}).

checked_utf8_binary(Name, Value, MaxBytes) ->
    Bin = checked_binary(Name, Value, MaxBytes),
    case ecai_chunker:validate_utf8(Bin) of
        ok ->
            Bin;
        {error, {invalid_utf8, Offset}} ->
            validation_error({invalid_utf8, Name, Offset})
    end.

checked_positive_u64(_Name, Value) when
    is_integer(Value), Value > 0, Value =< ?MAX_U64
->
    Value;
checked_positive_u64(Name, _Value) ->
    validation_error({invalid_field, Name}).

checked_u64(_Name, Value) when
    is_integer(Value), Value >= 0, Value =< ?MAX_U64
->
    Value;
checked_u64(Name, _Value) ->
    validation_error({invalid_field, Name}).

canonical_chunk_identity(
    SourceKey,
    SourceVersion,
    Chunker,
    Ordinal,
    ByteStart,
    ByteEnd,
    ContentSha256
) ->
    iolist_to_binary([
        ?CHUNK_ID_DOMAIN,
        <<0>>,
        encode_binary(SourceKey),
        encode_binary(SourceVersion),
        encode_binary(Chunker),
        encode_u64(Ordinal),
        encode_u64(ByteStart),
        encode_u64(ByteEnd),
        ContentSha256
    ]).

canonical_index_fields(Pipeline, Fields) ->
    Tags = maps:get(tags, Fields),
    iolist_to_binary([
        ?INDEX_FIELDS_DOMAIN,
        <<0>>,
        encode_binary(Pipeline),
        encode_binary(maps:get(title, Fields)),
        encode_binary(maps:get(heading, Fields)),
        encode_binary(maps:get(type, Fields)),
        encode_u32(length(Tags)),
        [encode_binary(Tag) || Tag <- Tags]
    ]).

canonical_event_identity(
    Pipeline,
    SourceKey,
    SourceVersion,
    ChunkId,
    IndexFieldsSha256
) ->
    iolist_to_binary([
        ?EVENT_ID_DOMAIN,
        <<0>>,
        encode_binary(?EVENT_SCHEMA),
        encode_binary(?OP_UPSERT_CHUNK),
        encode_binary(Pipeline),
        encode_binary(SourceKey),
        encode_binary(SourceVersion),
        ChunkId,
        IndexFieldsSha256
    ]).

encode_binary(Bin) ->
    [encode_u32(byte_size(Bin)), Bin].

encode_u32(Value) ->
    <<Value:32/unsigned-big-integer>>.

encode_u64(Value) ->
    <<Value:64/unsigned-big-integer>>.

sha256(Data) ->
    crypto:hash(sha256, Data).

compare_record_fields(Expected, Record) ->
    Keys = maps:keys(Expected),
    case
        [
            Key
         || Key <- Keys,
            maps:find(Key, Record) =/= {ok, maps:get(Key, Expected)}
        ]
    of
        [] ->
            ok;
        [FirstMismatch | _] ->
            {error, {identity_mismatch, FirstMismatch}}
    end.

validation_error(Reason) ->
    throw({validation_error, Reason}).

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + (N - 10).
