-module(nosternity_app).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-behaviour(application).

-export([start/2, stop/1]).
-export([start_phase/3]).

-include_lib("kernel/include/logger.hrl").

start(_StartType, _StartArgs) -> nosternity_sup:start_link().
get_trails() ->
    Handlers =
        [
            nosternity_http
        ],
    Trails =
        [
            {"/nostr", nostr_websocket, #{}},
            {"/", cowboy_static, {priv_file, nosternity, "static/nosternity.html"}}
            | trails:trails(Handlers)
        ],
    trails:store(Trails),
    trails:single_host_compile(Trails).

start_phase(start_trails_http, _StartType, []) ->
    ?LOG_INFO("Starting Damage."),
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(yamerl),
    {ok, _} = application:ensure_all_started(prometheus_cowboy),
    {ok, _} = application:ensure_all_started(cowboy_telemetry),
    {ok, _} = application:ensure_all_started(erlexec),
    {ok, _} = application:ensure_all_started(throttle),
    {ok, _} = application:ensure_all_started(gproc),
    Dispatch = get_trails(),
    WsPort = application:get_env(nosternity, port, 9001),
    WsIp = application:get_env(nosternity, ip, {127, 0, 0, 1}),
    {ok, _} =
        cowboy:start_clear(
            http_nosternity,
            [{ip, WsIp}, {port, WsPort}],
            #{
                env => #{dispatch => Dispatch},
                metrics_callback => fun prometheus_cowboy2_instrumenter:observe/1,
                stream_handlers =>
                    [cowboy_telemetry_h, cowboy_metrics_h, cowboy_stream_h]
            }
        ),
    metrics:init(),
    ?LOG_INFO("Started Nostrernity cowboy.");
start_phase(os_tune, _StartType, []) ->
    ?LOG_INFO("Tuning os."),
    {ok, _} = exec:run("ulimit -n 1000000", [sync]),
    ok.

stop(_State) ->
    ok = cowboy:stop_listener(http_nosternity),
    application:stop(gun),
    ok.

%% internal functions
