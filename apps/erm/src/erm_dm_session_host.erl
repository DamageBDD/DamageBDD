%%%-------------------------------------------------------------------
%%% Persistent X11 session host.
%%%
%%% This process is intentionally separate from the normal erm.service. It owns
%%% Xorg + the WM lifetime, publishes the environment to systemd --user, and
%%% starts graphical-session.target. Restarting normal ERM cannot affect it.
%%%-------------------------------------------------------------------
-module(erm_dm_session_host).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/1, start_link/0, status/0, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {session, xorg = undefined, wm = undefined, display = undefined,
                xauthority = undefined, phase = starting, started_mono}).

start_link() -> start_link(default_session_id()).
start_link(SessionId) -> gen_server:start_link({local, ?MODULE}, ?MODULE, [SessionId], []).
status() -> gen_server:call(?MODULE, status).
stop() -> gen_server:call(?MODULE, stop, 10000).

init([SessionId]) ->
    process_flag(trap_exit, true),
    case erm_dm_sessions:lookup(SessionId) of
        {ok, Session} ->
            self() ! start_session,
            {ok, #state{session = Session, started_mono = erlang:monotonic_time(millisecond)}};
        Error -> {stop, Error}
    end.

handle_call(status, _From, S) -> {reply, snapshot(S), S};
handle_call(stop, _From, S) -> {stop, normal, ok, S};
handle_call(_, _, S) -> {reply, {error, unsupported_call}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(start_session, S0) ->
    case erm_dm_xorg:start_user_display() of
        {ok, X = #{port := XPort, display := Display, xauthority := XA}} ->
            link(XPort),
            case publish_env(Display, XA, maps:get(desktop, S0#state.session)) of
                ok ->
                    _ = erm_dm_ops:systemctl_user(["start", "graphical-session.target"]),
                    case start_wm(S0#state.session, Display, XA) of
                        {ok, WmPort} -> link(WmPort), {noreply, S0#state{xorg = XPort, wm = WmPort,
                            display = Display, xauthority = XA, phase = running}};
                        Error -> {stop, {window_manager_failed, Error}, S0#state{xorg = XPort}}
                    end;
                Error -> {stop, {environment_publish_failed, Error}, S0#state{xorg = XPort}}
            end;
        Error -> {stop, {xorg_failed, Error}, S0}
    end;
handle_info({Port, {exit_status, Status}}, S = #state{wm = Port}) ->
    {stop, {window_manager_exit, Status}, S#state{wm = undefined}};
handle_info({Port, {exit_status, Status}}, S = #state{xorg = Port}) ->
    {stop, {xorg_exit, Status}, S#state{xorg = undefined}};
handle_info({'EXIT', Port, Reason}, S = #state{wm = Port}) -> {stop, {window_manager_exit, Reason}, S};
handle_info({'EXIT', Port, Reason}, S = #state{xorg = Port}) -> {stop, {xorg_exit, Reason}, S};
handle_info(_, S) -> {noreply, S}.

terminate(_Reason, S) ->
    _ = erm_dm_ops:systemctl_user(["stop", "graphical-session.target"]),
    _ = unset_env(),
    close_port(S#state.wm), close_port(S#state.xorg),
    case S#state.xauthority of undefined -> ok; XA -> file:delete(binary_to_list(XA)) end,
    ok.
code_change(_, S, _) -> {ok, S}.

start_wm(Session, Display, XA) ->
    Cmd = binary_to_list(maps:get(command, Session)),
    Args = [binary_to_list(A) || A <- maps:get(args, Session, [])],
    Env = [{"DISPLAY", binary_to_list(Display)}, {"XAUTHORITY", binary_to_list(XA)},
           {"XDG_SESSION_TYPE", "x11"}, {"XDG_CURRENT_DESKTOP", binary_to_list(maps:get(desktop, Session))},
           {"XDG_SESSION_DESKTOP", binary_to_list(maps:get(desktop, Session))},
           {"DESKTOP_SESSION", binary_to_list(maps:get(desktop, Session))}],
    case filelib:is_regular(Cmd) of
        true -> {ok, open_port({spawn_executable, Cmd}, [binary, exit_status, stderr_to_stdout, {args, Args}, {env, Env}])};
        false -> {error, {missing_session_command, Cmd}}
    end.

publish_env(Display, XA, Desktop) ->
    lists:foreach(fun({K,V}) -> os:putenv(K, V) end,
        [{"DISPLAY", binary_to_list(Display)}, {"XAUTHORITY", binary_to_list(XA)},
         {"XDG_SESSION_TYPE", "x11"}, {"XDG_CURRENT_DESKTOP", binary_to_list(Desktop)},
         {"XDG_SESSION_DESKTOP", binary_to_list(Desktop)}, {"DESKTOP_SESSION", binary_to_list(Desktop)}]),
    Args = ["import-environment", "DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR",
            "DBUS_SESSION_BUS_ADDRESS", "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP",
            "XDG_SESSION_TYPE", "DESKTOP_SESSION"],
    case erm_dm_ops:systemctl_user(Args) of {ok, _} -> ok; Error -> Error end.

unset_env() -> erm_dm_ops:systemctl_user(["unset-environment", "DISPLAY", "XAUTHORITY",
    "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "XDG_SESSION_TYPE", "DESKTOP_SESSION"]).

snapshot(S) -> #{phase => S#state.phase, display => S#state.display,
                 xauthority_present => S#state.xauthority =/= undefined,
                 xorg_alive => is_port(S#state.xorg), wm_alive => is_port(S#state.wm),
                 session => maps:with([id,label,desktop], S#state.session)}.
close_port(undefined) -> ok;
close_port(P) when is_port(P) -> catch port_close(P), ok.
default_session_id() ->
    Config = application:get_env(erm, display_manager, []),
    unicode:characters_to_binary(proplists:get_value(default_session, Config, "herbstluftwm")).
