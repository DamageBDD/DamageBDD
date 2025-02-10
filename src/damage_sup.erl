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
    logger:info("Starting workers ~p~n", [Pools]),
    SupFlags = {one_for_one, 10, 10},
    PoolSpecs =
        lists:map(
            fun({Name, SizeArgs, WorkerArgs}) ->
                PoolArgs = [{name, {local, Name}}, {worker_module, Name}] ++ SizeArgs,
                poolboy:child_spec(Name, PoolArgs, WorkerArgs)
            end,
            Pools
        ),
    LightPandaCmd = "bin/lightpanda-x86_64-linux --verbose",
    logger:info("Starting lightpanda ~p~n", [LightPandaCmd]),
    ChromedriverCmd = "chromedriver --port=9515",
    logger:info("Starting chromedriver ~p~n", [ChromedriverCmd]),
    PoolSpecs0 =
        PoolSpecs ++
            [
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
                    start => {cln, start_link, [[]]},
                    % optional
                    restart => permanent,
                    % optional
                    shutdown => 60,
                    % optional
                    type => worker,
                    modules => [cln]
                },
                #{
                    % mandatory
                    id => kyc_server,
                    % mandatory
                    start => {kyc_server, start_link, []},
                    % optional
                    restart => permanent,
                    % optional
                    shutdown => 60,
                    % optional
                    type => worker,
                    modules => [kyc_server]
                },
                #{
                    % mandatory
                    id => lightpanda,
                    % mandatory
                    start => {damage_worker, start_link, [LightPandaCmd]},
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
                    id => chromedriver,
                    % mandatory
                    start => {damage_worker, start_link, [ChromedriverCmd]},
                    % optional
                    restart => permanent,
                    % optional
                    shutdown => 60,
                    % optional
                    type => worker,
                    modules => []
                }
            ],
    logger:info("Worker definitions ~p~n", [PoolSpecs0]),
    {ok, {SupFlags, PoolSpecs0}}.

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
