%%%-------------------------------------------------------------------
%%%  steps_x11_time.erl
%%%  DamageBDD steps to control/verify X11 time tracking
%%%-------------------------------------------------------------------
-module(steps_x11_time).
-behaviour(gen_server).
-export([step/6]).
-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

%% Optional server: subscribe to hlwm_events and forward into x11_time
-export([
    start_link/1,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).
-export([
    hook/1
]).

-define(NAME, {n, l, {?MODULE, monitor}}).

start_link(Context) -> gen_server:start_link({local, ?MODULE}, ?MODULE, [Context], []).
init([Context]) ->
    process_flag(trap_exit, true),
    gproc:reg(?NAME),
    {ok, _Pid} = x11_time:get_or_start(Context),
    %% hook into existing hlwm_events like steps_herbstluftwm does
    Pid = hlwm_events:get_or_start(Context),
    ok = gen_server:call(Pid, {add_hook, x11_time, fun ?MODULE:hook/1}),
    {ok, Context}.

handle_call(_Req, _From, S) -> {reply, ok, S}.
handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.
terminate(_R, _S) -> ok.
code_change(_V, S, _E) -> {ok, S}.

hook(Evt = #{type := _}) ->
    gen_server:cast(x11_time, {hlwm_event, normalize(Evt)}),
    ok.

normalize(#{type := T} = E) ->
    %% Ensure binaries for downstream
    maps:from_list([{K, to_bin(V)} || {K, V} <- maps:to_list(E#{type := to_bin(T)})]).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

ensure_started(Ctx) ->
    case gproc:lookup_local_name(?NAME) of
        undefined -> {ok, _} = start_link(Ctx);
        _ -> ok
    end,
    ok.

%%% ================= Steps =================

step(_Cfg, Ctx, _Kw, _N, ["I start x11 time tracker"], _Body) ->
    ok = ensure_started(Ctx),
    Ctx;
step(_Cfg, Ctx, <<"When">>, _N, ["I reset x11 time usage"], _Body) ->
    ok = x11_time:reset(),
    Ctx;
step(_Cfg, Ctx, <<"When">>, _N, ["I alias x11 app", Alias, "to classes", ClassesCsv], _Body) ->
    Classes = [list_to_binary(string:trim(S)) || S <- string:split(ClassesCsv, ",", all)],
    ok = x11_time:add_alias(list_to_binary(Alias), Classes),
    Ctx;
step(_Cfg, Ctx, <<"Then">>, _N, ["x11 time for class", Class, "should be at least", MinStr], _Body) ->
    Summary = x11_time:summary(),
    ByClass = maps:get(by_class, Summary, #{}),
    Val = maps:get(list_to_binary(Class), ByClass, 0),
    Min = parse_dur(MinStr),
    case Val >= Min of
        true ->
            Ctx;
        false ->
            Msg = io_lib:format("x11 ~s was ~Bs (< ~Bs)", [Class, human(Val), human(Min)]),
            maps:put(fail, lists:flatten(Msg), Ctx)
    end;
step(_Cfg, Ctx, <<"Then">>, _N, ["x11 time for alias", Alias, "should be under", MaxStr], _Body) ->
    Summary = x11_time:summary(),
    ByClass = maps:get(by_class, Summary, #{}),
    Val = maps:get(list_to_binary(Alias), ByClass, 0),
    Max = parse_dur(MaxStr),
    case Val =< Max of
        true ->
            Ctx;
        false ->
            Msg = io_lib:format("x11 alias ~s was ~Bs (> ~Bs)", [Alias, human(Val), human(Max)]),
            maps:put(fail, lists:flatten(Msg), Ctx)
    end;
step(_Cfg, Ctx, <<"Then">>, _N, ["I print x11 usage summary"], _Body) ->
    #{by_class := BC, by_title := BT} = x11_time:summary(),
    ?LOG_INFO("X11 by_class=~p", [pretty(BC)]),
    ?LOG_INFO("X11 by_title=~p", [pretty(BT)]),
    Ctx;
%% Notify via notify-send if time exceeds limit
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _N,
    ["notify if x11 time for", Target, Name, "exceeds", LimitStr, "with", Msg],
    _Body
) ->
    Summary = x11_time:summary(),
    ByClass = maps:get(by_class, Summary, #{}),
    ByTitle = maps:get(by_title, Summary, #{}),
    Val =
        case Target of
            "class" -> maps:get(list_to_binary(Name), ByClass, 0);
            "alias" -> maps:get(list_to_binary(Name), ByClass, 0);
            "title" -> maps:get(list_to_binary(Name), ByTitle, 0);
            _ -> 0
        end,
    Limit = parse_dur(LimitStr),
    case Val > Limit of
        true ->
            _ = os:cmd("notify-send 'Time Limit Exceeded' '" ++ Msg ++ "'"),
            Ctx;
        false ->
            Ctx
    end;
%% ===== Generic class+title steps =====
%% Assert: time for <Class> titles matching <Regex> under <Dur>
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _N,
    ["x11 time for", Class, "titles matching", Regex, "should be under", LimitStr],
    _Body
) ->
    Val = sum_class_regex(Class, Regex),
    Limit = parse_dur(LimitStr),
    case Val =< Limit of
        true ->
            Ctx;
        false ->
            Msg = io_lib:format("~s(~s) ~Bs (> ~Bs)", [Class, Regex, human(Val), human(Limit)]),
            maps:put(fail, lists:flatten(Msg), Ctx)
    end;
%% Assert: time for <Class> titles matching <Regex> at least <Dur>
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _N,
    ["x11 time for", Class, "titles matching", Regex, "should be at least", MinStr],
    _Body
) ->
    Val = sum_class_regex(Class, Regex),
    Min = parse_dur(MinStr),
    case Val >= Min of
        true ->
            Ctx;
        false ->
            Msg = io_lib:format("~s(~s) ~Bs (< ~Bs)", [Class, Regex, human(Val), human(Min)]),
            maps:put(fail, lists:flatten(Msg), Ctx)
    end;
%% Notify: if time for <Class> titles matching <Regex> exceeds <Dur>
step(
    _Cfg,
    Ctx,
    <<"Then">>,
    _N,
    ["notify if x11 time for", Class, "titles matching", Regex, "exceeds", LimitStr, "with", Msg],
    _Body
) ->
    Val = sum_class_regex(Class, Regex),
    Limit = parse_dur(LimitStr),
    case Val > Limit of
        true ->
            _ = os:cmd("notify-send 'Time Limit Exceeded' '" ++ Msg ++ "'"),
            Ctx;
        false ->
            Ctx
    end.
%% ===== Generic class+title matching helpers =====

sum_class_regex(Class0, Regex) ->
    Summary = x11_time:summary(),
    BQ = maps:get(by_qual, Summary, #{}),
    Class = to_bin(Class0),
    {ok, RE} = re:compile(Regex, [unicode, caseless]),
    lists:sum([V || {K, V} <- maps:to_list(BQ), match_class_title(Class, K, RE)]).

match_class_title(Class, Key, RE) when is_binary(Key) ->
    case binary:split(Key, <<"|">>, [global, trim]) of
        [KClass, KTitle] when KClass =:= Class ->
            case re:run(KTitle, RE) of
                {match, _} -> true;
                nomatch -> false
            end;
        _ ->
            false
    end.

pretty(Map) ->
    lists:sort(
        fun({K1, V1}, {K2, V2}) -> {-V1, K1} =< {-V2, K2} end,
        [{binary_to_list(K), human(V)} || {K, V} <- maps:to_list(Map)]
    ).

parse_dur(Str) ->
    %% Accept "90s", "10m", "2h"
    {Num, Unit} = split_num_unit(Str),
    case Unit of
        <<"s">> -> Num;
        <<"m">> -> Num * 60;
        <<"h">> -> Num * 3600;
        _ -> erlang:error({bad_duration, Str})
    end.

split_num_unit(Str0) ->
    Str = list_to_binary(string:lowercase(Str0)),
    {NumBin, Unit} = {
        re:replace(Str, "[^0-9].*$", "", [{return, binary}]),
        re:replace(Str, "^[0-9]+", "", [{return, binary}])
    },
    {
        binary_to_integer(NumBin),
        case Unit of
            <<>> -> <<"s">>;
            _ -> Unit
        end
    }.

human(Secs) when is_integer(Secs) ->
    %% 1h02m03s formatting
    H = Secs div 3600,
    M = (Secs rem 3600) div 60,
    S = Secs rem 60,
    lists:flatten(
        [
            (H > 0 andalso io_lib:format("~Bh", [H]) orelse ""),
            (M > 0 andalso io_lib:format("~2..0Bm", [M]) orelse (H > 0 andalso "00m" orelse "")),
            io_lib:format("~2..0Bs", [S])
        ]
    ).
