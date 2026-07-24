%%--------------------------------------------------------------------
%% Bounded streaming decompression for Wikimedia .bz2 files.
%%
%% The decompressor is an external bzip2 process started without a shell, so
%% source paths are passed as argv values rather than interpolated commands.
%% Lines are delivered incrementally to a fold callback and never materialized
%% as one uncompressed file.
%%--------------------------------------------------------------------
-module(ecai_bzip2_stream).

-export([fold_lines/3, fold_lines/4, executable/0]).

-define(DEFAULT_TIMEOUT_MS, 120000).
-define(DEFAULT_MAX_LINE_BYTES, 33554432).
-define(DEFAULT_PORT_LINE_BYTES, 1048576).

-type fold_result(Acc) ::
    {ok, Acc}
    | {stop, Acc}
    | {error, term()}.

-spec executable() -> {ok, file:filename_all()} | {error, term()}.
executable() ->
    case os:find_executable("bzip2") of
        false -> {error, bzip2_not_found};
        Path -> {ok, Path}
    end.

-spec fold_lines(file:filename_all(), fun((binary(), term()) -> fold_result(term())), term()) ->
    {ok, term(), map()} | {error, term()}.
fold_lines(Path, Fun, Acc0) ->
    fold_lines(Path, Fun, Acc0, #{}).

-spec fold_lines(
    file:filename_all(),
    fun((binary(), term()) -> fold_result(term())),
    term(),
    map()
) -> {ok, term(), map()} | {error, term()}.
fold_lines(Path0, Fun, Acc0, Opts) when is_function(Fun, 2), is_map(Opts) ->
    try
        Path = path_list(Path0),
        case filelib:is_regular(Path) of
            false ->
                {error, {source_not_found, unicode:characters_to_binary(Path)}};
            true ->
                case executable() of
                    {ok, Executable} ->
                        PortLineBytes = bounded_positive(
                            port_line_bytes,
                            Opts,
                            ?DEFAULT_PORT_LINE_BYTES,
                            4096,
                            16777216
                        ),
                        Port = open_port(
                            {spawn_executable, Executable},
                            [
                                binary,
                                use_stdio,
                                exit_status,
                                hide,
                                {args, ["-dc", "--", Path]},
                                {line, PortLineBytes}
                            ]
                        ),
                        Timeout = positive_opt(timeout_ms, Opts, ?DEFAULT_TIMEOUT_MS),
                        MaxLine = positive_opt(
                            max_line_bytes,
                            Opts,
                            ?DEFAULT_MAX_LINE_BYTES
                        ),
                        Result = receive_lines(
                            Port,
                            Fun,
                            Acc0,
                            [],
                            0,
                            0,
                            0,
                            MaxLine,
                            Timeout
                        ),
                        safe_close(Port),
                        Result;
                    {error, _Reason} = Error ->
                        Error
                end
        end
    catch
        error:badarg -> {error, badarg};
        Class:Reason:Stacktrace ->
            {error, {bzip2_stream_failed, Class, Reason, Stacktrace}}
    end;
fold_lines(_Path, _Fun, _Acc0, _Opts) ->
    {error, badarg}.

receive_lines(
    Port,
    Fun,
    Acc0,
    Fragments,
    FragmentBytes,
    Lines,
    Bytes,
    MaxLine,
    Timeout
) ->
    receive
        {Port, {data, {noeol, Fragment}}} when is_binary(Fragment) ->
            NewFragmentBytes = FragmentBytes + byte_size(Fragment),
            case NewFragmentBytes =< MaxLine of
                true ->
                    receive_lines(
                        Port,
                        Fun,
                        Acc0,
                        [Fragment | Fragments],
                        NewFragmentBytes,
                        Lines,
                        Bytes + byte_size(Fragment),
                        MaxLine,
                        Timeout
                    );
                false ->
                    {error, {line_too_large, NewFragmentBytes, MaxLine}}
            end;
        {Port, {data, {eol, Tail}}} when is_binary(Tail) ->
            LineBytes = FragmentBytes + byte_size(Tail),
            case LineBytes =< MaxLine of
                false ->
                    {error, {line_too_large, LineBytes, MaxLine}};
                true ->
                    Line = assemble_line(Fragments, Tail),
                    case invoke(Fun, trim_cr(Line), Acc0) of
                        {ok, Acc1} ->
                            receive_lines(
                                Port,
                                Fun,
                                Acc1,
                                [],
                                0,
                                Lines + 1,
                                Bytes + byte_size(Tail),
                                MaxLine,
                                Timeout
                            );
                        {stop, Acc1} ->
                            terminate_port(Port),
                            {ok, Acc1, #{
                                lines => Lines + 1,
                                bytes => Bytes + byte_size(Tail),
                                stopped => true
                            }};
                        {error, Reason} ->
                            terminate_port(Port),
                            {error, Reason}
                    end
            end;
        {Port, {exit_status, 0}} ->
            case maybe_emit_final(Fun, Acc0, Fragments, Lines, Bytes) of
                {ok, Acc1, FinalLines} ->
                    {ok, Acc1, #{
                        lines => FinalLines,
                        bytes => Bytes,
                        stopped => false
                    }};
                {error, _Reason} = Error ->
                    Error
            end;
        {Port, {exit_status, Status}} ->
            {error, {bzip2_exit_status, Status}};
        {'EXIT', Port, Reason} ->
            {error, {bzip2_port_exit, Reason}}
    after Timeout ->
        terminate_port(Port),
        {error, {bzip2_inactivity_timeout, Timeout}}
    end.

maybe_emit_final(_Fun, Acc, [], Lines, _Bytes) ->
    {ok, Acc, Lines};
maybe_emit_final(Fun, Acc0, Fragments, Lines, _Bytes) ->
    Line = trim_cr(iolist_to_binary(lists:reverse(Fragments))),
    case invoke(Fun, Line, Acc0) of
        {ok, Acc1} -> {ok, Acc1, Lines + 1};
        {stop, Acc1} -> {ok, Acc1, Lines + 1};
        {error, _Reason} = Error -> Error
    end.

assemble_line([], Tail) -> Tail;
assemble_line(Fragments, Tail) ->
    iolist_to_binary([lists:reverse(Fragments), Tail]).

trim_cr(<<>>) -> <<>>;
trim_cr(Line) ->
    case binary:last(Line) of
        $\r -> binary:part(Line, 0, byte_size(Line) - 1);
        _ -> Line
    end.

invoke(Fun, Line, Acc0) ->
    try Fun(Line, Acc0) of
        {ok, _Acc1} = Ok -> Ok;
        {stop, _Acc1} = Stop -> Stop;
        {error, _Reason} = Error -> Error;
        Other -> {error, {invalid_fold_return, Other}}
    catch
        Class:Reason:Stacktrace ->
            {error, {fold_callback_failed, Class, Reason, Stacktrace}}
    end.

terminate_port(Port) ->
    try port_close(Port) of
        true -> ok
    catch
        error:badarg -> ok
    end.

safe_close(Port) ->
    try port_close(Port) of
        true -> ok
    catch
        error:badarg -> ok
    end.

positive_opt(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _ -> Default
    end.

bounded_positive(Key, Opts, Default, Min, Max) ->
    Value = positive_opt(Key, Opts, Default),
    erlang:min(erlang:max(Value, Min), Max).

path_list(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    unicode:characters_to_list(Bin);
path_list(List) when is_list(List), List =/= [] -> List;
path_list(_Other) -> erlang:error(badarg).
