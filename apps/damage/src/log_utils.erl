%% Reusable log utilities: file tailing (inode/offset), journald cursor query, pattern matching
-module(log_utils).

-author("Steven Joseph <steven@stevenjoseph.in>").
-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").

-export([
    compile_patterns/1,
    tail_file/3,
    query_journald/4,
    match_lines/2,
    filter_by_module/2,
    summarize/1,
    summarize/2,
    summarize_fmt/1,
    summarize_fmt/2
]).

-define(REGEX_OPTS, [unicode, dotall, multiline]).
% 1 MiB
-define(BUF, 1048576).

%% -------------------------
%% Pattern compilation
%% -------------------------

compile_patterns(undefined) ->
    [];
compile_patterns(<<>>) ->
    [];
compile_patterns("") ->
    [];
compile_patterns(Doc) when is_binary(Doc) ->
    compile_patterns(binary_to_list(Doc));
compile_patterns(Doc) when is_list(Doc) ->
    Lines0 = string:split(Doc, "\n", all),
    Lines = [string:trim(L) || L <- Lines0, L =/= ""],
    [compile_one(L) || L <- Lines].

compile_one(Line) ->
    case re:compile(Line, ?REGEX_OPTS) of
        {ok, MP} -> {regex, MP};
        {error, _Err} -> {literal, Line}
    end.

%% -------------------------
%% File tailing (inode/offset)
%% State :: #{} | #{inode := Inode, offset := Offset}
%% -------------------------

tail_file(File, State0, Patterns) ->
    case file:read_link_info(File) of
        {ok, FI} ->
            Inode = FI#file_info.inode,
            Size = FI#file_info.size,
            {Offset0, Rotated} =
                case State0 of
                    #{inode := Inode0, offset := Off0} when Inode0 =:= Inode, Off0 =< Size ->
                        {Off0, false};
                    _ ->
                        {0, true}
                end,
            {ok, Fd} = file:open(File, [read, raw, binary]),
            {ok, Bin} = pread_all(Fd, Offset0, Size - Offset0),
            ok = file:close(Fd),
            Lines = split_lines(Bin),
            Matches = match_lines(Lines, Patterns),
            State1 = #{inode => Inode, offset => Size, rotated => Rotated},
            {State1, Lines, Matches};
        {error, Reason} ->
            ?LOG_DEBUG("tail_file ~s read_link_info error: ~p", [File, Reason]),
            {State0, [], []}
    end.

pread_all(_Fd, _Pos, 0) ->
    {ok, <<>>};
pread_all(Fd, Pos, Len) when Len =< ?BUF ->
    case file:pread(Fd, Pos, Len) of
        {ok, Data} -> {ok, Data};
        eof -> {ok, <<>>}
    end;
pread_all(Fd, Pos, Len) ->
    Chunk = min(Len, ?BUF),
    {ok, A} = pread_all(Fd, Pos, Chunk),
    {ok, B} = pread_all(Fd, Pos + Chunk, Len - Chunk),
    {ok, <<A/binary, B/binary>>}.

split_lines(<<>>) -> [];
split_lines(Bin) -> [binary_to_list(L) || L <- binary:split(Bin, <<"\n">>, [global])].

%% -------------------------
%% Journald query (cursor)
%% Selector example: "SYSLOG_IDENTIFIER=lightningd" or "UNIT=lightningd.service"
%% -------------------------

query_journald(Selector, Minutes, Cursor0, Patterns) ->
    SinceArg = io_lib:format("--since=-~Bmin", [Minutes]),
    Base = ["journalctl", "-o", "cat"] ++ [lists:flatten(SinceArg)] ++ [Selector],
    Args =
        case Cursor0 of
            undefined -> Base ++ ["--show-cursor"];
            C -> Base ++ ["--after-cursor=" ++ C, "--show-cursor"]
        end,
    Cmd = string:join(Args, " "),
    Out = os:cmd(Cmd),
    {LinesRaw, Cursor1} = split_cursor(Out),
    Matches = match_lines(LinesRaw, Patterns),
    {Cursor1, LinesRaw, Matches}.

split_cursor(OutStr) when is_list(OutStr) ->
    Lines = string:split(OutStr, "\n", all),
    CursorLines = [L || L <- Lines, lists:prefix("-- cursor:", string:trim(L))],
    Cursor =
        case CursorLines of
            [] ->
                undefined;
            _ ->
                CLine = lists:last(CursorLines),
                string:trim(lists:nthtail(length("-- cursor:"), CLine))
        end,
    CleanLines = [L || L <- Lines, not lists:prefix("-- cursor:", string:trim(L))],
    {CleanLines, Cursor}.

%% -------------------------
%% Matching
%% -------------------------

match_lines(_Lines, []) -> [];
match_lines(Lines, Pats) -> [L || L <- Lines, any_match(L, Pats)].

any_match(Line, [{regex, MP} | Rest]) ->
    case re:run(Line, MP, [{capture, none}]) of
        match -> true;
        nomatch -> any_match(Line, Rest)
    end;
any_match(Line, [{literal, S} | Rest]) ->
    case string:find(Line, S) of
        nomatch -> any_match(Line, Rest);
        _ -> true
    end;
any_match(_Line, []) ->
    false.

%% ------------------------------------------------------------------
%% Generic logger filter
%%
%% Usage in sys.config:
%%
%% filters => #{
%%     only_damage_nostr =>
%%         {fun log_utils:filter_by_module/2, damage_nostr}
%% }
%%
%% ------------------------------------------------------------------

filter_by_module(LogEvent = #{meta := Meta}, Module) ->
    case maps:get(mfa, Meta, undefined) of
        {Module, _, _} ->
            LogEvent;
        _ ->
            stop
    end;
filter_by_module(_, _) ->
    stop.
%% ------------------------------------------------------------------
%% Safe bounded term summarisation for logs
%% ------------------------------------------------------------------

summarize(Term) ->
    summarize(Term, #{}).

summarize(Term, Opts0) ->
    Opts = maps:merge(
        #{
            depth => 5,
            max_binary => 96,
            max_list => 20,
            max_map => 20,
            max_tuple => 20
        },
        Opts0
    ),
    summarize_1(Term, maps:get(depth, Opts), Opts).

summarize_fmt(Term) ->
    summarize_fmt(Term, #{}).

summarize_fmt(Term, Opts) ->
    io_lib:format("~p", [summarize(Term, Opts)]).

summarize_1(Term, 0, _Opts) ->
    summarize_marker(Term);
summarize_1(Bin, _Depth, Opts) when is_binary(Bin) ->
    Max = maps:get(max_binary, Opts),
    Size = byte_size(Bin),
    case Size > Max of
        true ->
            Head = binary:part(Bin, 0, Max),
            #{type => binary, bytes => Size, head => Head};
        false ->
            Bin
    end;
summarize_1(Map, Depth, Opts) when is_map(Map) ->
    Max = maps:get(max_map, Opts),
    Pairs = lists:sublist(maps:to_list(Map), Max),
    #{
        type => map,
        size => maps:size(Map),
        sample => maps:from_list([
            {summarize_1(K, Depth - 1, Opts), summarize_1(V, Depth - 1, Opts)}
         || {K, V} <- Pairs
        ])
    };
summarize_1(List, Depth, Opts) when is_list(List) ->
    Max = maps:get(max_list, Opts),
    Sample = lists:sublist(List, Max),
    #{
        type => list,
        length => safe_list_length(List),
        sample => [summarize_1(X, Depth - 1, Opts) || X <- Sample]
    };
summarize_1(Tuple, Depth, Opts) when is_tuple(Tuple) ->
    Max = maps:get(max_tuple, Opts),
    Size = tuple_size(Tuple),
    Sample = lists:sublist(tuple_to_list(Tuple), Max),
    list_to_tuple(
        [
            {tuple_size, Size}
            | [summarize_1(X, Depth - 1, Opts) || X <- Sample]
        ]
    );
summarize_1(Term, _Depth, _Opts) ->
    Term.

safe_list_length(List) ->
    try
        length(List)
    catch
        _:_ -> unknown
    end.

summarize_marker(Map) when is_map(Map) ->
    #{type => map, size => maps:size(Map)};
summarize_marker(List) when is_list(List) ->
    #{type => list, length => safe_list_length(List)};
summarize_marker(Tuple) when is_tuple(Tuple) ->
    #{type => tuple, size => tuple_size(Tuple)};
summarize_marker(Bin) when is_binary(Bin) ->
    #{type => binary, bytes => byte_size(Bin)};
summarize_marker(Term) ->
    Term.
