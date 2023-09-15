%%%-------------------------------------------------------------------
%% @doc damage top level supervisor.
%% @end
%% https://erlang.org/doc/man/supervisor.html
%%%-------------------------------------------------------------------

-module(damage_sup).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() -> supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional

init([]) ->
  {ok, Pools} = application:get_env(damage, pools),
  PoolSpecs =
    lists:map(
      fun
        ({Name, SizeArgs, WorkerArgs}) ->
          PoolArgs = [{name, {local, Name}}, {worker_module, Name}] ++ SizeArgs,
          poolboy:child_spec(Name, PoolArgs, WorkerArgs)
      end,
      Pools
    ),
  {ok, {{one_for_one, 10, 10}, PoolSpecs}}.

%%SupFlags = #{strategy => one_for_one, intensity => 0, period => 1},
%%ChildSpecs =
%%  [
%%    % optional
%%    #{
%%      % mandatory
%%      id => default,
%%      % mandatory
%%      start => {damage_app, execute, []},
%%      % optional
%%      restart => temporary,
%%      % optional
%%      shutdown => 60,
%%      % optional
%%      type => worker,
%%      modules => [damage_app]
%%    }
%%  ],
%%{ok, {SupFlags, ChildSpecs}}.
%% internal functions
