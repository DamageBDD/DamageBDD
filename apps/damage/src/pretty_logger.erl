%% damage_pretty_formatter.erl
%% Compact, colored formatter for OTP logger with optional icons.
%% Config keys: #{color => auto|on|off, icons => emoji|ascii|off}

-module(pretty_logger).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").

-export([format/2, test/0, test/1]).

%% ===================== PUBLIC =====================

%% ========= Public (now fail-safe) =========
format(LogEvent, Cfg) ->
    try
        SafeBin = build(LogEvent, Cfg),
        %% Logger is happiest with a binary
        SafeBin
    catch
        Class:Reason:_Stack ->
            %% Last-ditch, never crash: emit a tiny fallback line
            Fallback = io_lib:format(
                "~s | ~p:~p (~p)~n",
                [
                    timestamp_iso(maps:get(meta, LogEvent, #{})),
                    Class,
                    Reason,
                    element(1, erlang:process_info(self(), current_function))
                ]
            ),
            unicode:characters_to_binary(Fallback)
    end.

%% ========= Original logic, refactored to return UTF-8 binary =========
build(#{level := Level, msg := {string, Msg}} = LogEvent, Cfg) ->
    Meta = maps:get(meta, LogEvent, #{}),
    Src = format_source(Meta),
    H = header(Level, Src, Meta, Cfg),
    B = body_text(Msg),
    finalize([H, $\n, B, tail_meta(Meta, Cfg)]);
build(#{level := Level, msg := {report, Report}} = LogEvent, Cfg) ->
    Meta = maps:get(meta, LogEvent, #{}),
    Src = format_source(Meta),
    H = header(Level, Src, Meta, Cfg),
    R = format_report(Report, Meta),
    B = indent_iolist(R, 1),
    finalize([H, $\n, B, tail_meta(Meta, Cfg)]);
build(#{level := Level} = LogEvent, Cfg) ->
    Meta = maps:get(meta, LogEvent, #{}),
    Src = format_source(Meta),
    H = header(Level, Src, Meta, Cfg),
    Msg0 = maps:get(msg, LogEvent, <<"">>),
    B = body_term(Msg0),
    finalize([H, $\n, B, tail_meta(Meta, Cfg)]).

finalize(IoData) ->
    %% Convert any unicode list / iolist (with codepoints >255) to UTF-8 binary
    unicode:characters_to_binary(IoData).

%% ========= Styling (unchanged except: ensure binaries) =========
header(Level, Src, Meta, Cfg) ->
    {Tag, Icon0, Color} = level_style(Level, maps:get(icons, Cfg, emoji)),
    Icon =
        case Icon0 of
            <<>> -> <<>>;
            _ -> [Icon0, " "]
        end,
    Pid = maps:get(pid, Meta, undefined),
    Node = node_name(Meta),
    TimeS = timestamp_iso(Meta),
    Ln = io_lib:format("~ts~ts | ~ts | pid=~p | node=~p | ~ts", [Icon, Tag, Src, Pid, Node, TimeS]),
    ansi(Color, Ln, Cfg).

tail_meta(Meta, Cfg) ->
    Crumbs0 = compact_crumbs(Meta),
    case Crumbs0 of
        [] ->
            <<>>;
        _ ->
            Ln = io_lib:format("~n└─ ~ts~n", [Crumbs0]),
            ansi(dim, Ln, Cfg)
    end.

body_text(Msg) when is_list(Msg) -> prefix_block(Msg);
body_text(Msg) when is_binary(Msg) -> prefix_block(Msg);
body_text({Fmt, P}) when is_tuple(Fmt) -> prefix_block(io_lib:format(Fmt, P));
body_text(Other) -> prefix_block(io_lib:format("~p", [Other])).

body_term(Msg0) ->
    prefix_block(
        case Msg0 of
            B when is_binary(B) -> B;
            L when is_list(L) -> L;
            {F, P} = T when is_tuple(T) -> io_lib:format(F, P);
            T -> io_lib:format("~p", [T])
        end
    ).

%% ========= Source & Meta helpers (same as your version) =========
%% (keep your existing implementations for: format_source/1, basefile/1, fmt/2,
%% compact_crumbs/1, kv/2, kvts/2, first_defined/1, node_name/1, short_id/1,
%% timestamp_iso/1, format_report/2, level_style/*)

%% ========= Utility =========
indent_iolist(Io, Levels) ->
    Prefix = lists:duplicate(Levels, $\s) ++ "│ ",
    Lines = to_lines(Io),
    lists:join($\n, [[Prefix, L] || L <- Lines]).

prefix_block(Io) ->
    Lines = to_lines(Io),
    lists:join($\n, [["│ ", L] || L <- Lines]).

to_lines(Bin) when is_binary(Bin) ->
    [binary_to_list(B) || B <- binary:split(Bin, <<"\n">>, [global])];
to_lines(List) when is_list(List) ->
    %% If any codepoints >255 exist, normalize to unicode list first:
    Full = unicode:characters_to_list(erlang:iolist_to_binary(unicode:characters_to_binary(List))),
    string:split(Full, "\n", all);
to_lines(Term) ->
    Str = io_lib:format("~p", [Term]),
    to_lines(Str).

%% ANSI coloring -> always return a binary

ansi(_, Str, #{color := off}) -> lists:flatten(Str);
ansi(Color, Str, #{color := on}) -> colorize(Color, Str);
ansi(Color, Str, #{color := auto}) -> colorize(Color, Str);
ansi(Color, Str, _Cfg) -> colorize(Color, Str).

%% ===================== SOURCE & META =====================

%% Prefers: mfa:line → module:line → file:line → error_logger → pid → "unknown"
format_source(Meta) ->
    Line = maps:get(line, Meta, undefined),
    case maps:get(mfa, Meta, undefined) of
        {M, F, A} when is_atom(M), is_atom(F), is_integer(A) ->
            case Line of
                L when is_integer(L) -> fmt("~p:~p/~p:~p", [M, F, A, L]);
                _ -> fmt("~p:~p/~p", [M, F, A])
            end;
        _ ->
            case {maps:get(module, Meta, undefined), Line} of
                {M, L} when is_atom(M), is_integer(L) ->
                    fmt("~p:~p", [M, L]);
                _ ->
                    File0 = maps:get(file, Meta, undefined),
                    case {File0, Line} of
                        {FPath, L} when (is_list(FPath) or is_binary(FPath)), is_integer(L) ->
                            fmt("~ts:~p", [basefile(FPath), L]);
                        {FPath, _} when is_list(FPath); is_binary(FPath) ->
                            fmt("~ts", [basefile(FPath)]);
                        _ ->
                            case maps:get(error_logger, Meta, undefined) of
                                EL when is_map(EL) ->
                                    Pid2 = maps:get(pid, Meta, undefined),
                                    Tag = maps:get(tag, EL, undefined),
                                    fmt("error_logger[~p] tag=~p", [Pid2, Tag]);
                                _ ->
                                    case maps:get(pid, Meta, undefined) of
                                        P when is_pid(P) -> fmt("<~p>", [P]);
                                        _ -> "unknown"
                                    end
                            end
                    end
            end
    end.

basefile(Bin) when is_binary(Bin) -> basefile(binary_to_list(Bin));
basefile(Path) when is_list(Path) -> filename:basename(Path).

fmt(Fmt, Args) -> lists:flatten(io_lib:format(Fmt, Args)).

compact_crumbs(Meta) ->
    App = maps:get(application, Meta, undefined),
    Dom = maps:get(domain, Meta, undefined),
    ReqId = first_defined([
        maps:get(request_id, Meta, undefined),
        maps:get(req_id, Meta, undefined),
        maps:get(trace_id, Meta, undefined)
    ]),
    NodeS = node_name(Meta),
    MFAseg =
        case maps:get(mfa, Meta, undefined) of
            {M, F, A} -> lists:flatten(io_lib:format("~p:~p/~p", [M, F, A]));
            _ -> undefined
        end,
    FileSeg =
        case maps:get(file, Meta, undefined) of
            FPath when is_list(FPath); is_binary(FPath) ->
                L2 = maps:get(line, Meta, undefined),
                case is_integer(L2) of
                    true -> lists:flatten(io_lib:format("~ts:~p", [basefile(FPath), L2]));
                    false -> lists:flatten(io_lib:format("~ts", [basefile(FPath)]))
                end;
            _ ->
                undefined
        end,
    GL = maps:get(gl, Meta, undefined),
    Segs = lists:filter(
        fun(N) -> N =/= undefined end,
        [
            kv(app, App),
            kv(domain, Dom),
            kv(req, short_id(ReqId)),
            kvts(mfa, MFAseg),
            kvts(file, FileSeg),
            kv(gl, GL),
            kv(node, NodeS)
        ]
    ),
    case Segs of
        [] -> [];
        _ -> string:join(Segs, " · ")
    end.

kv(_K, undefined) -> undefined;
kv(K, V) -> lists:flatten(io_lib:format("~s=~p", [atom_to_list(K), V])).

kvts(_K, undefined) -> undefined;
kvts(K, V) -> lists:flatten(io_lib:format("~s=~ts", [atom_to_list(K), V])).

first_defined([]) -> undefined;
first_defined([undefined | T]) -> first_defined(T);
first_defined([H | _]) -> H.

node_name(Meta) ->
    case maps:get(node, Meta, undefined) of
        undefined -> node();
        N when is_atom(N) -> N
    end.

short_id(undefined) ->
    undefined;
short_id(Bin) when is_binary(Bin) ->
    short_id(binary_to_list(Bin));
short_id(List) when is_list(List) ->
    case length(List) > 12 of
        true -> lists:sublist(List, length(List) - 11, 12);
        false -> List
    end;
short_id(Term) ->
    lists:flatten(io_lib:format("~p", [Term])).

timestamp_iso(Meta) ->
    NowUS =
        case maps:get(time, Meta, undefined) of
            I when is_integer(I) -> I;
            _ -> erlang:system_time(microsecond)
        end,
    Sec = erlang:convert_time_unit(NowUS, microsecond, second),
    calendar:system_time_to_rfc3339(Sec, [{unit, second}, {offset, "Z"}]).

%% ===================== REPORT HANDLING =====================

format_report(Report, Meta) ->
    case maps:get(report_cb, Meta, undefined) of
        Fun when is_function(Fun, 2) -> Fun(Report, #{});
        Fun when is_function(Fun, 1) -> Fun(Report);
        _ -> io_lib:format("~p", [Report])
    end.

%% ===================== UTIL (color & text) =====================

%% Icons & colors

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
    {<<"INFO">>, <<"[i]">>, cyan};
level_style(debug, ascii) ->
    {<<"DEBUG">>, <<"[?]">>, magenta};
level_style(_, ascii) ->
    {<<"LOG">>, <<"[·]">>, white};
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
    {<<"INFO">>, <<"💎">>, cyan};
level_style(debug, emoji) ->
    {<<"DEBUG">>, <<"🧪">>, magenta};
level_style(_, emoji) ->
    {<<"LOG">>, <<"▫️">>, white};
level_style(Level, off) ->
    {Tag, _I, C} = level_style(Level, ascii),
    {Tag, <<>>, C}.

colorize(Color, Str) ->
    Code =
        case Color of
            red -> "31";
            yellow -> "33";
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
    Evt1 = #{
        level => info,
        msg => {string, "Starting DAMAGE market maker..."},
        meta => #{
            module => damage_market_maker,
            line => 101,
            pid => Self,
            node => Node,
            time => Now
        }
    },
    Evt2 = #{
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
    Report = {erl_lint, {unused_function, {foo, 1}}},
    Evt3 = #{
        level => error,
        msg => {report, Report},
        meta => #{
            pid => Self,
            node => Node,
            time => Now,
            report_cb => fun(R) ->
                io_lib:format("lint: ~p~nsee docs at https://example/lint", [R])
            end
        }
    },
    Evt4 = #{
        level => warning,
        msg => {string, "legacy error_logger bridge warning"},
        meta => #{pid => Self, time => Now, error_logger => #{tag => warning}}
    },
    Evt5 = #{
        level => debug,
        msg => {string, "Cache miss for key abc"},
        meta => #{mfa => {?MODULE, test, 1}, pid => Self, node => Node, time => Now}
    },
    lists:foreach(
        fun(E) ->
            io:put_chars(format(E, Cfg)),
            io:put_chars("\n")
        end,
        [Evt1, Evt2, Evt3, Evt4, Evt5]
    ),
    ok.
