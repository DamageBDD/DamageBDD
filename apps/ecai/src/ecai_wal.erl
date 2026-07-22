%%--------------------------------------------------------------------
%% Framed, checksummed write-ahead log for ECAI ingest batches.
%%
%% Durability boundary:
%%   batch_begin -> event frames -> batch_commit -> file:sync/1
%%
%% Recovery exposes only complete, structurally valid committed batches. A
%% physically incomplete tail is truncated to the start of its uncommitted
%% batch. Corruption in complete history fails closed.
%%--------------------------------------------------------------------
-module(ecai_wal).

-export([
    format_version/0,
    header_size/0,
    wal_path/1,
    open/1,
    open/2,
    close/1,
    append_batch/2,
    stats/1,
    path/1
]).

-export_type([wal/0, recovery/0]).

-define(MAGIC, <<"ECAIWAL1">>).
-define(FORMAT_VERSION, 1).
-define(TYPE_BATCH_BEGIN, 1).
-define(TYPE_EVENT, 2).
-define(TYPE_BATCH_COMMIT, 3).
-define(HEADER_SIZE, 24).

-define(BATCH_ID_DOMAIN, <<"ECAI-WAL-BATCH-ID-V1">>).

-define(DEFAULT_MAX_BATCH_EVENTS, 4096).
%% 64 MiB
-define(DEFAULT_MAX_BATCH_BYTES, 67108864).
-define(HARD_MAX_BATCH_EVENTS, 65535).
%% 1 GiB
-define(HARD_MAX_BATCH_BYTES, 1073741824).
%% 32 MiB
-define(HARD_MAX_RECORD_BYTES, 33554432).
-define(HARD_MAX_FRAME_PAYLOAD, 33619968).

-record(wal, {
    fd,
    path,
    offset = 0,
    batch_count = 0,
    event_count = 0,
    max_batch_events = ?DEFAULT_MAX_BATCH_EVENTS,
    max_batch_bytes = ?DEFAULT_MAX_BATCH_BYTES
}).

-record(scan, {
    offset = 0,
    pending = none,
    records_rev = [],
    batch_count = 0,
    event_count = 0
}).

-opaque wal() :: #wal{}.
-type recovery() :: #{
    records := [ecai_ingest_record:ingest_record()],
    batch_count := non_neg_integer(),
    event_count := non_neg_integer(),
    repaired_bytes := non_neg_integer(),
    wal_bytes := non_neg_integer(),
    path := file:filename_all()
}.

-spec format_version() -> pos_integer().
format_version() ->
    ?FORMAT_VERSION.

-spec header_size() -> pos_integer().
header_size() ->
    ?HEADER_SIZE.

-spec wal_path(file:filename_all()) -> file:filename_all().
wal_path(BaseDir) ->
    filename:join([path_list(BaseDir), "wal", "ecai-ingest-v1.wal"]).

-spec open(file:filename_all()) ->
    {ok, wal(), recovery()} | {error, term()}.
open(BaseDir) ->
    open(BaseDir, #{}).

-spec open(file:filename_all(), map()) ->
    {ok, wal(), recovery()} | {error, term()}.
open(BaseDir0, Opts) when is_map(Opts) ->
    case {normalize_base_dir(BaseDir0), validate_options(Opts)} of
        {{ok, BaseDir}, {ok, MaxBatchEvents, MaxBatchBytes}} ->
            Path = wal_path(BaseDir),
            case filelib:ensure_dir(Path) of
                ok -> open_path(Path, MaxBatchEvents, MaxBatchBytes);
                {error, Reason} -> {error, {wal_directory_failed, Path, Reason}}
            end;
        {{error, Reason}, _} ->
            {error, Reason};
        {_, {error, _Reason} = Error} ->
            Error
    end;
open(_BaseDir, _Opts) ->
    {error, badarg}.

-spec close(wal()) -> ok | {error, term()}.
close(#wal{fd = Fd}) ->
    file:close(Fd).

-spec path(wal()) -> file:filename_all().
path(#wal{path = Path}) ->
    Path.

-spec stats(wal()) -> map().
stats(#wal{
    path = Path,
    offset = Offset,
    batch_count = BatchCount,
    event_count = EventCount,
    max_batch_events = MaxBatchEvents,
    max_batch_bytes = MaxBatchBytes
}) ->
    #{
        path => Path,
        wal_bytes => Offset,
        batch_count => BatchCount,
        event_count => EventCount,
        max_batch_events => MaxBatchEvents,
        max_batch_bytes => MaxBatchBytes,
        format_version => ?FORMAT_VERSION,
        record_format_version => ecai_ingest_record:format_version()
    }.

-spec append_batch(wal(), [map()]) ->
    {ok, wal(), map()} | {error, term()}.
append_batch(_Wal, []) ->
    {error, empty_batch};
append_batch(
    Wal0 = #wal{
        fd = Fd,
        max_batch_events = MaxBatchEvents,
        max_batch_bytes = MaxBatchBytes
    },
    Records0
) when is_list(Records0) ->
    case prepare_batch(Records0, MaxBatchEvents, MaxBatchBytes) of
        {ok, Prepared} ->
            Frames = maps:get(frames, Prepared),
            Bytes = maps:get(bytes, Prepared),
            case file:position(Fd, eof) of
                {ok, StartOffset} when StartOffset =:= Wal0#wal.offset ->
                    case file:write(Fd, Frames) of
                        ok ->
                            case file:sync(Fd) of
                                ok ->
                                    EndOffset = StartOffset + Bytes,
                                    Count = maps:get(event_count, Prepared),
                                    Wal1 = Wal0#wal{
                                        offset = EndOffset,
                                        batch_count = Wal0#wal.batch_count + 1,
                                        event_count = Wal0#wal.event_count + Count
                                    },
                                    Meta0 = maps:without([frames], Prepared),
                                    Meta = absolute_offsets(Meta0, StartOffset),
                                    {ok, Wal1, Meta};
                                {error, Reason} ->
                                    {error, {wal_sync_failed, Reason}}
                            end;
                        {error, Reason} ->
                            {error, {wal_write_failed, Reason}}
                    end;
                {ok, UnexpectedOffset} ->
                    {error, {
                        wal_size_changed,
                        Wal0#wal.offset,
                        UnexpectedOffset
                    }};
                {error, Reason} ->
                    {error, {wal_position_failed, Reason}}
            end;
        {error, _Reason} = Error ->
            Error
    end;
append_batch(_Wal, _Records) ->
    {error, invalid_batch}.

open_path(Path, MaxBatchEvents, MaxBatchBytes) ->
    case open_read_write(Path) of
        {ok, Fd} ->
            case file:position(Fd, eof) of
                {ok, FileSize} ->
                    finish_open(
                        Fd,
                        Path,
                        FileSize,
                        MaxBatchEvents,
                        MaxBatchBytes
                    );
                {error, Reason} ->
                    _ = file:close(Fd),
                    {error, {wal_size_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {wal_open_failed, Path, Reason}}
    end.

finish_open(Fd, Path, FileSize, MaxBatchEvents, MaxBatchBytes) ->
    case scan_wal(Fd, FileSize) of
        {ok, Records, ScanStats, TruncateAt} ->
            case maybe_truncate_tail(Fd, FileSize, TruncateAt) of
                {ok, FinalSize, RepairedBytes} ->
                    case file:position(Fd, eof) of
                        {ok, FinalSize} ->
                            BatchCount = maps:get(batch_count, ScanStats),
                            EventCount = maps:get(event_count, ScanStats),
                            Wal = #wal{
                                fd = Fd,
                                path = Path,
                                offset = FinalSize,
                                batch_count = BatchCount,
                                event_count = EventCount,
                                max_batch_events = MaxBatchEvents,
                                max_batch_bytes = MaxBatchBytes
                            },
                            Recovery = #{
                                records => Records,
                                batch_count => BatchCount,
                                event_count => EventCount,
                                repaired_bytes => RepairedBytes,
                                wal_bytes => FinalSize,
                                path => Path
                            },
                            {ok, Wal, Recovery};
                        {ok, Unexpected} ->
                            _ = file:close(Fd),
                            {error, {wal_position_mismatch, FinalSize, Unexpected}};
                        {error, Reason} ->
                            _ = file:close(Fd),
                            {error, {wal_position_failed, Reason}}
                    end;
                {error, Reason} ->
                    _ = file:close(Fd),
                    {error, Reason}
            end;
        {error, Reason} ->
            _ = file:close(Fd),
            {error, Reason}
    end.

open_read_write(Path) ->
    case file:open(Path, [raw, binary, read, write]) of
        {ok, _Fd} = Ok ->
            Ok;
        {error, enoent} ->
            case file:write_file(Path, <<>>) of
                ok -> file:open(Path, [raw, binary, read, write]);
                {error, Reason} -> {error, Reason}
            end;
        {error, _Reason} = Error ->
            Error
    end.

normalize_base_dir(BaseDir) when is_binary(BaseDir), byte_size(BaseDir) > 0 ->
    try unicode:characters_to_list(BaseDir) of
        List when is_list(List), List =/= [] ->
            {ok, filename:absname(List)};
        _ ->
            {error, invalid_base_dir}
    catch
        _:_ -> {error, invalid_base_dir}
    end;
normalize_base_dir(BaseDir) when is_list(BaseDir), BaseDir =/= [] ->
    try
        {ok, filename:absname(BaseDir)}
    catch
        _:_ -> {error, invalid_base_dir}
    end;
normalize_base_dir(_Invalid) ->
    {error, invalid_base_dir}.

path_list(Bin) when is_binary(Bin) ->
    unicode:characters_to_list(Bin);
path_list(List) when is_list(List) ->
    List.

validate_options(Opts) ->
    MaxBatchEvents = maps:get(
        max_batch_events,
        Opts,
        ?DEFAULT_MAX_BATCH_EVENTS
    ),
    MaxBatchBytes = maps:get(
        max_batch_bytes,
        Opts,
        ?DEFAULT_MAX_BATCH_BYTES
    ),
    Valid =
        is_integer(MaxBatchEvents) andalso
            MaxBatchEvents > 0 andalso
            MaxBatchEvents =< ?HARD_MAX_BATCH_EVENTS andalso
            is_integer(MaxBatchBytes) andalso
            MaxBatchBytes > 0 andalso
            MaxBatchBytes =< ?HARD_MAX_BATCH_BYTES,
    case Valid of
        true -> {ok, MaxBatchEvents, MaxBatchBytes};
        false -> {error, invalid_wal_options}
    end.

prepare_batch(Records0, MaxBatchEvents, MaxBatchBytes) ->
    Count = length(Records0),
    case Count =< MaxBatchEvents of
        false ->
            {error, {batch_event_limit_exceeded, Count, MaxBatchEvents}};
        true ->
            FixedBatchBytes = 2 * (?HEADER_SIZE + 36),
            case
                prepare_records(
                    Records0,
                    1,
                    #{},
                    [],
                    [],
                    FixedBatchBytes,
                    MaxBatchBytes
                )
            of
                {ok, Records, EncodedRecords} ->
                    build_batch(
                        Records,
                        EncodedRecords,
                        Count,
                        MaxBatchBytes
                    );
                {error, _Reason} = Error ->
                    Error
            end
    end.

prepare_records(
    [],
    _Position,
    _Seen,
    RecordsRev,
    EncodedRev,
    _EstimatedBytes,
    _MaxBatchBytes
) ->
    {ok, lists:reverse(RecordsRev), lists:reverse(EncodedRev)};
prepare_records(
    [Record0 | Rest],
    Position,
    Seen0,
    RecordsRev,
    EncodedRev,
    EstimatedBytes0,
    MaxBatchBytes
) ->
    case ecai_ingest_record:encode_with_record(Record0) of
        {ok, Record, Encoded} when
            byte_size(Encoded) =< ?HARD_MAX_RECORD_BYTES
        ->
            EventId = maps:get(event_id, Record),
            EstimatedBytes1 =
                EstimatedBytes0 + ?HEADER_SIZE + 68 + byte_size(Encoded),
            case EstimatedBytes1 =< MaxBatchBytes of
                false ->
                    {error, {
                        batch_byte_limit_exceeded,
                        EstimatedBytes1,
                        MaxBatchBytes
                    }};
                true ->
                    case maps:is_key(EventId, Seen0) of
                        true ->
                            {error, {
                                duplicate_event_id_in_batch,
                                Position,
                                EventId
                            }};
                        false ->
                            prepare_records(
                                Rest,
                                Position + 1,
                                Seen0#{EventId => true},
                                [Record | RecordsRev],
                                [Encoded | EncodedRev],
                                EstimatedBytes1,
                                MaxBatchBytes
                            )
                    end
            end;
        {ok, _Record, Encoded} ->
            {error, {
                record_byte_limit_exceeded,
                Position,
                byte_size(Encoded),
                ?HARD_MAX_RECORD_BYTES
            }};
        {error, Reason} ->
            {error, {invalid_record, Position, Reason}}
    end.

build_batch(Records, EncodedRecords, Count, MaxBatchBytes) ->
    EventIds = [maps:get(event_id, Record) || Record <- Records],
    BatchId = batch_id(EventIds),
    BeginFrame = frame(
        ?TYPE_BATCH_BEGIN,
        <<BatchId/binary, Count:32/unsigned-big-integer>>
    ),
    EventFrames = [
        event_frame(BatchId, Record, Encoded)
     || {Record, Encoded} <- lists:zip(Records, EncodedRecords)
    ],
    CommitFrame = frame(
        ?TYPE_BATCH_COMMIT,
        <<BatchId/binary, Count:32/unsigned-big-integer>>
    ),
    Frames = [BeginFrame, EventFrames, CommitFrame],
    Bytes = iolist_size(Frames),
    case Bytes =< MaxBatchBytes of
        true ->
            BeginBytes = byte_size(BeginFrame),
            EventSizes = [byte_size(EventFrame) || EventFrame <- EventFrames],
            EventOffsets = relative_offsets(EventSizes, BeginBytes, []),
            CommitOffset = BeginBytes + lists:sum(EventSizes),
            {ok, #{
                batch_id => BatchId,
                event_count => Count,
                bytes => Bytes,
                batch_start => 0,
                batch_end => Bytes,
                event_frame_offsets => EventOffsets,
                commit_offset => CommitOffset,
                frames => Frames
            }};
        false ->
            {error, {batch_byte_limit_exceeded, Bytes, MaxBatchBytes}}
    end.

event_frame(BatchId, Record, Encoded) ->
    EventId = maps:get(event_id, Record),
    RecordBytes = byte_size(Encoded),
    Payload = <<
        BatchId/binary,
        EventId/binary,
        RecordBytes:32/unsigned-big-integer,
        Encoded/binary
    >>,
    frame(?TYPE_EVENT, Payload).

frame(Type, Payload) ->
    PayloadBytes = byte_size(Payload),
    HeaderPrefix = <<
        ?MAGIC/binary,
        ?FORMAT_VERSION:8/unsigned-integer,
        Type:8/unsigned-integer,
        0:16/unsigned-big-integer,
        PayloadBytes:32/unsigned-big-integer
    >>,
    HeaderCrc32 = erlang:crc32(HeaderPrefix),
    PayloadCrc32 = erlang:crc32(Payload),
    <<
        HeaderPrefix/binary,
        HeaderCrc32:32/unsigned-big-integer,
        PayloadCrc32:32/unsigned-big-integer,
        Payload/binary
    >>.

batch_id(EventIds) ->
    Count = length(EventIds),
    crypto:hash(
        sha256,
        [?BATCH_ID_DOMAIN, <<0, Count:32/unsigned-big-integer>>, EventIds]
    ).

relative_offsets([], _Current, Acc) ->
    lists:reverse(Acc);
relative_offsets([Size | Rest], Current, Acc) ->
    relative_offsets(Rest, Current + Size, [Current | Acc]).

absolute_offsets(Meta0, StartOffset) ->
    Meta0#{
        batch_start => StartOffset,
        batch_end => StartOffset + maps:get(batch_end, Meta0),
        commit_offset => StartOffset + maps:get(commit_offset, Meta0),
        event_frame_offsets => [
            StartOffset + Offset
         || Offset <- maps:get(event_frame_offsets, Meta0)
        ]
    }.

scan_wal(Fd, FileSize) ->
    scan_next(Fd, FileSize, #scan{}).

scan_next(_Fd, FileSize, Scan = #scan{offset = FileSize, pending = none}) ->
    finish_scan(Scan, FileSize);
scan_next(_Fd, FileSize, Scan = #scan{offset = FileSize, pending = Pending}) when
    Pending =/= none
->
    finish_scan(Scan, maps:get(start_offset, Pending));
scan_next(_Fd, FileSize, Scan = #scan{offset = Offset}) when
    FileSize - Offset < ?HEADER_SIZE
->
    finish_scan(Scan, truncate_start(Scan));
scan_next(Fd, FileSize, Scan = #scan{offset = Offset}) ->
    case file:pread(Fd, Offset, ?HEADER_SIZE) of
        {ok, Header} when byte_size(Header) =:= ?HEADER_SIZE ->
            scan_header(Fd, FileSize, Scan, Header);
        eof ->
            finish_scan(Scan, truncate_start(Scan));
        {ok, _ShortHeader} ->
            finish_scan(Scan, truncate_start(Scan));
        {error, Reason} ->
            {error, {wal_read_failed, Offset, Reason}}
    end.

scan_header(Fd, FileSize, Scan = #scan{offset = Offset}, Header) ->
    case parse_header(Header) of
        {ok, Type, PayloadBytes, ExpectedPayloadCrc32} ->
            FrameEnd = Offset + ?HEADER_SIZE + PayloadBytes,
            case PayloadBytes =< ?HARD_MAX_FRAME_PAYLOAD of
                false ->
                    corrupt(Offset, {frame_too_large, PayloadBytes});
                true when FrameEnd > FileSize ->
                    finish_scan(Scan, truncate_start(Scan));
                true ->
                    read_and_handle_frame(
                        Fd,
                        FileSize,
                        Scan,
                        Type,
                        PayloadBytes,
                        ExpectedPayloadCrc32,
                        FrameEnd
                    )
            end;
        {error, Reason} ->
            corrupt(Offset, Reason)
    end.

read_and_handle_frame(
    Fd,
    FileSize,
    Scan = #scan{offset = Offset},
    Type,
    PayloadBytes,
    ExpectedPayloadCrc32,
    FrameEnd
) ->
    case file:pread(Fd, Offset + ?HEADER_SIZE, PayloadBytes) of
        {ok, Payload} when byte_size(Payload) =:= PayloadBytes ->
            ActualCrc32 = erlang:crc32(Payload),
            case ActualCrc32 =:= ExpectedPayloadCrc32 of
                true ->
                    case handle_frame(Type, Payload, Scan, FrameEnd) of
                        {ok, Scan1} -> scan_next(Fd, FileSize, Scan1);
                        {error, _Reason} = Error -> Error
                    end;
                false ->
                    corrupt(Offset, {
                        checksum_mismatch,
                        ExpectedPayloadCrc32,
                        ActualCrc32
                    })
            end;
        eof ->
            finish_scan(Scan, truncate_start(Scan));
        {ok, _ShortPayload} ->
            finish_scan(Scan, truncate_start(Scan));
        {error, Reason} ->
            {error, {wal_read_failed, Offset, Reason}}
    end.

parse_header(<<
    Magic:8/binary,
    Version:8/unsigned-integer,
    Type:8/unsigned-integer,
    Reserved:16/unsigned-big-integer,
    PayloadBytes:32/unsigned-big-integer,
    ExpectedHeaderCrc32:32/unsigned-big-integer,
    PayloadCrc32:32/unsigned-big-integer
>>) ->
    HeaderPrefix = <<
        Magic/binary,
        Version:8/unsigned-integer,
        Type:8/unsigned-integer,
        Reserved:16/unsigned-big-integer,
        PayloadBytes:32/unsigned-big-integer
    >>,
    ActualHeaderCrc32 = erlang:crc32(HeaderPrefix),
    case ActualHeaderCrc32 =:= ExpectedHeaderCrc32 of
        false ->
            {error, {
                header_checksum_mismatch,
                ExpectedHeaderCrc32,
                ActualHeaderCrc32
            }};
        true when Magic =/= ?MAGIC ->
            {error, invalid_frame_magic};
        true when Version =/= ?FORMAT_VERSION ->
            {error, {unsupported_wal_version, Version}};
        true when Reserved =/= 0 ->
            {error, {unsupported_frame_flags, Reserved}};
        true when
            Type =:= ?TYPE_BATCH_BEGIN;
            Type =:= ?TYPE_EVENT;
            Type =:= ?TYPE_BATCH_COMMIT
        ->
            {ok, Type, PayloadBytes, PayloadCrc32};
        true ->
            {error, {invalid_frame_type, Type}}
    end;
parse_header(_Header) ->
    {error, invalid_frame_header}.

handle_frame(
    ?TYPE_BATCH_BEGIN,
    <<BatchId:32/binary, Count:32/unsigned-big-integer>>,
    Scan = #scan{pending = none, offset = Offset},
    FrameEnd
) when Count > 0, Count =< ?HARD_MAX_BATCH_EVENTS ->
    Pending = #{
        batch_id => BatchId,
        expected_count => Count,
        seen_count => 0,
        event_ids_rev => [],
        event_ids_seen => #{},
        records_rev => [],
        start_offset => Offset
    },
    {ok, Scan#scan{offset = FrameEnd, pending = Pending}};
handle_frame(
    ?TYPE_BATCH_BEGIN,
    _Payload,
    #scan{pending = none, offset = Offset},
    _FrameEnd
) ->
    corrupt(Offset, invalid_batch_begin);
handle_frame(?TYPE_BATCH_BEGIN, _Payload, #scan{offset = Offset}, _FrameEnd) ->
    corrupt(Offset, nested_batch_begin);
handle_frame(
    ?TYPE_EVENT,
    Payload,
    Scan = #scan{pending = Pending, offset = Offset},
    FrameEnd
) when Pending =/= none ->
    case decode_event_payload(Payload) of
        {ok, BatchId, EventId, Record} ->
            handle_pending_event(
                Scan,
                Pending,
                Offset,
                FrameEnd,
                BatchId,
                EventId,
                Record
            );
        {error, Reason} ->
            corrupt(Offset, Reason)
    end;
handle_frame(?TYPE_EVENT, _Payload, #scan{offset = Offset}, _FrameEnd) ->
    corrupt(Offset, event_without_batch);
handle_frame(
    ?TYPE_BATCH_COMMIT,
    <<BatchId:32/binary, Count:32/unsigned-big-integer>>,
    Scan = #scan{pending = Pending, offset = Offset},
    FrameEnd
) when Pending =/= none ->
    handle_pending_commit(Scan, Pending, Offset, FrameEnd, BatchId, Count);
handle_frame(
    ?TYPE_BATCH_COMMIT,
    _Payload,
    #scan{pending = none, offset = Offset},
    _FrameEnd
) ->
    corrupt(Offset, commit_without_batch);
handle_frame(?TYPE_BATCH_COMMIT, _Payload, #scan{offset = Offset}, _FrameEnd) ->
    corrupt(Offset, invalid_batch_commit_payload).

handle_pending_event(
    Scan,
    Pending,
    Offset,
    FrameEnd,
    BatchId,
    EventId,
    Record
) ->
    ExpectedBatchId = maps:get(batch_id, Pending),
    SeenCount = maps:get(seen_count, Pending),
    ExpectedCount = maps:get(expected_count, Pending),
    SeenIds = maps:get(event_ids_seen, Pending),
    case BatchId =:= ExpectedBatchId of
        false ->
            corrupt(Offset, event_batch_id_mismatch);
        true when SeenCount >= ExpectedCount ->
            corrupt(Offset, too_many_events_in_batch);
        true ->
            case maps:is_key(EventId, SeenIds) of
                true ->
                    corrupt(Offset, duplicate_event_id_in_committed_batch);
                false ->
                    Pending1 = Pending#{
                        seen_count => SeenCount + 1,
                        event_ids_rev => [
                            EventId | maps:get(event_ids_rev, Pending)
                        ],
                        event_ids_seen => SeenIds#{EventId => true},
                        records_rev => [
                            Record | maps:get(records_rev, Pending)
                        ]
                    },
                    {ok, Scan#scan{offset = FrameEnd, pending = Pending1}}
            end
    end.

handle_pending_commit(Scan, Pending, Offset, FrameEnd, BatchId, Count) ->
    ExpectedBatchId = maps:get(batch_id, Pending),
    ExpectedCount = maps:get(expected_count, Pending),
    SeenCount = maps:get(seen_count, Pending),
    EventIds = lists:reverse(maps:get(event_ids_rev, Pending)),
    Valid =
        BatchId =:= ExpectedBatchId andalso
            Count =:= ExpectedCount andalso
            SeenCount =:= ExpectedCount andalso
            batch_id(EventIds) =:= ExpectedBatchId,
    case Valid of
        true ->
            BatchRecordsRev = maps:get(records_rev, Pending),
            {ok, Scan#scan{
                offset = FrameEnd,
                pending = none,
                records_rev = BatchRecordsRev ++ Scan#scan.records_rev,
                batch_count = Scan#scan.batch_count + 1,
                event_count = Scan#scan.event_count + SeenCount
            }};
        false ->
            corrupt(
                Offset,
                {
                    invalid_batch_commit,
                    #{
                        expected_batch_id => ExpectedBatchId,
                        commit_batch_id => BatchId,
                        expected_count => ExpectedCount,
                        commit_count => Count,
                        seen_count => SeenCount
                    }
                }
            )
    end.

decode_event_payload(<<
    BatchId:32/binary,
    EventId:32/binary,
    RecordBytes:32/unsigned-big-integer,
    Encoded:RecordBytes/binary
>>) when RecordBytes > 0, RecordBytes =< ?HARD_MAX_RECORD_BYTES ->
    case ecai_ingest_record:decode(Encoded) of
        {ok, Record} ->
            case maps:get(event_id, Record) =:= EventId of
                true -> {ok, BatchId, EventId, Record};
                false -> {error, event_id_payload_mismatch}
            end;
        {error, Reason} ->
            {error, {invalid_event_record, Reason}}
    end;
decode_event_payload(_Payload) ->
    {error, invalid_event_payload}.

finish_scan(Scan, TruncateAt) ->
    Records = lists:reverse(Scan#scan.records_rev),
    Stats = #{
        batch_count => Scan#scan.batch_count,
        event_count => Scan#scan.event_count
    },
    {ok, Records, Stats, TruncateAt}.

truncate_start(#scan{pending = none, offset = Offset}) ->
    Offset;
truncate_start(#scan{pending = Pending}) ->
    maps:get(start_offset, Pending).

maybe_truncate_tail(_Fd, FileSize, FileSize) ->
    {ok, FileSize, 0};
maybe_truncate_tail(Fd, FileSize, TruncateAt) when
    TruncateAt >= 0, TruncateAt < FileSize
->
    case file:position(Fd, {bof, TruncateAt}) of
        {ok, TruncateAt} ->
            case file:truncate(Fd) of
                ok ->
                    case file:sync(Fd) of
                        ok -> {ok, TruncateAt, FileSize - TruncateAt};
                        {error, Reason} -> {error, {wal_repair_sync_failed, Reason}}
                    end;
                {error, Reason} ->
                    {error, {wal_repair_truncate_failed, Reason}}
            end;
        {ok, Unexpected} ->
            {error, {wal_repair_position_mismatch, TruncateAt, Unexpected}};
        {error, Reason} ->
            {error, {wal_repair_position_failed, Reason}}
    end;
maybe_truncate_tail(_Fd, FileSize, TruncateAt) ->
    {error, {invalid_wal_truncate_offset, FileSize, TruncateAt}}.

corrupt(Offset, Reason) ->
    {error, {wal_corrupt, #{offset => Offset, reason => Reason}}}.
