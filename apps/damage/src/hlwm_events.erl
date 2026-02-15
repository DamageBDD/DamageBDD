%%%-------------------------------------------------------------------
%%%  hlwm_events.erl
%%%  Event monitor: spawns `herbstclient --idle` and parses events
%%%-------------------------------------------------------------------
-module(hlwm_events).
-author("Steven Joseph <steven@damagebdd.com>").

-copyright("Steven Joseph <steven@damagebdd.com>").

-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-behaviour(gen_server).
-define(NOTIFY_ID, "42").
-define(NOTIFY_TIMEOUT, "1000").

-export([start_link/1, get_or_start/1]).
-export([init/1, handle_call/3, handle_info/2, handle_cast/2, terminate/2, code_change/3]).
-export([test/0]).

-record(state, {port, hooks = #{}, events = [], max_events = 256}).
notify_dunst(Msg) ->
    RunOpts = [sync, stderr],
    {ok, []} = exec:run(
        [
            "/usr/sbin//notify-send",
            "-t",
            ?NOTIFY_TIMEOUT,
            "-r",
            ?NOTIFY_ID,
            "-a",
            "erm",
            Msg
        ],
        RunOpts
    ).

%% in init/1, after you build Port and register with gproc:
init([_Ctx]) ->
    process_flag(trap_exit, true),
    Port = open_port(
        {spawn, "herbstclient --idle"},
        [{line, 1024}, exit_status, use_stdio, stderr_to_stdout]
    ),
    gproc:reg({n, l, {hlwm_events, monitor}}),

    %% Default hook: desktop (tag) switch notifications via dunst
    DeskHook = fun(Evt) ->
        case maps:get(type, Evt, undefined) of
            "tag_changed" ->
                Name = maps:get(name, Evt, ""),
                {ok, []} = notify_dunst(io_lib:format("Workspace: ~s", [Name])),
                ok;
            _ ->
                ok
        end
    end,

    {ok, #state{port = Port, hooks = #{desktop_notify => DeskHook}}}.

get_or_start(Context) ->
    case gproc:where({n, l, {hlwm_events, monitor}}) of
        undefined ->
            {ok, Pid} = gen_server:start_link(?MODULE, [Context], []),
            Pid;
        Pid ->
            Pid
    end.

start_link(Context) -> gen_server:start_link(?MODULE, [Context], []).

handle_call({add_hook, Id, Fun}, _From, S = #state{hooks = H}) when is_function(Fun, 1) ->
    {reply, ok, S#state{hooks = maps:put(Id, Fun, H)}};
handle_call({get, events}, _From, S = #state{events = E}) ->
    {reply, E, S};
handle_call({query, focused_title}, _From, S) ->
    Title = string:trim(os:cmd("herbstclient attr clients.focus.title")),
    {reply, {ok, Title}, S};
handle_call(_Any, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info({Port, {data, {eol, Line}}}, S = #state{port = Port}) ->
    case parse_event(Line) of
        {ok, Evt} ->
            S1 = push_event(Evt, S),
            broadcast(Evt, S1),
            {noreply, S1};
        _ ->
            {noreply, S}
    end;
handle_info({'EXIT', Port, _Status}, _State = #state{port = Port}) ->
    ?LOG_WARNING("hlwm port exited; restarting", []),
    {ok, S1} = init([#{}]),
    {noreply, S1};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(Reason, _S) ->
    ?LOG_INFO("hlwm_events terminating ~p", [Reason]),
    ok.
code_change(_V, S, _E) -> {ok, S}.

push_event(E, S = #state{events = Evts, max_events = Max}) ->
    Evts1 =
        case length(Evts) < Max of
            true -> [E | Evts];
            false -> [E | lists:sublist(Evts, Max - 1)]
        end,
    S#state{events = Evts1}.

broadcast(Evt, #state{hooks = Hooks}) ->
    maps:map(fun(_K, Fun) -> catch Fun(Evt) end, Hooks),
    ok.

%%
%% Example lines (from `herbstclient --idle`):
%%  focus_changed 0x58026c6 1
%%  window_title_changed 0x58026c6 "ChatGPT - DamageBDD – Ablaze Floorp"
%%  tag_changed 4 staging
%%
parse_event(Line) ->
    Tokens = string:tokens(Line, " \t"),
    case Tokens of
        ["focus_changed", WinIdStr, _Idx] ->
            {ok, #{type => "focus_changed", win_id => WinIdStr}};
        ["window_title_changed", WinIdStr | Rest] ->
            Title = string:trim(string:join(Rest, " "), both, "\""),
            {ok, #{type => "window_title_changed", win_id => WinIdStr, title => Title}};
        ["tag_changed", Index, Name] ->
            {ok, #{type => "tag_changed", index => Index, name => Name}};
        [Other | _] ->
            {ok, #{type => Other, raw => Line}};
        _ ->
            {error, nomatch}
    end.
test() ->
    notify_dunst("test erm notification").
