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
         || {Name, SizeArgs, WorkerArgs} <- Pools, Name =/= cln
        ],

    %% Start order matters: put providers before consumers.
    %% Strategy rest_for_one: if an early child dies, later (dependent) ones restart.
    %SupFlags = {rest_for_one, 10, 10},
    SupFlags = {one_for_one, 10, 10},

    Core =
        [
            #{
                id => damage_settings,
                start => {damage_settings, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [damage_settings]
            },
            #{
                id => damage_theme_store,
                start => {damage_theme_store, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [damage_theme_store]
            },
            #{
                id => secrets,
                start => {secrets, start_link, []},
                restart => permanent,
                shutdown => 60000,
                type => worker,
                modules => [secrets]
            }
        ] ++ ecai_logging_specs() ++
            [
                #{
                    id => nostr_pool,
                    start => {
                        nostr_pool,
                        start_link,
                        [#{relays => nostr_pool:default_relays(#{})}]
                    },
                    restart => permanent,
                    shutdown => 60000,
                    type => worker,
                    modules => [nostr_pool]
                },
                #{
                    id => damage_enterprise_invoices,
                    start => {damage_enterprise_invoices, start_link, []},
                    restart => permanent,
                    shutdown => 10000,
                    type => worker,
                    modules => [damage_enterprise_invoices]
                },
                #{
                    id => damage_browser_auth,
                    start => {damage_browser_auth, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [damage_browser_auth]
                },
                #{
                    id => damage_webdriver_sup,
                    start => {damage_webdriver_sup, start_link, []},
                    restart => permanent,
                    shutdown => infinity,
                    type => supervisor,
                    modules => [damage_webdriver_sup]
                },
                #{
                    id => damage_bdd_service,
                    start => {damage_bdd_service, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [damage_bdd_service]
                },
                #{
                    id => damage_firecracker,
                    start => {damage_firecracker, start_link, []},
                    restart => permanent,
                    shutdown => 15000,
                    type => worker,
                    modules => [damage_firecracker]
                },
                #{
                    id => damage_schedule_v2,
                    start => {damage_schedule_v2, start_link, []},
                    restart => permanent,
                    shutdown => 10000,
                    type => worker,
                    modules => [damage_schedule_v2]
                },
                #{
                    id => damage_quickstart_store,
                    start => {damage_quickstart_store, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [damage_quickstart_store]
                },
                #{
                    id => abduco_services,
                    start => {abduco_sup, start_link, [AbducoWorkers]},
                    restart => permanent,
                    shutdown => 10000,
                    type => supervisor,
                    modules => [abduco_sup]
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
                #{
                    id => price_feed,
                    start => {price_feed, start_link, []},
                    restart => permanent,
                    shutdown => 60000,
                    type => worker,
                    modules => [price_feed]
                },
                %% CLN is behind a fault-containment manager. damage_cln:init/1
                %% always succeeds and boots the CLN subtree asynchronously, so
                %% missing/broken CLN cannot prevent DamageBDD from starting.
                #{
                    id => damage_cln,
                    start => {damage_cln, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [damage_cln]
                },
                #{
                    id => damage_ssh_tunnel_listener,
                    start => {damage_ssh_tunnel_listener, start_link, []},
                    %% Optional startup failures return ignore; once started,
                    %% supervise the listener normally and restart runtime crashes.
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [damage_ssh_tunnel_listener]
                },
                #{
                    id => damage_ssh_git_listener,
                    start => {damage_ssh_git_listener, start_link, []},
                    %% Optional startup failures return ignore; once started,
                    %% supervise the listener normally and restart runtime crashes.
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [damage_ssh_git_listener]
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
                    id => damage_analytics_store,
                    start => {damage_analytics_store, start_link, []},
                    restart => permanent,
                    shutdown => 10000,
                    type => worker,
                    modules => [damage_analytics_store]
                },
                #{
                    id => damage_analytics_ecai_worker,
                    start => {damage_analytics_ecai_worker, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [damage_analytics_ecai_worker]
                },
                #{
                    id => damage_analytics_indexer,
                    start => {damage_analytics_indexer, start_link, []},
                    restart => permanent,
                    shutdown => 10000,
                    type => worker,
                    modules => [damage_analytics_indexer]
                },
                #{
                    id => damage_balance_cache,
                    start => {damage_balance_cache, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [damage_balance_cache]
                },
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
                %% Cached market history remains readable when quoting is disabled.
                %% Startup opens storage only; HTTP backfill is independently queued.
                #{
                    id => ecai_mm_price_cache,
                    start => {ecai_mm_price_cache, start_link, []},
                    restart => permanent,
                    shutdown => 10000,
                    type => worker,
                    modules => [ecai_mm_price_cache]
                },
                %% Admin Settings can enable/disable the paper engine without
                %% restarting the node. The controller is not a trading worker.
                #{
                    id => ecai_mm_control,
                    start => {ecai_mm_control, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [ecai_mm_control]
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
                #{
                    id => damage_nwc_invoice_watch_sup,
                    start => {damage_nwc_invoice_watch_sup, start_link, []},
                    restart => permanent,
                    shutdown => infinity,
                    type => supervisor,
                    modules => [damage_nwc_invoice_watch_sup]
                },
                #{
                    id => damage_nostr,
                    start => {damage_nostr, start_link, [damage_nostr_nsec]},
                    restart => transient,
                    shutdown => 60000,
                    type => worker,
                    modules => [damage_nostr]
                },
                damage_nsecbunker_sup:child_spec(),
                damage_nsecbunker_handoff:child_spec(),
                #{
                    id => damage_nwc_listener,
                    start => {damage_nwc_listener, start_link, []},
                    restart => permanent,
                    shutdown => infinity,
                    type => worker,
                    modules => [damage_nwc_listener, damage_nwc_listener]
                },
                damage_ipfs_sup:child_spec()
            ],

    %% 6) finally: append Poolboy pools LAST so their workers prepopulate after price_feed is up
    AllChildren = Core ++ tax_children() ++ PoolSpecs,

    {ok, {SupFlags, AllChildren}}.

%% Tax reporting is opt-in and keeps the journal on local private storage.
%% Do not contact CLN or price APIs in supervisor child start functions.
%% The backfill worker starts asynchronously once the node has booted.
tax_children() ->
    case application:get_env(damage, tax_enabled, false) of
        true ->
            DataDir0 = application:get_env(damage, tax_data_dir, "/var/lib/damage/tax"),
            DataDir =
                case DataDir0 of
                    B when is_binary(B) -> binary_to_list(B);
                    L when is_list(L) -> L
                end,
            Journal = filename:join(DataDir, "journal.jsonl"),
            [
                #{
                    id => damage_tax_store,
                    start => {damage_tax_store, start_link, [Journal]},
                    restart => permanent,
                    shutdown => 10000,
                    type => worker,
                    modules => [damage_tax_store]
                },
                #{
                    id => damage_tax_jobs,
                    start => {damage_tax_jobs, start_link, []},
                    restart => permanent,
                    shutdown => 10000,
                    type => worker,
                    modules => [damage_tax_jobs]
                }
            ];
        _ ->
            []
    end.

ecai_logging_specs() ->
    case application:get_env(damage, ecai_log_learning_enabled, true) of
        true ->
            [damage_ecai_log_bridge:child_spec(#{})];
        false ->
            [];
        Invalid ->
            erlang:error({invalid_configuration, ecai_log_learning_enabled, Invalid})
    end.
