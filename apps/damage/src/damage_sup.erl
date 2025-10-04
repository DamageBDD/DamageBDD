%%-------------------------------------------------------------------
%% @doc damage top level supervisor.
%% @end
%% https://erlang.org/doc/man/supervisor.html
%%%-------------------------------------------------------------------

-module(damage_sup).

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
    {ok, Pools} = application:get_env(damage, pools),
    ?LOG_DEBUG("Starting workers ~p~n", [Pools]),
    {ok, AbducoWorkers} = application:get_env(damage, abduco_workers),
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
    PoolSpecs0 =
        [
            #{
                % mandatory
                id => secrets,
                % mandatory
                start => {secrets, start_link, []},
                % optional
                restart => permanent,
                % optional
                shutdown => 60,
                % optional
                type => worker,
                modules => []
            },
            #{
                id => abduco_services,
                start =>
                    {abduco_sup, start_link, [AbducoWorkers]},
                restart => permanent,
                shutdown => 10000,
                type => supervisor,
                modules => [abduco_sup]
            },
            #{
                % mandatory
                id => damage_ae,
                % mandatory
                start => {damage_ae, start_link, []},
                % optional
                restart => permanent,
                % optional
                shutdown => 60,
                % optional
                type => worker,
                modules => [damage_ae]
            },
            #{
                % mandatory
                id => damage_aemdw,
                % mandatory
                start => {damage_ae, start_link, []},
                % optional
                restart => permanent,
                % optional
                shutdown => 60,
                % optional
                type => worker,
                modules => [damage_aemdw]
            },
            #{
                % mandatory
                id => damage_ssh,
                % mandatory
                start => {damage_ssh, start_link, []},
                % optional
                restart => permanent,
                % optional
                shutdown => 60,
                % optional
                type => worker,
                modules => [damage_ssh]
            },
            #{
                % mandatory
                id => damage_nostr,
                % mandatory
                start => {damage_nostr, start_link, []},
                % optional
                restart => permanent,
                % optional
                shutdown => 60,
                % optional
                type => worker,
                modules => [damage_nostr]
            },
            #{
                % mandatory
                id => cln_websocket,
                % mandatory
                start => {cln, start_link, [[ws]]},
                % optional
                restart => permanent,
                % optional
                shutdown => 60,
                % optional
                type => worker,
                modules => []
            },
            #{
                % mandatory
                id => identity_server,
                % mandatory
                start => {identity_server, start_link, []},
                % optional
                restart => permanent,
                % optional
                shutdown => 60,
                % optional
                type => worker,
                modules => []
            },
            #{
                id => lightning_auth_cache,
                start => {lightning_auth_cache, start_link, []},
                restart => permanent,
                shutdown => 60,
                type => worker,
                modules => []
            },
            #{
                id => price_feed,
                start => {price_feed, start_link, []},
                restart => permanent,
                shutdown => 60,
                type => worker,
                modules => []
            },
            damage_ssh_listener:child_spec()
        ] ++ PoolSpecs,
    PoolSpecs1 =
        case application:get_env(damage, market_rules) of
            {ok, Rules} ->
                ?LOG_INFO("Damage market making enabled with rules: ~p~n", [Rules]),
                PoolSpecs0 ++
                    [
                        #{
                            id => damage_mm,
                            start => {damage_mm, start_link, [Rules]},
                            restart => permanent,
                            shutdown => 60,
                            type => worker,
                            modules => []
                        }
                    ];
            Other ->
                ?LOG_INFO("Damage market making disabled ~p~n", [Other]),
                PoolSpecs0
        end,
    ?LOG_DEBUG("Worker definitions ~p~n", [PoolSpecs1]),
    {ok, {SupFlags, PoolSpecs1}}.

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
