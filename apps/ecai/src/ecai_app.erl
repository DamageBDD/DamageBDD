-module(ecai_app).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-behaviour(application).

-export([start/2, stop/1]).
-export([start_phase/3]).

-include_lib("kernel/include/logger.hrl").

start(_StartType, _StartArgs) -> ecai_sup:start_link().
get_trails() ->
    Handlers =
        [
            ecai_api,
            ecai_dashboard
        ],
    Trails =
        [
            {"/terms", cowboy_static, {priv_file, damage, "static/terms.html"}}
            | trails:trails(Handlers)
        ],
    trails:store(Trails),
    trails:single_host_compile(Trails).

start_phase(start_trails_http, _StartType, []) ->
    ?LOG_INFO("Starting Ecai."),
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(yamerl),
    {ok, _} = application:ensure_all_started(prometheus_cowboy),
    {ok, _} = application:ensure_all_started(cowboy_telemetry),
    {ok, _} = application:ensure_all_started(erlexec),
    {ok, _} = application:ensure_all_started(throttle),
    {ok, _} = application:ensure_all_started(gproc),
    Dispatch = get_trails(),
    {ok, WsPort} = application:get_env(ecai, port),
    {ok, _} =
        cowboy:start_clear(
            http_ecai,
            [{port, WsPort}],
            #{
                env => #{dispatch => Dispatch},
                metrics_callback => fun prometheus_cowboy2_instrumenter:observe/1,
                stream_handlers =>
                    [cowboy_telemetry_h, cowboy_metrics_h, cowboy_stream_h]
            }
        ),
    metrics:init(),
    ?LOG_INFO("Started ECAI cowboy.").

stop(_State) ->
    ok = cowboy:stop_listener(http),
    application:stop(gun),
    ok.

%% internal functions
