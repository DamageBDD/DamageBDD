-module(ecai_app).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-behaviour(application).

-export([start/2, stop/1]).
-export([start_phase/3]).
-export([reload_router/0]).

-include_lib("kernel/include/logger.hrl").

start(_StartType, _StartArgs) ->
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(poolboy),
    ecai_sup:start_link().

get_trails() ->
    {ok, _} = application:ensure_all_started(poolboy),

    Handlers =
        [
            ecai_api,
            ecai_yelp_admin,
            ecai_dashboard,
            ecai_chat_http_handler
        ],
    Trails =
        [
            {"/terms", cowboy_static, {priv_file, ecai, "static/terms.html"}},
            {"/static/[...]", cowboy_static, {priv_dir, ecai, "static/"}},
            {"/ecai/ws/", ecai_ws, #{}}
            | trails:trails(Handlers)
        ],
    trails:store(Trails),
    trails:single_host_compile(Trails).

start_phase(start_trails_http, _StartType, []) ->
    ?LOG_INFO("Starting Ecai."),
    {ok, _} = application:ensure_all_started(yamerl),
    {ok, _} = application:ensure_all_started(prometheus_cowboy),
    {ok, _} = application:ensure_all_started(cowboy_telemetry),
    {ok, _} = application:ensure_all_started(erlexec),
    {ok, _} = application:ensure_all_started(throttle),
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(os_mon),
    %% Set to 90%
    memsup:set_sysmem_high_watermark(0.90),
    %% Set to 10%
    memsup:set_procmem_high_watermark(0.10),

    WsPort = application:get_env(ecai, port, 9003),
    WsIp = application:get_env(ecai, ip, {127, 0, 0, 1}),
    {ok, _} =
        cowboy:start_clear(
            http_ecai,
            [{ip, WsIp}, {port, WsPort}],
            #{
                env => #{dispatch => get_trails()},
                metrics_callback => fun prometheus_cowboy2_instrumenter:observe/1,
                stream_handlers =>
                    [cowboy_telemetry_h, cowboy_metrics_h, cowboy_stream_h]
            }
        ),
    metrics:init(),
    ?LOG_INFO("Started ECAI cowboy.").

stop(_State) ->
    ok = cowboy:stop_listener(http_ecai),
    application:stop(gun),

    ok.

%% internal functions
reload_router() ->
    %% 1) rebuild trails and compile
    Dispatch = get_trails(),
    [{'_', [], Trails}] = Dispatch,

    %% 2) apply to running listener (default name 'http')
    ok = cowboy:set_env(http_ecai, dispatch, Dispatch),
    io:format("~n[+] Cowboy router reloaded (~p routes)~n", [length(Trails)]),
    ok.
