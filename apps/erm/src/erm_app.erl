%%%-------------------------------------------------------------------
%% @doc ERM application callback module.
%% @end
%%%-------------------------------------------------------------------

-module(erm_app).

-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-behaviour(application).

-export([start/2, stop/1]).
-export([start_phase/3]).
-export([get_trails/0]).

-include_lib("kernel/include/logger.hrl").

start(_StartType, _StartArgs) ->
    erm_sup:start_link().

get_trails() ->
    Handlers = [erm_http],
    Trails = trails:trails(Handlers),
    trails:store(Trails),
    trails:single_host_compile(Trails).
start_phase(Phase, StartType, Args) ->
    case enabled() of
        true ->
            start_phase_enabled(Phase, StartType, Args);
        false ->
            ?LOG_NOTICE("erm disabled; skipping start phase ~p", [Phase]),
            ok
    end.

start_phase_enabled(start_trails_http, _StartType, []) ->
    %% Normally gtknode4_sup is present from erm_sup:init/1. Reconciliation is
    %% intentionally idempotent and also covers configuration loaded or changed
    %% after the supervisor child list was originally constructed.
    case erm_sup:sync_gtknode4() of
        {ok, GtkPid} ->
            ?LOG_INFO("Supervised gtknode4 session is running as ~p", [GtkPid]);
        ok ->
            ?LOG_DEBUG("gtknode4 configuration reconciled", []);
        {error, SyncReason} ->
            ?LOG_WARNING("Could not reconcile gtknode4 configuration: ~p", [SyncReason])
    end,
    lists:foreach(fun ensure_runtime_app/1, [gun, gproc, erlexec]),
    case start_http_listener() of
        ok ->
            ok;
        {error, HttpReason} ->
            case application:get_env(erm, http_required, false) of
                true ->
                    {error, {http_listener_failed, HttpReason}};
                false ->
                    ?LOG_WARNING(
                        "ERM HTTP listener is unavailable; continuing without HTTP: ~p",
                        [HttpReason]
                    ),
                    ok
            end
    end.

enabled() ->
    case application:get_env(erm, enabled, true) of
        true -> true;
        false -> false;
        Invalid ->
            ?LOG_WARNING("Ignoring invalid erm.enabled value: ~p; defaulting to true", [Invalid]),
            true
    end.

stop(_State) ->
    %% The application controller has already shut down erm_sup, including
    %% gtknode4_sup and the local native process, before this callback runs.
    best_effort(fun() -> cowboy:stop_listener(http_erm) end),
    best_effort(fun() -> application:stop(gun) end),
    best_effort(fun() -> persistent_term:erase(erm_wx_env) end),
    best_effort(fun() -> wx:destroy() end),
    ok.

best_effort(Fun) when is_function(Fun, 0) ->
    try Fun() of
        _ -> ok
    catch
        _:_ -> ok
    end.

ensure_runtime_app(App) ->
    try application:ensure_all_started(App) of
        {ok, _Started} -> ok;
        {error, AppReason} ->
            ?LOG_WARNING("Optional ERM runtime application ~p is unavailable: ~p", [
                App, AppReason
            ]),
            ok
    catch
        Class:ExceptionReason:Stacktrace ->
            ?LOG_WARNING("Could not start optional ERM runtime application ~p: ~p", [
                App, {Class, ExceptionReason, Stacktrace}
            ]),
            ok
    end.

start_http_listener() ->
    case application:get_env(erm, http_enabled, true) of
        false ->
            ?LOG_INFO("erm HTTP listener disabled by configuration", []),
            ok;
        true ->
            start_http_listener_enabled();
        Invalid ->
            ?LOG_WARNING("Ignoring invalid erm.http_enabled value: ~p; defaulting to true", [Invalid]),
            start_http_listener_enabled()
    end.

start_http_listener_enabled() ->
    try
        Dispatch = get_trails(),
        WsPort = application:get_env(erm, port, 9000),
        WsIp = application:get_env(erm, ip, {127, 0, 0, 1}),
        case cowboy:start_clear(
            http_erm,
            [{ip, WsIp}, {port, WsPort}],
            #{env => #{dispatch => Dispatch}}
        ) of
            {ok, _Pid} ->
                ?LOG_INFO("Started erm Cowboy listener on ~p:~p", [WsIp, WsPort]),
                ok;
            {error, {already_started, _Pid}} ->
                ?LOG_DEBUG("erm Cowboy listener is already running on ~p:~p", [WsIp, WsPort]),
                ok;
            {error, ListenerReason} ->
                {error, ListenerReason};
            Other ->
                {error, {unexpected_cowboy_result, Other}}
        end
    catch
        Class:ExceptionReason:Stacktrace ->
            {error, {Class, ExceptionReason, Stacktrace}}
    end.
