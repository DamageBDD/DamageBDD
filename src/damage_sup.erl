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
      fun
        ({Name, SizeArgs, WorkerArgs}) ->
          PoolArgs = [{name, {local, Name}}, {worker_module, Name}] ++ SizeArgs,
          poolboy:child_spec(Name, PoolArgs, WorkerArgs)
      end,
      Pools
    ),
  BTCPassword =
    case os:getenv("BTC_PASSWORD") of
      false -> exit(btc_password_env_not_set);
      Other -> Other
    end,
  Home = os:getenv("HOME"),
  {ok, BtcRpcUser} = application:get_env(damage, bitcoin_rpc_user),
  CoreLightningCmd =
    "lightningd --network=bitcoin --log-level=info --addr=0.0.0.0 --grpc-port=10008 --grpc-host=0.0.0.0 --clnrest-port=3010 --clnrest-protocol=http"
    ++
    " --log-file="
    ++
    filename:join([Home, ".local/var/logs/lightning.log"])
    ++
    " --bitcoin-rpcuser="
    ++
    BtcRpcUser
    ++
    " --bitcoin-rpcpassword="
    ++
    BTCPassword,
  logger:info("Starting corelightning ~p~n", [CoreLightningCmd]),
  PoolSpecs0 =
    PoolSpecs ++ [
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
        id => damage_lightning,
        % mandatory
        start => {damage_worker, start_link, [CoreLightningCmd]},
        % optional
        restart => permanent,
        % optional
        shutdown => 60,
        % optional
        type => worker,
        modules => [damage_lightning]
        %},
        %#{
        %  % mandatory
        %  id => lndconnect,
        %  % mandatory
        %  start => {lndconnect, start_link, []},
        %  % optional
        %  restart => permanent,
        %  % optional
        %  shutdown => 60,
        %  % optional
        %  type => worker,
        %  modules => [lndconnect]
      },
      #{
        % mandatory
        id => cln,
        % mandatory
        start => {cln, start_link, []},
        % optional
        restart => permanent,
        % optional
        shutdown => 60,
        % optional
        type => worker,
        modules => [cln]
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
