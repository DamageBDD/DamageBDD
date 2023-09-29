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
  logger:info("Startint Damage."),
  %{ok, _} = application:ensure_all_started(cedb),
  {ok, _} = application:ensure_all_started(fast_yaml),
  {ok, _} = application:ensure_all_started(prometheus),
  {ok, _} = application:ensure_all_started(prometheus_cowboy),
  {ok, _} = application:ensure_all_started(erlexec),
  %logger:info("Starting vanilla."),
  %code:add_patha("vanillae/ebin"),
  %{ok, _} = application:ensure_all_started(vanillae),
  %ok = vanillae:network_id("ae_uat"),
  %{ok, AeNodes} = application:get_env(ae_nodes),
  %ok = vanillae:ae_nodes(AeNodes),
  Dispatch =
    cowboy_router:compile(
      [
        {
          '_',
          [
            {"/", cowboy_static, {priv_file, damage, "static/dealdamage.html"}},
            {"/steps.json", cowboy_static, {priv_file, damage, "static/steps.json"}},
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
  logger:info("Started cowboy."),
  {ok, _} = application:ensure_all_started(gun),
  logger:info("Started Gun."),
  metrics:init(),
  logger:info("Started Damage."),
  damage_sup:start_link().


stop(_State) ->
  ok = cowboy:stop_listener(http),
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
