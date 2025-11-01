%%%-------------------------------------------------------------------
%% @doc BoP public API
%% @end
%%%-------------------------------------------------------------------

-module(bop_app).

-author("Steven Joseph <steven@bitcoinonly.party>").

-copyright("Steven Joseph <steven@bitcoinonly.party>").

-license("Apache-2.0").

-behaviour(application).

-export([start/2, stop/1]).
-export([start_phase/3]).
-export([get_trails/0]).

-include_lib("kernel/include/logger.hrl").

start(_StartType, _StartArgs) -> bop_sup:start_link().

get_trails() ->
    Handlers =
        [
            bop_http
        ],
    
    Trails =
        [
            {"/bop/", cowboy_static, {priv_file, bop, "static/bop.html"}},
            {"/bop/ws/auth", lightning_auth_ws, #{}},
            {"/bop/ws/", bop_ws, #{}}
            | trails:trails(Handlers)
        ],

    trails:store(Trails),
    trails:single_host_compile(Trails).

start_phase(start_trails_http, _StartType, []) ->
    ?LOG_INFO("Starting BoP."),
    {ok, _} = application:ensure_all_started(gun),
    Dispatch = get_trails(),
    WsPort = application:get_env(bop, port, 9002),
    WsIp = application:get_env(bop, ip, {127, 0, 0, 1}),
    {ok, _} =
        cowboy:start_clear(
            http_bop,
            [{ip, WsIp}, {port, WsPort}],
            #{
                env => #{dispatch => Dispatch},
                metrics_callback => fun prometheus_cowboy2_instrumenter:observe/1,
                stream_handlers =>
                    [cowboy_telemetry_h, cowboy_metrics_h, cowboy_stream_h],
                idle_timeout => 60000
            }
        ),
    metrics:init(),
    ?LOG_INFO("Started cowboy.").

stop(_State) ->
    ok = cowboy:stop_listener(http),
    application:stop(gun),
    ok.

%% internal functions
