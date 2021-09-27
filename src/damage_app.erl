%%%-------------------------------------------------------------------
%% @doc damage public API
%% @end
%%%-------------------------------------------------------------------

-module(damage_app).

-export([execute/2]).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
  application:start(?MODULE),
  application:ensure_all_started(hackney),
  application:ensure_all_started(gun),
  application:ensure_all_started(cedb),
  application:ensure_all_started(p1_utils),
  application:ensure_all_started(fast_yaml),
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
