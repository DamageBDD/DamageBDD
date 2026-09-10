%% Reusable log utilities: Logger routing/filtering, file tailing (inode/offset),
%% journald cursor query, pattern matching and bounded event summarisation
-module(log_utils).

-author("Steven Joseph <steven@stevenjoseph.in>").
-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").

-export([
    compile_patterns/1,
    tail_file/3,
    query_journald/4,
    match_lines/2,
    include/2,
    exclude/2,
    matches_selector/2,
    filter_by_module/2,
    filter_by_module_prefix/2,
    filter_by_application/2,
    summarize/1,
    summarize/2,
    summarize_fmt/1,
    summarize_fmt/2,
    summarize_log_event/1,
    summarize_log_event/2
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
%% Generic Logger routing filters
%%
%% Keep routing policy in sys.config and matching mechanics here. This avoids
%% adding logger-filter functions to every subsystem module.
%%
%% Selector keys are ORed:
%%   #{modules => [damage_gun],
%%     module_prefixes => [<<"erm_lens">>],
%%     applications => [erm]}
%%
%% Handler examples:
%%
%%   %% Dedicated module-family file
%%   filter_default => stop,
%%   filters => [
%%       {only_erm_lens,
%%        {fun log_utils:include/2,
%%         #{module_prefixes => [<<"erm_lens">>]}}}
%%   ]
%%
%%   %% Remove the same family from a general/console handler
%%   filters => [
%%       {exclude_erm_lens,
%%        {fun log_utils:exclude/2,
%%         #{module_prefixes => [<<"erm_lens">>]}}}
%%   ]
%%
%% Application matching uses Logger metadata when present and otherwise
%% application:get_application(Module). No atoms are created from config data.
%% ------------------------------------------------------------------

-spec include(map(), term()) -> map() | stop.
include(LogEvent, Selector) ->
    case matches_selector(LogEvent, Selector) of
        true -> LogEvent;
        false -> stop
    end.

-spec exclude(map(), term()) -> stop | ignore.
exclude(LogEvent, Selector) ->
    case matches_selector(LogEvent, Selector) of
        true -> stop;
        false -> ignore
    end.

%% Compatibility/readability helpers for simple handlers.
filter_by_module(LogEvent, Module) ->
    include(LogEvent, #{modules => [Module]}).

filter_by_module_prefix(LogEvent, Prefix) ->
    include(LogEvent, #{module_prefixes => [Prefix]}).

filter_by_application(LogEvent, Application) ->
    include(LogEvent, #{applications => [Application]}).

-spec matches_selector(map(), term()) -> boolean().
matches_selector(LogEvent, Selector0) ->
    Selector = normalize_selector(Selector0),
    Module = event_module(LogEvent),
    Modules = selector_values(module, modules, Selector),
    Prefixes = selector_values(module_prefix, module_prefixes, Selector),
    Applications = selector_values(application, applications, Selector),
    module_selected(Module, Modules) orelse
        prefix_selected(Module, Prefixes) orelse
        application_selected(LogEvent, Module, Applications).

normalize_selector(Selector) when is_map(Selector) ->
    Selector;
normalize_selector({module, Module}) ->
    #{modules => [Module]};
normalize_selector({modules, Modules}) ->
    #{modules => normalize_selector_list(Modules)};
normalize_selector({module_prefix, Prefix}) ->
    #{module_prefixes => [Prefix]};
normalize_selector({module_prefixes, Prefixes}) ->
    #{module_prefixes => normalize_selector_list(Prefixes)};
normalize_selector({application, Application}) ->
    #{applications => [Application]};
normalize_selector({applications, Applications}) ->
    #{applications => normalize_selector_list(Applications)};
normalize_selector(Module) when is_atom(Module) ->
    #{modules => [Module]};
normalize_selector(_) ->
    #{}.

selector_values(Singular, Plural, Selector) ->
    SingularValues =
        case maps:find(Singular, Selector) of
            {ok, Value} -> [Value];
            error -> []
        end,
    PluralValues =
        case maps:find(Plural, Selector) of
            {ok, Values} -> normalize_selector_list(Values);
            error -> []
        end,
    SingularValues ++ PluralValues.

normalize_selector_list([]) ->
    [];
normalize_selector_list(Values) when is_list(Values) ->
    case lists:all(fun erlang:is_integer/1, Values) of
        true -> [Values];
        false -> Values
    end;
normalize_selector_list(Value) ->
    [Value].

event_module(#{meta := Meta}) when is_map(Meta) ->
    case maps:get(mfa, Meta, undefined) of
        {Module, _Function, _Arity} when is_atom(Module) -> Module;
        _ -> maps:get(module, Meta, undefined)
    end;
event_module(_) ->
    undefined.

module_selected(undefined, _Modules) ->
    false;
module_selected(Module, Modules) ->
    ModuleName = selector_name(Module),
    lists:any(fun(M) -> selector_name(M) =:= ModuleName end, Modules).

prefix_selected(undefined, _Prefixes) ->
    false;
prefix_selected(Module, Prefixes) ->
    ModuleName = selector_name(Module),
    lists:any(fun(Prefix) -> has_prefix(ModuleName, selector_name(Prefix)) end, Prefixes).

has_prefix(_Name, <<>>) ->
    false;
has_prefix(Name, Prefix) when byte_size(Name) >= byte_size(Prefix) ->
    binary:part(Name, 0, byte_size(Prefix)) =:= Prefix;
has_prefix(_Name, _Prefix) ->
    false.

application_selected(_LogEvent, _Module, []) ->
    false;
application_selected(LogEvent, Module, Applications) ->
    case event_application(LogEvent, Module) of
        undefined -> false;
        Application ->
            AppName = selector_name(Application),
            lists:any(fun(A) -> selector_name(A) =:= AppName end, Applications)
    end.

event_application(#{meta := Meta}, Module) when is_map(Meta) ->
    case maps:get(application, Meta, undefined) of
        undefined -> module_application(Module);
        Application -> Application
    end;
event_application(_LogEvent, Module) ->
    module_application(Module).

module_application(Module) when is_atom(Module) ->
    case application:get_application(Module) of
        {ok, Application} -> Application;
        undefined -> undefined
    end;
module_application(_) ->
    undefined.

selector_name(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
selector_name(Value) when is_binary(Value) ->
    Value;
selector_name(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
selector_name(Value) ->
    iolist_to_binary(io_lib:format("~p", [Value])).

%% Safe bounded term summarisation for logs
%% ------------------------------------------------------------------

summarize(Term) ->
    summarize(Term, #{}).

summarize(Term, Opts0) ->
    Opts = normalize_summarize_opts(Opts0),
    summarize_1(Term, maps:get(depth, Opts), Opts).

summarize_fmt(Term) ->
    summarize_fmt(Term, #{}).

summarize_fmt(Term, Opts) ->
    io_lib:format("~p", [summarize(Term, Opts)]).

%% Logger-event convenience wrapper. Useful from custom formatters/filters.
summarize_log_event(Event) ->
    summarize_log_event(Event, #{}).

summarize_log_event(Event, Opts0) ->
    Opts = normalize_summarize_opts(Opts0),
    summarize_1(Event, maps:get(depth, Opts), Opts).

normalize_summarize_opts(Opts0) when is_map(Opts0) ->
    maps:merge(
        #{
            depth => 6,
            max_binary => 128,
            max_string => 512,
            max_list => 24,
            max_map => 32,
            max_tuple => 24
        },
        Opts0
    );
normalize_summarize_opts(_) ->
    normalize_summarize_opts(#{}).

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
    Size = maps:size(Map),
    Pairs0 = maps:to_list(Map),
    Pairs = lists:sublist(Pairs0, Max),
    Sample = maps:from_list([
        {summarize_key(K, Depth - 1, Opts), summarize_1(V, Depth - 1, Opts)}
     || {K, V} <- Pairs
    ]),
    case Size > Max of
        true ->
            #{type => map, size => Size, sample => Sample};
        false ->
            Sample
    end;
summarize_1(List, Depth, Opts) when is_list(List) ->
    summarize_list(List, Depth, Opts);
summarize_1(Tuple, Depth, Opts) when is_tuple(Tuple) ->
    Max = maps:get(max_tuple, Opts),
    Size = tuple_size(Tuple),
    Sample0 = lists:sublist(tuple_to_list(Tuple), Max),
    Sample = [summarize_1(X, Depth - 1, Opts) || X <- Sample0],
    case Size > Max of
        true ->
            #{type => tuple, size => Size, sample => list_to_tuple(Sample)};
        false ->
            list_to_tuple(Sample)
    end;
summarize_1(Term, _Depth, _Opts) ->
    Term.

summarize_key(K, _Depth, _Opts) when is_atom(K); is_integer(K); is_binary(K) ->
    K;
summarize_key(K, Depth, Opts) ->
    summarize_1(K, Depth, Opts).

summarize_list(List, Depth, Opts) ->
    Len = safe_list_length(List),
    MaxList = maps:get(max_list, Opts),
    MaxString = maps:get(max_string, Opts),
    case {Len, safe_printable_list(List), safe_byte_list(List)} of
        {N, true, _} when is_integer(N), N > MaxString ->
            #{type => string, chars => N, head => lists:sublist(List, MaxString)};
        {N, true, _} when is_integer(N) ->
            List;
        {N, _, true} when is_integer(N), N > MaxList ->
            #{type => byte_list, length => N, head => lists:sublist(List, MaxList)};
        {N, _, _} when is_integer(N), N > MaxList ->
            #{
                type => list,
                length => N,
                sample => [summarize_1(X, Depth - 1, Opts) || X <- lists:sublist(List, MaxList)]
            };
        {N, _, _} when is_integer(N) ->
            [summarize_1(X, Depth - 1, Opts) || X <- List];
        _ ->
            #{type => improper_list, head => safe_improper_head(List, MaxList, Depth, Opts)}
    end.

safe_list_length(List) ->
    try
        length(List)
    catch
        _:_ -> unknown
    end.

safe_printable_list(List) ->
    try
        io_lib:printable_list(List)
    catch
        _:_ -> false
    end.

safe_byte_list(List) ->
    try
        lists:all(fun(I) -> is_integer(I) andalso I >= 0 andalso I =< 255 end, List)
    catch
        _:_ -> false
    end.

safe_improper_head(List, Max, Depth, Opts) ->
    safe_improper_head(List, Max, Depth, Opts, []).

safe_improper_head(_List, 0, _Depth, _Opts, Acc) ->
    lists:reverse(Acc);
safe_improper_head([H | T], N, Depth, Opts, Acc) ->
    safe_improper_head(T, N - 1, Depth, Opts, [summarize_1(H, Depth - 1, Opts) | Acc]);
safe_improper_head(Tail, _N, Depth, Opts, Acc) ->
    lists:reverse([{tail, summarize_1(Tail, Depth - 1, Opts)} | Acc]).

summarize_marker(Map) when is_map(Map) ->
    #{type => map, size => maps:size(Map)};
summarize_marker(List) when is_list(List) ->
    case safe_printable_list(List) of
        true -> #{type => string, chars => safe_list_length(List)};
        false -> #{type => list, length => safe_list_length(List)}
    end;
summarize_marker(Tuple) when is_tuple(Tuple) ->
    #{type => tuple, size => tuple_size(Tuple)};
summarize_marker(Bin) when is_binary(Bin) ->
    #{type => binary, bytes => byte_size(Bin)};
summarize_marker(Term) ->
    Term.
