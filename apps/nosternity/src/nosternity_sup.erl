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
    SupFlags = #{
        strategy => one_for_one,
        intensity => 1000,
        period => 60
    },
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
        [
            #{
                id => nosternity_nostr,
                start => {damage_nostr, start_link, [nosternity_nostr_nsec]},
                restart => transient,
                shutdown => 60000,
                type => worker,
                modules => [damage_nostr]
            },
            #{
                id => inglorious_nostr,
                start => {damage_nostr, start_link, [inglorious_nostr_nsec]},
                restart => transient,
                shutdown => 60000,
                type => worker,
                modules => [damage_nostr]
            }
        ] ++
            PoolSpecs,

    ?LOG_DEBUG("Worker definitions ~p~n", [PoolSpecs0]),
    case whereis(nostr_pool) of
        undefined ->
            ?LOG_WARNING("damage-supervised nostr_pool is not running");
        Pid ->
            ?LOG_DEBUG("Using damage-supervised nostr_pool pid=~p", [Pid])
    end,
    {ok, {SupFlags, PoolSpecs0}}.
