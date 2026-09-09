%% Copyright Steven Joseph. SPDX-License-Identifier: Apache-2.0
-module(damage_ipfs_sup).
-behaviour(supervisor).
-export([start_link/0, start_link/1, child_spec/0, init/1]).

start_link() -> start_link(damage_ipfs_config:load()).
start_link(Opts) -> supervisor:start_link({local, ?MODULE}, ?MODULE, Opts).
child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [?MODULE]
    }.

init(Opts) ->
    C = damage_ipfs_config:normalize(Opts),
    %% All init functions perform local work only. An offline daemon is a
    %% degraded service, not a reason to bring down the DamageBDD application.
    Modules = [
        damage_ipfs_store,
        damage_ipfs_client,
        damage_ipfs_fetcher,
        damage_ipfs_pinner,
        damage_ipfs_reconciler,
        damage_ipfs_health,
        damage_ipfs_peers
    ],
    Children = [
        #{
            id => M,
            start => {M, start_link, [C]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => callbacks(M)
        }
     || M <- Modules
    ],
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 30}, Children}}.

callbacks(damage_ipfs_client) -> [damage_ipfs_queue];
callbacks(damage_ipfs_fetcher) -> [damage_ipfs_queue];
callbacks(damage_ipfs_store) -> [damage_ipfs_store];
callbacks(_) -> [damage_ipfs_loop].
