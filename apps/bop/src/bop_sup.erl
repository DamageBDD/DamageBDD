%%-------------------------------------------------------------------
%% @doc BoP top level supervisor.
%% @end
%% https://erlang.org/doc/man/supervisor.html
%%%-------------------------------------------------------------------

-module(bop_sup).

-author("Steven Joseph <steven@bitcoinonly.party>").

-copyright("Steven Joseph <steven@bitcoinonly.party>").

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
    {ok, Pools} = application:get_env(bop, pools),
    ?LOG_DEBUG("Starting BoP workers ~p~n", [Pools]),
    SupFlags = {one_for_one, 10, 10},
    PoolSpecs =
        lists:map(
            fun({Name, SizeArgs, WorkerArgs}) ->
                PoolArgs = [{name, {local, Name}}, {worker_module, Name}] ++ SizeArgs,
                poolboy:child_spec(Name, PoolArgs, WorkerArgs)
            end,
            Pools
        ),
    PoolSpecs0 =
        [
            %#{
            %    % mandatory
            %    id => bop,
            %    % mandatory
            %    start => {bop, start_link, []},
            %    % optional
            %    restart => permanent,
            %    % optional
            %    shutdown => 60,
            %    % optional
            %    type => worker,
            %    modules => []
            %}
        ] ++
            PoolSpecs,
    %?LOG_DEBUG("Worker definitions ~p~n", [PoolSpecs0]),
    {ok, {SupFlags, PoolSpecs0}}.
