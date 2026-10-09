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
    Pools0 = application:get_env(ecai, pools, []),
    Pools = maybe_ensure_ecai_chat_pool(Pools0),
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
    %% Snapshot state follows the shared ECAI XDG state layout.
    SnapPath = ecai_paths:index_snapshot_path(),
    ok = ecai_paths:ensure_parent(SnapPath),
    Interval = application:get_env(ecai, index_snapshot_ms, 60000),
    PoolSpecs0 =
        maybe_ingest_specs() ++
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
                    id => ecai_wikimedia_search_server,
                    start => {ecai_wikimedia_search_server, start_link, []},
                    restart => permanent,
                    shutdown => 30000,
                    type => worker,
                    modules => [ecai_wikimedia_search_server]
                },
                #{
                    id => ecai_blender,
                    start => {ecai_blender, start_link, []},
                    restart => permanent,
                    shutdown => 60,
                    type => worker,
                    modules => []
                },
                #{
                    id => wikipedia_loader,
                    start => {ecai_wikipedia_loader, start_link, []},
                    restart => permanent,
                    shutdown => 60,
                    type => worker,
                    modules => []
                }
            ] ++
            indexing_rewards_specs() ++
            indexing_pool_specs() ++
            code_security_specs() ++
            marketplace_specs() ++
            vulnerability_monitor_specs() ++
            PoolSpecs,
    ?LOG_DEBUG("Worker definitions ~p~n", [PoolSpecs0]),
    {ok, {SupFlags, PoolSpecs0}}.

%% Funding/settlement is an explicit, operator-configured opt-in. CLN is
%% contacted only after a deliberate API operation, never during supervisor init.
indexing_rewards_specs() ->
    case application:get_env(ecai, index_rewards_enabled, false) of
        true -> [#{id => ecai_index_rewards, start => {ecai_index_rewards, start_link, []},
                   restart => permanent, shutdown => 30000, type => worker,
                   modules => [ecai_index_rewards]}];
        false -> [];
        Invalid -> erlang:error({invalid_configuration, index_rewards_enabled, Invalid})
    end.

indexing_pool_specs() ->
    case application:get_env(ecai, index_pool_enabled, false) of
        true ->
            true = application:get_env(ecai, index_rewards_enabled, false),
            [#{id => ecai_index_pool, start => {ecai_index_pool, start_link, []},
               restart => permanent, shutdown => 30000, type => worker,
               modules => [ecai_index_pool]}];
        false -> [];
        Invalid -> erlang:error({invalid_configuration, index_pool_enabled, Invalid})
    end.

%% The experimental chunk-job ledger is disabled by default and is NOT durable.
marketplace_specs() ->
    case application:get_env(ecai, marketplace_enabled, false) of
        true ->
            [#{id => ecai_jobs_srv,
               start => {ecai_jobs_srv, start_link, []},
               restart => permanent, shutdown => 5000,
               type => worker, modules => [ecai_jobs_srv]}];
        false -> [];
        Invalid -> erlang:error({invalid_configuration, marketplace_enabled, Invalid})
    end.

code_security_specs() ->
    case application:get_env(ecai, code_security_enabled, true) of
        true ->
            [
                #{
                    id => ecai_code_security_sup,
                    start => {ecai_code_security_sup, start_link, []},
                    restart => permanent,
                    shutdown => infinity,
                    type => supervisor,
                    modules => [ecai_code_security_sup]
                }
            ];
        false ->
            [];
        Invalid ->
            erlang:error({invalid_configuration, code_security_enabled, Invalid})
    end.

vulnerability_monitor_specs() ->
    Interval = application:get_env(ecai, vulnerability_scan_interval_ms, 60000),
    RescanUnchanged = application:get_env(ecai, vulnerability_rescan_unchanged, false),
    [
        ecai_vuln_monitor:child_spec(#{
            app => App,
            interval_ms => Interval,
            rescan_unchanged => RescanUnchanged
        })
     || App <- [damage, ecai, erm]
    ].

maybe_ingest_specs() ->
    case application:get_env(ecai, ingest_wal_enabled, false) of
        true ->
            [
                #{
                    id => ecai_ingest_sup,
                    start => {ecai_ingest_sup, start_link, []},
                    restart => permanent,
                    shutdown => infinity,
                    type => supervisor,
                    modules => [ecai_ingest_sup]
                }
            ];
        false ->
            [];
        Invalid ->
            erlang:error({invalid_configuration, ingest_wal_enabled, Invalid})
    end.

maybe_ensure_ecai_chat_pool(Pools) ->
    case application:get_env(ecai, ecai_chat_enabled, true) of
        true -> ensure_ecai_chat_pool(Pools);
        false -> Pools
    end.

ensure_ecai_chat_pool(Pools) ->
    case lists:keymember(ecai_chat, 1, Pools) of
        true ->
            Pools;
        false ->
            Pools ++ [default_ecai_chat_pool()]
    end.

default_ecai_chat_pool() ->
    Host = application:get_env(ecai, ecai_chat_ollama_host, "localhost"),
    Port = application:get_env(ecai, ecai_chat_ollama_port, 11434),
    Model = application:get_env(ecai, ecai_chat_ollama_model, <<"qwen3-coder:30b">>),
    TopK = application:get_env(ecai, ecai_chat_top_k, 8),

    {
        ecai_chat,
        [
            {size, 1},
            {max_overflow, 0}
        ],
        [
            {ollama_host, Host},
            {ollama_port, Port},
            {ollama_model, Model},
            {top_k, TopK}
        ]
    }.
