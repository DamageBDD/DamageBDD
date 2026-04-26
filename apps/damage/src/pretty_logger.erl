%% damage_pretty_formatter.erl
%% Compact, colored, fail-safe formatter for OTP logger.
%% Config keys: #{color => auto|on|off, icons => emoji|ascii|off}

-module(pretty_logger).
-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([format/2, test/0, test/1]).

%% ===================== PUBLIC =====================

format(LogEvent, Cfg) ->
    try
        finalize(build(LogEvent, normalize_cfg(Cfg)))
    catch
        Class:Reason:Stack ->
            fallback(LogEvent, Class, Reason, Stack)
    end.

normalize_cfg(Cfg) when is_map(Cfg) ->
    maps:merge(#{color => auto, icons => emoji}, Cfg);
normalize_cfg(_) ->
    #{color => auto, icons => emoji}.

fallback(LogEvent, Class, Reason, Stack) ->
    Meta = safe_meta(LogEvent),
    TimeS = safe_timestamp_iso(Meta),
    MFA = safe_current_function(self()),
    Line = io_lib:format(
        "~ts | logger_formatter_failed | ~p:~p | current=~p | stack_top=~p~n",
        [TimeS, Class, Reason, MFA, stack_top(Stack)]
    ),
    safe_unicode(Line).

stack_top([H | _]) -> H;
stack_top(_) -> undefined.

safe_current_function(Pid) when is_pid(Pid) ->
    try erlang:process_info(Pid, current_function) of
        {current_function, MFA} -> MFA;
        undefined -> undefined;
        Other -> Other
    catch
        _:_ -> undefined
    end;
safe_current_function(_) ->
    undefined.

%% ===================== BUILD =====================

build(#{level := Level, msg := {string, Msg}} = LogEvent, Cfg) ->
    Meta = safe_meta(LogEvent),
    [header(Level, Meta, Cfg), $\n, body_text(Msg), tail_meta(Meta, Cfg)];
build(#{level := Level, msg := {report, Report}} = LogEvent, Cfg) ->
    Meta = safe_meta(LogEvent),
    [
        header(Level, Meta, Cfg),
        $\n,
        indent_iolist(format_report_safe(Report, Meta), 1),
        tail_meta(Meta, Cfg)
    ];
build(#{level := Level} = LogEvent, Cfg) ->
    Meta = safe_meta(LogEvent),
    Msg0 = maps:get(msg, LogEvent, <<>>),
    [header(Level, Meta, Cfg), $\n, body_term(Msg0), tail_meta(Meta, Cfg)];
build(Other, Cfg) ->
    Meta = #{},
    [header(info, Meta, Cfg), $\n, body_term(Other)].

safe_meta(#{meta := Meta}) when is_map(Meta) -> Meta;
safe_meta(_) -> #{}.

finalize(IoData) ->
    safe_unicode(IoData).

safe_unicode(IoData) ->
    try unicode:characters_to_binary(IoData) of
        Bin when is_binary(Bin) -> Bin;
        Other -> iolist_to_binary(io_lib:format("~p", [Other]))
    catch
        _:_ -> iolist_to_binary(io_lib:format("~p", [IoData]))
    end.

%% ===================== HEADER / BODY =====================

header(Level, Meta, Cfg) ->
    Src = format_source(Meta),
    {Tag, Icon0, Color} = level_style(Level, maps:get(icons, Cfg, emoji)),
    Icon =
        case Icon0 of
            <<>> -> <<>>;
            _ -> [Icon0, " "]
        end,
    Pid = maps:get(pid, Meta, undefined),
    Node = node_name(Meta),
    TimeS = safe_timestamp_iso(Meta),
    Ln = io_lib:format("~ts~ts | ~ts | pid=~p | node=~p | ~ts", [Icon, Tag, Src, Pid, Node, TimeS]),
    ansi(Color, Ln, Cfg).

tail_meta(Meta, Cfg) ->
    case compact_crumbs(Meta) of
        [] -> <<>>;
        Crumbs -> ansi(dim, io_lib:format("~n└─ ~ts~n", [Crumbs]), Cfg)
    end.

body_text(Msg) -> prefix_block(Msg).

body_term(Msg0) ->
    prefix_block(
        case Msg0 of
            B when is_binary(B) -> B;
            L when is_list(L) -> L;
            {F, P} when is_list(F), is_list(P) -> io_lib:format(F, P);
            {F, P} when is_binary(F), is_list(P) -> io_lib:format(binary_to_list(F), P);
            T -> io_lib:format("~p", [T])
        end
    ).

indent_iolist(Io, Levels) ->
    Prefix = lists:duplicate(Levels, $\s) ++ "│ ",
    Lines = to_lines(Io),
    lists:join($\n, [[Prefix, L] || L <- Lines]).

prefix_block(Io) ->
    Lines = to_lines(Io),
    lists:join($\n, [["│ ", L] || L <- Lines]).

to_lines(Io) ->
    Bin = safe_unicode(Io),
    [binary_to_list(B) || B <- binary:split(Bin, <<"\n">>, [global])].

%% ===================== SOURCE & META =====================

format_source(Meta) ->
    Line = maps:get(line, Meta, undefined),
    case maps:get(mfa, Meta, undefined) of
        {M, F, A} when is_atom(M), is_atom(F), is_integer(A) ->
            case Line of
                L when is_integer(L) -> fmt("~p:~p/~p:~p", [M, F, A, L]);
                _ -> fmt("~p:~p/~p", [M, F, A])
            end;
        _ ->
            format_source_1(Meta, Line)
    end.

format_source_1(Meta, Line) ->
    case {maps:get(module, Meta, undefined), Line} of
        {M, L} when is_atom(M), is_integer(L) ->
            fmt("~p:~p", [M, L]);
        _ ->
            format_source_file(Meta, Line)
    end.

format_source_file(Meta, Line) ->
    File0 = maps:get(file, Meta, undefined),
    case {File0, Line} of
        {FPath, L} when (is_list(FPath) orelse is_binary(FPath)), is_integer(L) ->
            fmt("~ts:~p", [basefile(FPath), L]);
        {FPath, _} when is_list(FPath); is_binary(FPath) ->
            fmt("~ts", [basefile(FPath)]);
        _ ->
            format_source_fallback(Meta)
    end.

format_source_fallback(Meta) ->
    case maps:get(error_logger, Meta, undefined) of
        EL when is_map(EL) ->
            fmt("error_logger[~p] tag=~p", [
                maps:get(pid, Meta, undefined), maps:get(tag, EL, undefined)
            ]);
        _ ->
            case maps:get(pid, Meta, undefined) of
                P when is_pid(P) -> fmt("<~p>", [P]);
                _ -> "unknown"
            end
    end.

basefile(Bin) when is_binary(Bin) -> basefile(binary_to_list(Bin));
basefile(Path) when is_list(Path) -> filename:basename(Path);
basefile(Other) -> fmt("~p", [Other]).

fmt(Fmt, Args) -> lists:flatten(io_lib:format(Fmt, Args)).

compact_crumbs(Meta) ->
    ReqId = first_defined([
        maps:get(request_id, Meta, undefined),
        maps:get(req_id, Meta, undefined),
        maps:get(trace_id, Meta, undefined)
    ]),
    MFAseg =
        case maps:get(mfa, Meta, undefined) of
            {M, F, A} -> fmt("~p:~p/~p", [M, F, A]);
            _ -> undefined
        end,
    FileSeg =
        case maps:get(file, Meta, undefined) of
            FPath when is_list(FPath); is_binary(FPath) ->
                case maps:get(line, Meta, undefined) of
                    L when is_integer(L) -> fmt("~ts:~p", [basefile(FPath), L]);
                    _ -> fmt("~ts", [basefile(FPath)])
                end;
            _ ->
                undefined
        end,
    Segs = lists:filter(
        fun(N) -> N =/= undefined end,
        [
            kv(app, maps:get(application, Meta, undefined)),
            kv(domain, maps:get(domain, Meta, undefined)),
            kv(req, short_id(ReqId)),
            kvts(mfa, MFAseg),
            kvts(file, FileSeg),
            kv(gl, maps:get(gl, Meta, undefined)),
            kv(node, node_name(Meta))
        ]
    ),
    case Segs of
        [] -> [];
        _ -> string:join(Segs, " · ")
    end.

kv(_K, undefined) -> undefined;
kv(K, V) -> fmt("~s=~p", [atom_to_list(K), V]).

kvts(_K, undefined) -> undefined;
kvts(K, V) -> fmt("~s=~ts", [atom_to_list(K), V]).

first_defined([]) -> undefined;
first_defined([undefined | T]) -> first_defined(T);
first_defined([H | _]) -> H.

node_name(Meta) ->
    case maps:get(node, Meta, undefined) of
        undefined -> node();
        N when is_atom(N) -> N;
        N -> N
    end.

short_id(undefined) ->
    undefined;
short_id(Bin) when is_binary(Bin) -> short_id(binary_to_list(Bin));
short_id(List) when is_list(List) ->
    Len = length(List),
    case Len > 12 of
        true -> lists:nthtail(Len - 12, List);
        false -> List
    end;
short_id(Term) ->
    fmt("~p", [Term]).

safe_timestamp_iso(Meta) ->
    try
        timestamp_iso(Meta)
    catch
        _:_ -> "1970-01-01T00:00:00Z"
    end.

timestamp_iso(Meta) ->
    NowUS =
        case maps:get(time, Meta, undefined) of
            I when is_integer(I) -> I;
            _ -> erlang:system_time(microsecond)
        end,
    Sec = erlang:convert_time_unit(NowUS, microsecond, second),
    calendar:system_time_to_rfc3339(Sec, [{unit, second}, {offset, "Z"}]).

%% ===================== REPORT HANDLING =====================

format_report_safe(Report, Meta) ->
    try
        format_report(Report, Meta)
    catch
        C:R -> io_lib:format("report_cb_failed ~p:~p report=~p", [C, R, Report])
    end.

format_report(Report, Meta) ->
    case maps:get(report_cb, Meta, undefined) of
        Fun when is_function(Fun, 2) -> Fun(Report, #{});
        Fun when is_function(Fun, 1) -> Fun(Report);
        _ -> io_lib:format("~p", [Report])
    end.

%% ===================== COLOR =====================

ansi(_, Str, #{color := off}) -> Str;
ansi(Color, Str, #{color := on}) -> colorize(Color, Str);
ansi(Color, Str, #{color := auto}) -> colorize(Color, Str);
ansi(Color, Str, _Cfg) -> colorize(Color, Str).

level_style(error, ascii) ->
    {<<"ERROR">>, <<"[!]">>, red};
level_style(critical, ascii) ->
    {<<"CRIT">>, <<"[!]">>, red};
level_style(alert, ascii) ->
    {<<"ALERT">>, <<"[!]">>, red};
level_style(emergency, ascii) ->
    {<<"EMERG">>, <<"[!]">>, red};
level_style(warning, ascii) ->
    {<<"WARN">>, <<"[~]">>, yellow};
level_style(notice, ascii) ->
    {<<"NOTE">>, <<"[+]">>, cyan};
level_style(info, ascii) ->
    {<<"INFO">>, <<"[i]">>, green};
level_style(debug, ascii) ->
    {<<"DEBUG">>, <<"[?]">>, magenta};
level_style(_, ascii) ->
    {<<"LOG">>, <<"[.]">>, white};
level_style(error, emoji) ->
    {<<"ERROR">>, <<"⛓️‍💥">>, red};
level_style(critical, emoji) ->
    {<<"CRIT">>, <<"⛓️‍💥">>, red};
level_style(alert, emoji) ->
    {<<"ALERT">>, <<"⛓️‍💥">>, red};
level_style(emergency, emoji) ->
    {<<"EMERG">>, <<"⛓️‍💥">>, red};
level_style(warning, emoji) ->
    {<<"WARN">>, <<"⚡">>, yellow};
level_style(notice, emoji) ->
    {<<"NOTE">>, <<"✨">>, cyan};
level_style(info, emoji) ->
    {<<"INFO">>, <<"💎">>, green};
level_style(debug, emoji) ->
    {<<"DEBUG">>, <<"🧪">>, magenta};
level_style(_, emoji) ->
    {<<"LOG">>, <<"▫️">>, white};
level_style(Level, off) ->
    {Tag, _I, C} = level_style(Level, ascii),
    {Tag, <<>>, C};
level_style(Level, _) ->
    level_style(Level, ascii).

colorize(Color, Str) ->
    Code =
        case Color of
            red -> "31";
            yellow -> "33";
            green -> "32";
            cyan -> "36";
            magenta -> "35";
            white -> "37";
            dim -> "2";
            _ -> "0"
        end,
    ["\e[", Code, "m", Str, "\e[0m"].

%% ===================== TEST HELPERS =====================

test() -> test(#{color => on, icons => ascii}).

test(Cfg0) ->
    Cfg = maps:merge(#{color => on, icons => ascii}, Cfg0),
    Now = erlang:system_time(microsecond),
    Node = node(),
    Self = self(),
    Events = [
        #{
            level => info,
            msg => {string, "Starting DAMAGE market maker..."},
            meta => #{
                module => damage_market_maker, line => 101, pid => Self, node => Node, time => Now
            }
        },
        #{
            level => error,
            msg => {string, "Error connecting to IPFS node ipfs0"},
            meta => #{
                file => "/srv/damage/apps/damage/src/damage_ipfs.erl",
                line => 243,
                pid => Self,
                node => Node,
                time => Now
            }
        },
        #{
            level => error,
            msg => {report, {erl_lint, {unused_function, {foo, 1}}}},
            meta => #{
                pid => Self,
                node => Node,
                time => Now,
                report_cb => fun(R) -> io_lib:format("lint: ~p", [R]) end
            }
        },
        #{
            level => warning,
            msg => {string, "legacy error_logger bridge warning"},
            meta => #{pid => Self, time => Now, error_logger => #{tag => warning}}
        },
        #{
            level => debug,
            msg => {string, "Cache miss for key abc"},
            meta => #{mfa => {?MODULE, test, 1}, pid => Self, node => Node, time => Now}
        }
    ],
    lists:foreach(
        fun(E) ->
            io:put_chars(format(E, Cfg)),
            io:put_chars("\n")
        end,
        Events
    ),
    ok.
