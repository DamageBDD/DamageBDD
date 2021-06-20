%%%-------------------------------------------------------------------
%% @doc damage public API
%% @end
%%%-------------------------------------------------------------------

-module(damage_app).

-export([execute/1]).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    application:start(?MODULE),
  application:ensure_all_started(hackney),
  application:start(cedb),
  application:start(p1_utils),
  application:start(fast_yaml),
  damage_sup:start_link().


stop(_State) -> ok.

%% internal functions

execute([]) -> damage:execute().
