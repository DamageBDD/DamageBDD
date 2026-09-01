%%--------------------------------------------------------------------
%% Recoverable activity stream with optional IPFS publication.
%%
%% Activity is first appended to a synced local NDJSON file. When the pending
%% block reaches a configured size (or flush/1 is called), it is wrapped with
%% a small chain header and added to IPFS. Publication failure never loses the
%% local activity: the pending file remains available for a later retry.
%%--------------------------------------------------------------------
-module(ecai_ipfs_activity).

-export([open/2, append/2, flush/1, status/1, close/1]).

-define(SCHEMA, <<"ecai-activity-stream/v1">>).
-define(DEFAULT_BLOCK_BYTES, 1048576).
-define(DEFAULT_SYNC_EVERY, 1).

-type activity() :: map().

-spec open(file:filename_all(), map()) -> {ok, activity()} | {error, term()}.
open(BaseDir0, Opts) when is_map(Opts) ->
    try
        BaseDir = path_list(BaseDir0),
        Dir = filename:join(BaseDir, "activity"),
        ok = filelib:ensure_dir(filename:join(Dir, "x")),
        Pending = filename:join(Dir, "pending.ndjson"),
        StatePath = filename:join(Dir, "state.json"),
        case read_state(StatePath) of
            {ok, State} ->
                open_recovered(Dir, Pending, StatePath, State, Opts);
            not_found ->
                open_recovered(Dir, Pending, StatePath, #{}, Opts);
            {error, _Reason} = Error ->
                Error
        end
    catch
        error:badarg -> {error, badarg};
        Class:Reason:Stacktrace -> {error, {activity_open_failed, Class, Reason, Stacktrace}}
    end;
open(_BaseDir, _Opts) ->
    {error, badarg}.

open_recovered(Dir, Pending, StatePath, State, Opts) ->
    case recover_pending(Pending) of
        {ok, PendingEvents0, LastPendingSequence0, RepairedBytes0} ->
            StateSequence = maps:get(sequence, State, 0),
            CommittedSequence = maps:get(committed_sequence, State, 0),
            case
                discard_committed_pending(
                    Pending,
                    PendingEvents0,
                    LastPendingSequence0,
                    CommittedSequence,
                    RepairedBytes0
                )
            of
                {ok, PendingEvents, LastPendingSequence, RepairedBytes} ->
                    case
                        pending_sequence_consistent(
                            StateSequence,
                            LastPendingSequence
                        )
                    of
                        true ->
                            {ok, #{
                                dir => Dir,
                                pending_path => Pending,
                                state_path => StatePath,
                                sequence => erlang:max(
                                    StateSequence,
                                    LastPendingSequence
                                ),
                                committed_sequence => CommittedSequence,
                                previous_cid => maps:get(previous_cid, State, null),
                                published_blocks => maps:get(published_blocks, State, 0),
                                pending_events => PendingEvents,
                                pending_bytes => file_size(Pending),
                                repaired_bytes_at_startup => RepairedBytes,
                                unsynced_events => 0,
                                publish_ipfs => maps:get(publish_ipfs, Opts, true),
                                block_bytes => positive_opt(
                                    block_bytes,
                                    Opts,
                                    ?DEFAULT_BLOCK_BYTES
                                ),
                                sync_every => positive_opt(
                                    sync_every,
                                    Opts,
                                    ?DEFAULT_SYNC_EVERY
                                ),
                                stream_id => maps:get(
                                    stream_id,
                                    Opts,
                                    <<"wikimedia-index">>
                                ),
                                last_publish_error => maps:get(
                                    last_publish_error,
                                    State,
                                    undefined
                                )
                            }};
                        false ->
                            {error, {
                                activity_sequence_inconsistent,
                                StateSequence,
                                LastPendingSequence
                            }}
                    end;
                {error, _Reason} = Error ->
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

-spec append(activity(), map()) -> {ok, activity()} | {error, term()}.
append(Activity0, Event0) when is_map(Activity0), is_map(Event0) ->
    Event = Event0#{
        schema => <<"ecai-activity-event/v1">>,
        sequence => maps:get(sequence, Activity0, 0) + 1
    },
    Line = <<(jsx:encode(ecai_index_job_codec:externalize(Event)))/binary, "\n">>,
    Path = maps:get(pending_path, Activity0),
    case append_file(Path, Line) of
        ok ->
            Sequence = maps:get(sequence, Activity0, 0) + 1,
            Unsynced = maps:get(unsynced_events, Activity0, 0) + 1,
            Activity1 = Activity0#{
                sequence => Sequence,
                pending_events => maps:get(pending_events, Activity0, 0) + 1,
                pending_bytes => maps:get(pending_bytes, Activity0, 0) + byte_size(Line),
                unsynced_events => Unsynced
            },
            case maybe_sync(Activity1) of
                {ok, Activity2} -> maybe_flush_threshold(Activity2);
                {error, _Reason} = Error -> Error
            end;
        {error, Reason} ->
            {error, {activity_append_failed, Path, Reason}}
    end;
append(_Activity, _Event) ->
    {error, badarg}.

-spec flush(activity()) -> {ok, activity()} | {error, term()}.
flush(Activity0) when is_map(Activity0) ->
    case maps:get(pending_events, Activity0, 0) of
        0 ->
            persist_state(Activity0);
        _ ->
            case sync_pending(Activity0) of
                {ok, Activity1} -> publish_pending(Activity1);
                {error, _Reason} = Error -> Error
            end
    end;
flush(_Activity) ->
    {error, badarg}.

-spec status(activity()) -> map().
status(Activity) when is_map(Activity) ->
    maps:with(
        [
            sequence,
            previous_cid,
            published_blocks,
            pending_events,
            pending_bytes,
            publish_ipfs,
            last_publish_error,
            repaired_bytes_at_startup,
            committed_sequence
        ],
        Activity
    ).

-spec close(activity()) -> {ok, activity()} | {error, term()}.
close(Activity) ->
    flush(Activity).

maybe_flush_threshold(Activity) ->
    case maps:get(pending_bytes, Activity, 0) >= maps:get(block_bytes, Activity) of
        true -> flush(Activity);
        false -> {ok, Activity}
    end.

maybe_sync(Activity) ->
    case maps:get(unsynced_events, Activity, 0) >= maps:get(sync_every, Activity) of
        true -> sync_pending(Activity);
        false -> {ok, Activity}
    end.

sync_pending(Activity) ->
    Path = maps:get(pending_path, Activity),
    case file:open(Path, [read, write, raw, binary]) of
        {ok, Fd} ->
            try
                case file:sync(Fd) of
                    ok -> {ok, Activity#{unsynced_events => 0}};
                    {error, Reason} -> {error, {activity_sync_failed, Path, Reason}}
                end
            after
                ok = file:close(Fd)
            end;
        {error, enoent} ->
            {ok, Activity#{unsynced_events => 0}};
        {error, Reason} ->
            {error, {activity_sync_open_failed, Path, Reason}}
    end.

publish_pending(Activity) ->
    PendingPath = maps:get(pending_path, Activity),
    Sequence = maps:get(sequence, Activity),
    StartSequence = Sequence - maps:get(pending_events, Activity) + 1,
    Header = jsx:encode(
        ecai_index_job_codec:externalize(#{
            schema => ?SCHEMA,
            stream_id => maps:get(stream_id, Activity),
            previous_cid => maps:get(previous_cid, Activity, null),
            first_sequence => StartSequence,
            last_sequence => Sequence,
            event_count => maps:get(pending_events, Activity)
        })
    ),
    BlockPath = filename:join(
        maps:get(dir, Activity),
        lists:flatten(io_lib:format("activity-~12..0B.ndjson", [Sequence]))
    ),
    case build_block(BlockPath, Header, PendingPath) of
        ok -> publish_built_block(Activity, BlockPath);
        {error, Reason} -> {error, {activity_block_build_failed, Reason}}
    end.

publish_built_block(Activity = #{publish_ipfs := false}, BlockPath) ->
    case hash_file(BlockPath) of
        {ok, Digest} ->
            LocalRef = <<"sha256:", (ecai_index_job_codec:id_hex(Digest))/binary>>,
            commit_block(Activity, LocalRef, BlockPath, false);
        {error, Reason} ->
            {error, {activity_block_hash_failed, Reason}}
    end;
publish_built_block(Activity, BlockPath) ->
    case normalize_add_response(damage_ipfs:add({file, BlockPath})) of
        {ok, Cid} ->
            commit_block(Activity, Cid, BlockPath, true);
        {error, Reason} ->
            _ = file:delete(BlockPath),
            case persist_state(Activity#{last_publish_error => Reason}) of
                {ok, _Persisted} -> {error, {activity_ipfs_publish_failed, Reason}};
                {error, _} = Error -> Error
            end
    end.

build_block(BlockPath, Header, PendingPath) ->
    Tmp = BlockPath ++ ".tmp",
    case file:open(Tmp, [write, raw, binary]) of
        {ok, Out} ->
            Result =
                try
                    ok = file:write(Out, <<Header/binary, "\n">>),
                    case file:open(PendingPath, [read, raw, binary]) of
                        {ok, In} ->
                            try
                                ok = copy_file(In, Out)
                            after
                                ok = file:close(In)
                            end;
                        {error, Reason0} ->
                            erlang:error({pending_open_failed, Reason0})
                    end,
                    ok = file:sync(Out),
                    ok
                catch
                    Class:Reason:Stacktrace ->
                        {error, {Class, Reason, Stacktrace}}
                after
                    ok = file:close(Out)
                end,
            case Result of
                ok ->
                    case file:rename(Tmp, BlockPath) of
                        ok -> ok;
                        {error, Reason1} -> {error, {rename_failed, Reason1}}
                    end;
                {error, _Reason} = Error ->
                    _ = file:delete(Tmp),
                    Error
            end;
        {error, Reason} ->
            {error, {block_open_failed, Reason}}
    end.

copy_file(In, Out) ->
    case file:read(In, 1048576) of
        eof ->
            ok;
        {ok, Bin} ->
            ok = file:write(Out, Bin),
            copy_file(In, Out);
        {error, Reason} ->
            {error, {read_failed, Reason}}
    end.

commit_block(Activity0, Reference, BlockPath, DeleteBlock) ->
    Sequence = maps:get(sequence, Activity0),
    Committed = Activity0#{
        previous_cid => Reference,
        published_blocks => maps:get(published_blocks, Activity0) + 1,
        committed_sequence => Sequence,
        last_publish_error => undefined
    },
    %% Persist the commit marker before clearing pending data. If the VM dies
    %% between these operations, open/2 observes committed_sequence and safely
    %% removes the already-published pending block instead of republishing it.
    case persist_state(Committed) of
        {ok, Persisted} ->
            case reset_pending(Persisted) of
                {ok, Reset} ->
                    case DeleteBlock of
                        true -> _ = file:delete(BlockPath);
                        false -> ok
                    end,
                    {ok, Reset};
                {error, _Reason} = Error ->
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

reset_pending(Activity0) ->
    PendingPath = maps:get(pending_path, Activity0),
    EmptyTmp = PendingPath ++ ".empty",
    case file:write_file(EmptyTmp, <<>>, [write, raw, binary, sync]) of
        ok ->
            case file:rename(EmptyTmp, PendingPath) of
                ok ->
                    {ok, Activity0#{
                        pending_events => 0,
                        pending_bytes => 0,
                        unsynced_events => 0
                    }};
                {error, Reason} ->
                    {error, {pending_reset_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {pending_reset_write_failed, Reason}}
    end.

persist_state(Activity) ->
    StatePath = maps:get(state_path, Activity),
    State = ecai_index_job_codec:externalize(#{
        schema => ?SCHEMA,
        sequence => maps:get(sequence, Activity, 0),
        previous_cid => maps:get(previous_cid, Activity, null),
        published_blocks => maps:get(published_blocks, Activity, 0),
        committed_sequence => maps:get(committed_sequence, Activity, 0),
        last_publish_error => maps:get(last_publish_error, Activity, undefined)
    }),
    case atomic_write(StatePath, jsx:encode(State)) of
        ok -> {ok, Activity};
        {error, Reason} -> {error, {activity_state_write_failed, Reason}}
    end.

read_state(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} ->
            try jsx:decode(Bytes, [return_maps]) of
                Map when is_map(Map) ->
                    {ok, #{
                        sequence => integer_value(maps:get(<<"sequence">>, Map, 0), 0),
                        previous_cid => maps:get(<<"previous_cid">>, Map, null),
                        published_blocks => integer_value(
                            maps:get(<<"published_blocks">>, Map, 0),
                            0
                        ),
                        committed_sequence => integer_value(
                            maps:get(<<"committed_sequence">>, Map, 0),
                            0
                        ),
                        last_publish_error => maps:get(
                            <<"last_publish_error">>,
                            Map,
                            undefined
                        )
                    }};
                _ ->
                    {error, {activity_state_not_map, Path}}
            catch
                error:Reason -> {error, {activity_state_corrupt, Path, Reason}}
            end;
        {error, enoent} ->
            not_found;
        {error, Reason} ->
            {error, {activity_state_read_failed, Path, Reason}}
    end.

recover_pending(Path) ->
    case file:open(Path, [read, write, raw, binary]) of
        {ok, Fd} ->
            try
                Size = file_size(Path),
                recover_pending_loop(Fd, Size, 0, 0, 0, 0)
            after
                ok = file:close(Fd)
            end;
        {error, enoent} ->
            {ok, 0, 0, 0};
        {error, Reason} ->
            {error, {activity_pending_open_failed, Path, Reason}}
    end.

recover_pending_loop(Fd, Size, LastGoodOffset, Count, LastSequence, Repaired) ->
    case file:read_line(Fd) of
        eof ->
            {ok, Count, LastSequence, Repaired};
        {ok, Line} ->
            {ok, CurrentOffset} = file:position(Fd, cur),
            case line_is_complete(Line) of
                false when CurrentOffset =:= Size ->
                    case truncate_at(Fd, LastGoodOffset) of
                        ok ->
                            {ok, Count, LastSequence, Size - LastGoodOffset};
                        {error, Reason} ->
                            {error, {activity_pending_repair_failed, Reason}}
                    end;
                false ->
                    {error, {activity_pending_corrupt, LastGoodOffset, incomplete_line}};
                true ->
                    case activity_sequence(Line) of
                        {ok, Sequence} when Count =:= 0; Sequence =:= LastSequence + 1 ->
                            recover_pending_loop(
                                Fd,
                                Size,
                                CurrentOffset,
                                Count + 1,
                                Sequence,
                                Repaired
                            );
                        {ok, Sequence} ->
                            {error, {
                                activity_pending_sequence_gap,
                                LastSequence,
                                Sequence
                            }};
                        {error, Reason} ->
                            {error, {activity_pending_corrupt, LastGoodOffset, Reason}}
                    end
            end;
        {error, Reason} ->
            {error, {activity_pending_read_failed, Reason}}
    end.

line_is_complete(<<>>) -> false;
line_is_complete(Line) -> binary:last(Line) =:= $\n.

activity_sequence(Line0) ->
    Line = trim_line_end(Line0),
    try jsx:decode(Line, [return_maps]) of
        Map when is_map(Map) ->
            case maps:get(<<"sequence">>, Map, undefined) of
                Sequence when is_integer(Sequence), Sequence > 0 -> {ok, Sequence};
                Other -> {error, {invalid_sequence, Other}}
            end;
        _ ->
            {error, not_map}
    catch
        error:Reason -> {error, {invalid_json, Reason}}
    end.

trim_line_end(Bin) when is_binary(Bin) ->
    trim_line_end(Bin, byte_size(Bin)).

trim_line_end(_Bin, 0) ->
    <<>>;
trim_line_end(Bin, Size) ->
    case binary:at(Bin, Size - 1) of
        $\n -> trim_line_end(Bin, Size - 1);
        $\r -> trim_line_end(Bin, Size - 1);
        _ -> binary:part(Bin, 0, Size)
    end.

truncate_at(Fd, Offset) ->
    case file:position(Fd, {bof, Offset}) of
        {ok, Offset} ->
            case file:truncate(Fd) of
                ok -> file:sync(Fd);
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

discard_committed_pending(
    _Path,
    0,
    0,
    _CommittedSequence,
    RepairedBytes
) ->
    {ok, 0, 0, RepairedBytes};
discard_committed_pending(
    Path,
    _PendingEvents,
    LastPendingSequence,
    CommittedSequence,
    RepairedBytes
) when CommittedSequence >= LastPendingSequence ->
    Bytes = file_size(Path),
    case file:write_file(Path, <<>>, [write, raw, binary, sync]) of
        ok -> {ok, 0, 0, RepairedBytes + Bytes};
        {error, Reason} -> {error, {committed_pending_reset_failed, Reason}}
    end;
discard_committed_pending(
    _Path,
    PendingEvents,
    LastPendingSequence,
    _CommittedSequence,
    RepairedBytes
) ->
    {ok, PendingEvents, LastPendingSequence, RepairedBytes}.

pending_sequence_consistent(_StateSequence, 0) ->
    true;
pending_sequence_consistent(StateSequence, LastPendingSequence) ->
    StateSequence =< LastPendingSequence.

hash_file(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try
                hash_file_loop(Fd, crypto:hash_init(sha256))
            after
                ok = file:close(Fd)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

hash_file_loop(Fd, Context) ->
    case file:read(Fd, 1048576) of
        eof -> {ok, crypto:hash_final(Context)};
        {ok, Bin} -> hash_file_loop(Fd, crypto:hash_update(Context, Bin));
        {error, Reason} -> {error, Reason}
    end.

append_file(Path, Bytes) ->
    case file:open(Path, [append, raw, binary]) of
        {ok, Fd} ->
            try
                file:write(Fd, Bytes)
            after
                ok = file:close(Fd)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

atomic_write(Path, Bytes) ->
    Tmp = Path ++ ".tmp",
    case file:open(Tmp, [write, raw, binary]) of
        {ok, Fd} ->
            Result =
                try
                    ok = file:write(Fd, Bytes),
                    file:sync(Fd)
                after
                    ok = file:close(Fd)
                end,
            case Result of
                ok -> file:rename(Tmp, Path);
                {error, _Reason} = Error -> Error
            end;
        {error, Reason} ->
            {error, Reason}
    end.

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
        _:_ -> {error, invalid_cid}
    end;
normalize_add_response({error, _Reason} = Error) ->
    Error;
normalize_add_response(Other) ->
    {error, {invalid_ipfs_add_response, Other}}.

file_size(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(2, Info);
        {error, _Reason} -> 0
    end.

positive_opt(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _ -> Default
    end.

integer_value(Value, _Default) when is_integer(Value) -> Value;
integer_value(_Value, Default) -> Default.

path_list(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    unicode:characters_to_list(Bin);
path_list(List) when is_list(List), List =/= [] -> List;
path_list(_Other) ->
    erlang:error(badarg).
