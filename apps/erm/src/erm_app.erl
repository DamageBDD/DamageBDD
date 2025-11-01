%%%-------------------------------------------------------------------
%% @doc damage public API
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

start(_StartType, _StartArgs) -> erm_sup:start_link().

get_trails() ->
    Handlers =
        [
            erm_http
        ],
    Trails = trails:trails(Handlers),
    trails:store(Trails),
    trails:single_host_compile(Trails).

start_phase(start_trails_http, _StartType, []) ->
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(erlexec),
    Dispatch = get_trails(),
    WsPort = application:get_env(erm, port, 9000),
    WsIp = application:get_env(erm, ip, {127, 0, 0, 1}),
    {ok, _} =
        cowboy:start_clear(
            http_erm,
            [{ip, WsIp}, {port, WsPort}],
            #{
                env => #{dispatch => Dispatch}
            }
        ),
    ?LOG_INFO("Started erm cowboy.").

stop(_State) ->
    ok = cowboy:stop_listener(http_erm),
    application:stop(gun),
    catch wx:destroy(),
    ok.
