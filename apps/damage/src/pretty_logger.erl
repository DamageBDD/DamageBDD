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
    Cfg1 = normalize_cfg(Cfg),
    try
        finalize(build(LogEvent, Cfg1), Cfg1)
    catch
        Class:Reason:Stack ->
            fallback(LogEvent, Class, Reason, Stack, Cfg1)
    end.

normalize_cfg(Cfg) when is_map(Cfg) ->
    maps:merge(
        #{
            color => auto,
            icons => emoji,
            max_event_chars => 12000,
            max_text_chars => 4096,
            max_binary => 128,
            max_string => 512,
            max_list => 24,
            max_map => 32,
            max_tuple => 24,
            depth => 6
        },
        Cfg
    );
normalize_cfg(_) ->
    #{
        color => auto,
        icons => emoji,
        max_event_chars => 12000,
        max_text_chars => 4096,
        max_binary => 128,
        max_string => 512,
        max_list => 24,
        max_map => 32,
        max_tuple => 24,
        depth => 6
    }.

fallback(LogEvent, Class, Reason, Stack, Cfg) ->
    %% This path must be boring and tiny.  Do not call report callbacks here and
    %% do not render raw stack frames: they can contain the same huge terms that
    %% broke the formatter in the first place.
    Meta = safe_meta(LogEvent),
    TimeS = safe_timestamp_iso(Meta),
    MFA = safe_current_function(self()),
    StackTop = summarize_stack_top(Stack, Cfg),
    Event = summarize_term(
        LogEvent,
        maps:merge(Cfg, #{
            depth => 3,
            max_list => 8,
            max_map => 12,
            max_tuple => 8,
            max_string => 160,
            max_binary => 64
        })
    ),
    Line = io_lib:format(
        "~s | logger_formatter_failed | ~p:~p | current=~p | stack_top=~p | event=~p~n",
        [TimeS, Class, Reason, MFA, StackTop, Event]
    ),
    cap_binary(safe_unicode(Line), maps:get(max_event_chars, Cfg, 12000)).

summarize_stack_top([Frame | _], Cfg) ->
    SmallCfg = maps:merge(Cfg, #{
        depth => 3,
        max_list => 8,
        max_map => 12,
        max_tuple => 8,
        max_string => 160,
        max_binary => 64
    }),
    case Frame of
        {M, F, Args, Loc} when is_list(Args) ->
            #{
                m => M,
                f => F,
                args => summarize_args(Args, SmallCfg),
                loc => summarize_term(Loc, SmallCfg)
            };
        {M, F, Arity, Loc} ->
            #{m => M, f => F, arity => Arity, loc => summarize_term(Loc, SmallCfg)};
        Other ->
            summarize_term(Other, SmallCfg)
    end;
summarize_stack_top(_, _Cfg) ->
    undefined.

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
    [header(Level, Meta, Cfg), $\n, body_text(Msg, Cfg), tail_meta(Meta, Cfg)];
build(#{level := Level, msg := {report, Report}} = LogEvent, Cfg) ->
    Meta = safe_meta(LogEvent),
    [
        header(Level, Meta, Cfg),
        $\n,
        indent_iolist(format_report_safe(Report, Meta, Cfg), 1),
        tail_meta(Meta, Cfg)
    ];
build(#{level := Level} = LogEvent, Cfg) ->
    Meta = safe_meta(LogEvent),
    Msg0 = maps:get(msg, LogEvent, <<>>),
    [header(Level, Meta, Cfg), $\n, body_term(Msg0, Cfg), tail_meta(Meta, Cfg)];
build(Other, Cfg) ->
    Meta = #{},
    [header(info, Meta, Cfg), $\n, body_term(Other, Cfg)].

safe_meta(#{meta := Meta}) when is_map(Meta) -> Meta;
safe_meta(_) -> #{}.

finalize(IoData, Cfg) ->
    cap_binary(safe_unicode(IoData), maps:get(max_event_chars, Cfg, 12000)).

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

body_text(Msg, Cfg) ->
    prefix_block(truncate_iolist(Msg, Cfg)).

body_term(Msg0, Cfg) ->
    Rendered =
        case Msg0 of
            B when is_binary(B) -> truncate_iolist(B, Cfg);
            L when is_list(L) -> truncate_iolist(L, Cfg);
            {F, P} when is_list(F), is_list(P) -> safe_fmt(F, P, Cfg);
            {F, P} when is_binary(F), is_list(P) -> safe_fmt(binary_to_list(F), P, Cfg);
            T -> io_lib:format("~p", [summarize_term(T, Cfg)])
        end,
    prefix_block(Rendered).

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

format_report_safe(Report, Meta, Cfg) ->
    try
        format_report(Report, Meta, Cfg)
    catch
        C:R ->
            io_lib:format("report_cb_failed ~p:~p report=~p", [
                C, R, summarize_term(Report, Cfg)
            ])
    end.

format_report(Report, Meta, Cfg) ->
    case maps:get(report_cb, Meta, undefined) of
        Fun when is_function(Fun, 2) -> truncate_iolist(Fun(Report, #{}), Cfg);
        Fun when is_function(Fun, 1) -> truncate_iolist(Fun(Report), Cfg);
        _ -> format_report_default(Report, Cfg)
    end.

format_report_default(#{label := Label, report := Rep}, Cfg) ->
    ["label=", io_lib:format("~p", [Label]), "\n", format_report_default(Rep, Cfg)];
format_report_default({Fmt0, Args}, Cfg) when is_list(Fmt0), is_list(Args) ->
    safe_fmt(Fmt0, Args, Cfg);
format_report_default({Fmt0, Args}, Cfg) when is_binary(Fmt0), is_list(Args) ->
    safe_fmt(binary_to_list(Fmt0), Args, Cfg);
format_report_default([Fmt0, Args], Cfg) when is_list(Fmt0), is_list(Args) ->
    safe_fmt(Fmt0, Args, Cfg);
format_report_default([Fmt0, Args], Cfg) when is_binary(Fmt0), is_list(Args) ->
    safe_fmt(binary_to_list(Fmt0), Args, Cfg);
format_report_default(Report, Cfg) ->
    io_lib:format("~p", [summarize_term(Report, Cfg)]).

safe_fmt(Fmt0, Args0, Cfg) ->
    Fmt = normalize_format(Fmt0),
    Args = summarize_args_for_format(Fmt, Args0, Cfg),
    try
        truncate_iolist(io_lib:format(Fmt, Args), Cfg)
    catch
        C:R ->
            %% Last-resort rendering.  Never reuse the original format string here;
            %% it may contain ~s/~ts controls that are incompatible with summarized
            %% replacement terms, or with Unicode charlists produced by upstream logs.
            io_lib:format("format_failed ~p:~p fmt=~p args=~p", [
                C, R, truncate_iolist(Fmt, Cfg), summarize_args(Args0, Cfg)
            ])
    end.

normalize_format(Fmt) when is_binary(Fmt) -> binary_to_list(Fmt);
normalize_format(Fmt) when is_list(Fmt) -> Fmt;
normalize_format(Fmt) -> io_lib:format("~p", [Fmt]).

summarize_args(Args, Cfg) when is_list(Args) ->
    [summarize_term(A, Cfg) || A <- Args];
summarize_args(Args, Cfg) ->
    summarize_term(Args, Cfg).

summarize_args_for_format(Fmt, Args, Cfg) when is_list(Args) ->
    Specs = format_arg_specs(Fmt),
    summarize_args_for_format_1(Args, Specs, Cfg);
summarize_args_for_format(_Fmt, Args, Cfg) ->
    summarize_term(Args, Cfg).

summarize_args_for_format_1([], _Specs, _Cfg) ->
    [];
summarize_args_for_format_1([Arg | Rest], [Spec | Specs], Cfg) ->
    [summarize_arg_for_spec(Spec, Arg, Cfg) | summarize_args_for_format_1(Rest, Specs, Cfg)];
summarize_args_for_format_1([Arg | Rest], [], Cfg) ->
    [summarize_term(Arg, Cfg) | summarize_args_for_format_1(Rest, [], Cfg)].

%% Extract one argument-consuming control char per directive. This is intentionally
%% conservative: it only needs enough knowledge to keep ~s/~ts arguments as
%% strings/binaries while allowing ~p/~w terms to be summarized aggressively.
format_arg_specs(Fmt) ->
    format_arg_specs(Fmt, []).

format_arg_specs([], Acc) ->
    lists:reverse(Acc);
format_arg_specs([$~, $~ | T], Acc) ->
    format_arg_specs(T, Acc);
format_arg_specs([$~, $n | T], Acc) ->
    format_arg_specs(T, Acc);
format_arg_specs([$~, $i | T], Acc) ->
    format_arg_specs(T, Acc);
format_arg_specs([$~ | T], Acc) ->
    {Spec, Rest} = take_format_spec(T),
    case Spec of
        none -> format_arg_specs(Rest, Acc);
        _ -> format_arg_specs(Rest, [Spec | Acc])
    end;
format_arg_specs([_ | T], Acc) ->
    format_arg_specs(T, Acc).

take_format_spec([]) ->
    {none, []};
take_format_spec([$t, C | Rest]) when C =:= $s; C =:= $p; C =:= $w -> {C, Rest};
take_format_spec([C | Rest]) when
    C =:= $s;
    C =:= $p;
    C =:= $w;
    C =:= $W;
    C =:= $P;
    C =:= $c;
    C =:= $f;
    C =:= $e;
    C =:= $g;
    C =:= $b;
    C =:= $B;
    C =:= $x;
    C =:= $X;
    C =:= $+;
    C =:= $#
->
    {C, Rest};
take_format_spec([_ | Rest]) ->
    take_format_spec(Rest).

summarize_arg_for_spec($s, Arg, Cfg) ->
    string_arg(Arg, Cfg);
summarize_arg_for_spec($c, Arg, _Cfg) when is_integer(Arg) ->
    Arg;
summarize_arg_for_spec(_Spec, Arg, Cfg) ->
    summarize_term(Arg, Cfg).

string_arg(Bin, Cfg) when is_binary(Bin) ->
    cap_binary(Bin, maps:get(max_string, Cfg, 512));
string_arg(List, Cfg) when is_list(List) ->
    Max = maps:get(max_string, Cfg, 512),
    %% Plain ~s is Latin-1 oriented.  Unicode charlists such as [9888] can crash
    %% io_lib:format/2 with badarg.  Convert to UTF-8 binary and cap bytes.
    case safe_unicode(List) of
        Bin when byte_size(Bin) > Max ->
            Suffix = <<"...">>,
            Head = binary:part(Bin, 0, Max),
            <<Head/binary, Suffix/binary>>;
        Bin ->
            Bin
    end;
string_arg(Other, Cfg) ->
    string_arg(io_lib:format("~p", [summarize_term(Other, Cfg)]), Cfg).

summarize_term(Term, Cfg) ->
    try
        log_utils:summarize(Term, summarize_opts(Cfg))
    catch
        _:_ -> Term
    end.

summarize_opts(Cfg) ->
    #{
        depth => maps:get(depth, Cfg, 6),
        max_binary => maps:get(max_binary, Cfg, 128),
        max_string => maps:get(max_string, Cfg, 512),
        max_list => maps:get(max_list, Cfg, 24),
        max_map => maps:get(max_map, Cfg, 32),
        max_tuple => maps:get(max_tuple, Cfg, 24)
    }.

truncate_iolist(Io, Cfg) ->
    cap_binary(safe_unicode(Io), maps:get(max_text_chars, Cfg, 4096)).

cap_binary(Bin, Max) when is_binary(Bin), is_integer(Max), Max > 0 ->
    Size = byte_size(Bin),
    case Size > Max of
        true ->
            Omitted = Size - Max,
            Head = binary:part(Bin, 0, Max),
            Suffix = iolist_to_binary(io_lib:format("\n... <truncated ~B bytes>", [Omitted])),
            <<Head/binary, Suffix/binary>>;
        false ->
            Bin
    end;
cap_binary(Bin, _Max) ->
    Bin.

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
