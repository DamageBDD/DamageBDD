%%-------------------------------------------------------------------
%% @doc ecai top level supervisor.
%% @end
%% https://erlang.org/doc/man/supervisor.html
%%%-------------------------------------------------------------------

-module(ecai_sup).

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
    {ok, Pools} = application:get_env(ecai, pools),
    ?LOG_DEBUG("Starting workers ~p~n", [Pools]),
    SupFlags = {one_for_one, 10, 10},
    PoolSpecs =
        lists:map(
            fun({Name, SizeArgs, WorkerArgs}) ->
                PoolArgs = [{name, {local, Name}}, {worker_module, Name}] ++ SizeArgs,
                poolboy:child_spec(Name, PoolArgs, WorkerArgs)
            end,
            Pools
        ),
    %% snapshot path & interval configurable
    SnapPath = application:get_env(
        ecai, index_snapshot_path, "/var/lib/damage/ecai/state/ecai_index.snap"
    ),
    Interval = application:get_env(ecai, index_snapshot_ms, 60000),
    PoolSpecs0 =
        [
            #{
                id => ecai_index_snapshot,
                start =>
                    {ecai_index_snapshot, start_link, [
                        fun ecai_search_server:get_ctx/0, SnapPath, Interval
                    ]},
                restart => permanent,
                shutdown => 60,
                type => worker,
                modules => []
            },
            #{
                id => ecai_search_server,
                start => {ecai_search_server, start_link, []},
                restart => permanent,
                shutdown => 60,
                type => worker,
                modules => []
            },
            #{
                id => ecai_indexer,
                start => {ecai_indexer, start_link, []},
                restart => permanent,
                shutdown => 60,
                type => worker,
                modules => []
            }
        ] ++
            PoolSpecs,
    ?LOG_DEBUG("Worker definitions ~p~n", [PoolSpecs0]),
    {ok, {SupFlags, PoolSpecs0}}.
