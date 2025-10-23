%%-------------------------------------------------------------------
%% @doc nosternity top level supervisor.
%% @end
%% https://erlang.org/doc/man/supervisor.html
%%%-------------------------------------------------------------------

-module(nosternity_sup).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-behaviour(supervisor).

-include_lib("kernel/include/logger.hrl").

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
    SupFlags = {one_for_one, 10, 10},
    Pools = application:get_env(nosternity, pools, []),
    ?LOG_DEBUG("Starting erm workers ~p~n", [Pools]),
    PoolSpecs =
        lists:map(
            fun({Name, SizeArgs, WorkerArgs}) ->
                PoolArgs = [{name, {local, Name}}, {worker_module, Name}] ++ SizeArgs,
                poolboy:child_spec(Name, PoolArgs, WorkerArgs)
            end,
            Pools
        ),

    PoolSpecs0 =
        [] ++
            PoolSpecs,

    ?LOG_DEBUG("Worker definitions ~p~n", [PoolSpecs0]),
    {ok, {SupFlags, PoolSpecs0}}.
