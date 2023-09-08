%%%-------------------------------------------------------------------
%% @doc damage public API
%% @end
%%%-------------------------------------------------------------------

-module(damage_app).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([execute/2]).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
  application:start(?MODULE),
  {ok, _} = application:ensure_all_started(gun),
  {ok, _} = application:ensure_all_started(cedb),
  {ok, _} = application:ensure_all_started(p1_utils),
  {ok, _} = application:ensure_all_started(fast_yaml),
  {ok, _} = application:ensure_all_started(prometheus),
  {ok, _} = application:ensure_all_started(prometheus_cowboy),
  metrics:init(),
  Dispatch =
    cowboy_router:compile(
      [
        {
          '_',
          [
            {"/", cowboy_static, {priv_file, damage, "static/dealdamage.html"}},
            {"/api/execute_feature/", damage_http, []},
            {"/metrics/[:registry]", prometheus_cowboy2_handler, []}
          ]
        }
      ]
    ),
  {ok, WsPort} = application:get_env(damage, port),
  {ok, _} =
    cowboy:start_clear(
      http,
      [{port, WsPort}],
      #{
        env => #{dispatch => Dispatch},
        metrics_callback => fun prometheus_cowboy2_instrumenter:observe/1,
        stream_handlers => [cowboy_metrics_h, cowboy_stream_h]
      }
    ),
  damage_sup:start_link().


stop(_State) ->
  application:stop(gun),
  ok.

%% internal functions

execute(_FeatureName, 0) -> logger:info("ending.", []);

execute(FeatureName, Count) ->
  logger:info("starting transaction ~p.", [Count]),
  poolboy:transaction(
    bdd,
    fun (Worker) -> gen_server:call(Worker, {execute, FeatureName}) end
  ),
  execute(FeatureName, Count - 1).
