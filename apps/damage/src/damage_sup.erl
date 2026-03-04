%%-------------------------------------------------------------------
%% @doc damage top level supervisor.
%% @end
%% https://erlang.org/doc/man/supervisor.html
%%%-------------------------------------------------------------------

-module(damage_sup).
-behaviour(supervisor).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% Read configured pools (fallback to [])
    Pools =
        case application:get_env(damage, pools) of
            {ok, V} when is_list(V) -> V;
            _ -> []
        end,

    AbducoWorkers =
        case application:get_env(damage, abduco_workers) of
            {ok, V0} when is_list(V0) -> V0;
            _ -> []
        end,

    %% Build poolboy child specs *but do not start them until the end*
    PoolSpecs =
        [
            poolboy:child_spec(
                Name,
                [{name, {local, Name}}, {worker_module, Name}] ++ SizeArgs,
                WorkerArgs
            )
         || {Name, SizeArgs, WorkerArgs} <- Pools
        ],

    %% Start order matters: put providers before consumers.
    %% Strategy rest_for_one: if an early child dies, later (dependent) ones restart.
    SupFlags = {one_for_one, 10, 10},
    %SupFlags = #{strategy => rest_for_one, intensity => 10, period => 10},

    Core =
        [
            #{
                id => schedule_index,
                start => {damage_schedule_index, start_link, []},
                restart => permanent,
                shutdown => 10000,
                type => supervisor,
                modules => []
            },
            #{
                id => abduco_services,
                start => {abduco_sup, start_link, [AbducoWorkers]},
                restart => permanent,
                shutdown => 10000,
                type => supervisor,
                modules => [abduco_sup]
            },
            %% 1) prerequisites & caches
            #{
                id => secrets,
                start => {secrets, start_link, []},
                restart => permanent,
                shutdown => 60000,
                type => worker,
                modules => [secrets]
            },
            #{
                id => identity_server,
                start => {identity_server, start_link, []},
                restart => permanent,
                shutdown => 60000,
                type => worker,
                modules => [identity_server]
            },
            #{
                id => lightning_auth_cache,
                start => {lightning_auth_cache, start_link, []},
                restart => permanent,
                shutdown => 60000,
                type => worker,
                modules => [lightning_auth_cache]
            },

            %% 2) services that others call during boot (MUST precede pools)
            #{
                id => price_feed,
                start => {price_feed, start_link, []},
                restart => permanent,
                shutdown => 60000,
                type => worker,
                modules => [price_feed]
            },

            %% 3) the rest of your workers that don't depend on pools
            #{
                id => cln_websocket,
                start => {cln_ws_mgr, start_link, [[ws]]},
                restart => permanent,
                shutdown => 60000,
                type => worker,
                modules => [cln, cln_ws_mgr]
            },
            #{
                id => damage_ssh,
                start => {damage_ssh, start_link, []},
                restart => permanent,
                shutdown => 60000,
                type => worker,
                modules => [damage_ssh]
            },
            #{
                id => damage_ae,
                start => {damage_ae, start_link, []},
                restart => permanent,
                shutdown => 60000,
                type => worker,
                modules => [damage_ae]
            },
            #{
                id => damage_aemdw,
                start => {damage_aemdw, start_link, []},
                restart => permanent,
                shutdown => 60000,
                type => worker,
                modules => [damage_aemdw]
            },
            #{
                id => damage_l402,
                start => {damage_l402, start_link, []},
                restart => permanent,
                shutdown => 60000,
                type => worker,
                modules => [cln, cln_ws_mgr, damage_l402]
            },

            %% 4) supervisors that may create pools/workers relying on the above
            #{
                id => liquidity_ltr_server,
                start => {liquidity_ltr_server, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [liquidity_ltr_server]
            },
            #{
                id => damage_mm_sup,
                start => {damage_mm_sup, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => supervisor,
                modules => [damage_mm_sup]
            },
            {damage_hwmon,
                {damage_hwmon, start_link, [
                    #{
                        interval_ms => 5000,
                        timeout_ms => 1500,
                        use_ets => true,
                        sink => fun damage_hwmon_sink:emit/1
                    }
                ]},
                permanent, 5000, worker, [damage_hwmon]},
            #{
                id => damage_node_registry,
                start => {damage_node_registry, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [damage_node_registry]
            },
            %% 5) listeners
            git_ssh_listener:child_spec()
        ],

    %% 6) finally: append Poolboy pools LAST so their workers prepopulate after price_feed is up
    AllChildren = Core ++ PoolSpecs,
    %?LOG_DEBUG("Child specs (ordered): ~p", [AllChildren]),

    {ok, {SupFlags, AllChildren}}.
