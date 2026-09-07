%%%-------------------------------------------------------------------
%% @doc damage public API
%% @end
%%%-------------------------------------------------------------------

-module(damage_app).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-behaviour(application).

-export([start/2, stop/1]).
-export([start_phase/3]).
-export([
    get_trails/0
]).

-include_lib("kernel/include/logger.hrl").

start(_StartType, _StartArgs) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(public_key),
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(cowlib),
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(inets),
    io:setopts(standard_io, [{encoding, utf8}]),
    io:setopts(standard_error, [{encoding, utf8}]),
    case application:get_env(damage, app_dir) of
        undefined ->
            ok;
        {ok, Cwd} ->
            ok = file:set_cwd(Cwd)
    end,
    damage_sup:start_link().

get_trails() ->
    Handlers =
        [
            damage_context,
            damage_domains,
            damage_webhooks,
            damage_static,
            damage_http,
            damage_install_http,
            damage_http_unlock,
            damage_market,
            damage_schedule,
            damage_invoicing,
            damage_accounts,
            damage_tests,
            damage_analytics,
            damage_reports,
            damage_ai,
            lnaddress,
            cowboy_swagger_handler,
            lightning_auth,
            damage_doc,
            damage_swap_options_http,
            damage_dashboard,
            damage_nwc_http,
            damage_liquidity_http,
            damage_node_admin_http
        ],
    Trails =
        [
            %{"/", cowboy_static, {priv_file, damage, "static/dealdamage.html"}},
            {"/terms", cowboy_static, {priv_file, damage, "static/terms.html"}},
            {"/activity", cowboy_static, {priv_file, damage, "static/activity.html"}},
            {"/x", x_redirect_h, #{}},
            {"/samples/features/index.json", cowboy_static,
                {priv_file, damage, "static/samples.json"}},
            {"/.well-known/security.txt", cowboy_static,
                {priv_file, damage, "static/.well-known/security.txt"}},
            {"/.well-known/security.txt.asc", cowboy_static,
                {priv_file, damage, "static/.well-known/security.txt.asc"}},
            {"/token_tos", cowboy_static, {priv_file, damage, "static/token_tos.html"}},
            {"/static/[...]", cowboy_static, {priv_dir, damage, "static/"}},
            {"/scripts/[...]", cowboy_static, {priv_dir, damage, "scripts/"}},
            {"/docs/[...]", cowboy_static, {priv_dir, damage, "docs/"}},
            {"/steps.json", cowboy_static, {priv_file, damage, "static/steps.json"}},
            {"/steps.yaml", cowboy_static, {priv_file, damage, "static/steps.yaml"}},
            {"/metrics/[:registry]", prometheus_cowboy2_handler, #{}},
            {"/ws/auth", lightning_auth_ws, #{}},
            {"/proc_bw/[...]", proc_bw_http, #{}}
            | trails:trails(Handlers)
        ],
    trails:store(Trails),
    trails:single_host_compile(Trails).

-spec start_phase(atom(), application:start_type(), []) -> ok | {error, term()}.
start_phase(start_vanillae, _StartType, []) ->
    ?LOG_INFO("Starting vanillae."),

    lists:foreach(
        fun(App) -> ok = application:ensure_started(App) end,
        [
            base58,
            getopt,
            eblake2,
            aeserialization,
            aebytecode,
            ec_utils,
            syntax_tools,
            aesophia,
            gun,
            vanillae
        ]
    ),

    {ok, NetworkId} = application:get_env(damage, ae_network_id),
    vanillae:network_id(NetworkId),

    {ok, AeNodes0} = application:get_env(damage, ae_nodes),
    AeNodes = [{Host, Port} || {Host, Port, _PathPrefix} <- AeNodes0],
    ok = vanillae:ae_nodes(AeNodes),

    case application:get_env(damage, ae_tls) of
        {ok, ForceTls} ->
            vanillae:tls(ForceTls),
            ?LOG_INFO(
                "Started vanillae network_id=~p tls_override=~p nodes=~p.",
                [NetworkId, ForceTls, AeNodes0]
            );
        undefined ->
            Tls0 = lists:any(fun({_Host, Port}) -> Port =:= 443 end, AeNodes),
            vanillae:tls(Tls0),
            ?LOG_INFO(
                "Started vanillae network_id=~p tls=auto_by_port nodes=~p.",
                [NetworkId, AeNodes0]
            )
    end,

    ok;
start_phase(start_trails_http, _StartType, []) ->
    ?LOG_INFO("Starting Damage."),
    {ok, _} = application:ensure_all_started(yamerl),
    {ok, _} = application:ensure_all_started(prometheus_cowboy),
    {ok, _} = application:ensure_all_started(cowboy_telemetry),
    {ok, _} = application:ensure_all_started(throttle),
    {ok, _} = application:ensure_all_started(gen_smtp),
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(ssh),
    ok = damage_nwc_balance_cache:start(),
    {ok, _} =
        gen_smtp_server:start(
            damage_smtp_server,
            [
                {
                    sessionoptions,
                    [{allow_bare_newlines, fix}, {callbackoptions, [{parse, true}]}]
                }
            ]
        ),
    Dispatch = get_trails(),
    WsPort = application:get_env(damage, port, 4888),
    WsIp = application:get_env(damage, ip, {127, 0, 0, 1}),
    {ok, _} =
        cowboy:start_clear(
            http,
            [{ip, WsIp}, {port, WsPort}],
            #{
                env => #{dispatch => Dispatch},
                metrics_callback => fun prometheus_cowboy2_instrumenter:observe/1,
                stream_handlers =>
                    [cowboy_telemetry_h, cowboy_metrics_h, cowboy_stream_h],
                middlewares => [cowboy_router, throttling_middleware, cowboy_handler],
                idle_timeout => 90_000_000,
                request_timeout => 90_000_000
            }
        ),
    damage_metrics:init(),
    ?LOG_INFO("Started cowboy.");
start_phase(damage, _StartType, []) ->
    damage_schedule:load_all_schedules(),
    ?LOG_INFO("Started Damage.");
start_phase(register_node, _StartType, []) ->
    ?LOG_INFO("registering node."),
    case ensure_distribution() of
        {ok, NodeName, NameDomain, StartState} ->
            ?LOG_INFO("Erlang distribution ~p as ~p using ~p", [
                StartState, NodeName, NameDomain
            ]),
            ok;
        {error, Reason} ->
            ?LOG_ERROR("Could not start Erlang distribution: ~p", [Reason]),
            {error, Reason}
    end;
start_phase(start_sync, _StartType, []) ->
    ?LOG_INFO("Starting sync."),
    case init:get_plain_arguments() of
        [_, "shell" | _] ->
            ?LOG_INFO("Sourc sync enabled.", []),
            sync:go();
        Cause ->
            ?LOG_INFO("Sourc sync disabled. ~p", [Cause]),
            ok
    end,
    ?LOG_INFO("Sync Ready."),
    ok;
start_phase(init_chain, _StartType, []) ->
    ?LOG_INFO("Scheduling async node registry bootstrap."),
    spawn(fun() ->
        ?LOG_INFO("Initializing node registry only."),
        case damage_contract_bootstrap:bootstrap_node_only() of
            {ok, Info} ->
                ?LOG_INFO("Node bootstrap initialized: ~p", [Info]);
            {error, Reason} ->
                ?LOG_ERROR("Node bootstrap failed: ~p", [Reason])
        end
    end),
    ok;
%% --- Essentials setup phase (parity with setup.sh) --------------------------
start_phase(setup_essentials, _StartType, []) ->
    ?LOG_INFO("setup_essentials: scheduling async setup."),
    spawn(fun() ->
        DataDir =
            case application:get_env(damage, app_dir) of
                undefined ->
                    {ok, Cwd} = file:get_cwd(),
                    Cwd;
                {ok, Cwd} ->
                    Cwd
            end,
        _ = damage_ipfs:ensure_ipfs_asset(
            "Qmehdmv1CT7qXbmSHp31at6GhkyPhAnj2ePYCfvXzPDkZC",
            filename:join([DataDir, "bin", "lightpanda-x86_64-linux"])
        ),
        ?LOG_INFO("setup_essentials: done.")
    end),
    ok.

stop(_State) ->
    ok = cowboy:stop_listener(http),
    application:stop(gun),
    ok.

%% internal functions

ensure_distribution() ->
    case node() of
        nonode@nohost ->
            start_distribution();
        RunningNode ->
            validate_running_distribution(RunningNode)
    end.

start_distribution() ->
    case inet:gethostname() of
        {ok, Hostname} ->
            AliveName = damage,
            case configured_name_domain(Hostname) of
                {ok, NameDomain} ->
                    case net_kernel:start(AliveName, #{name_domain => NameDomain}) of
                        {ok, _Pid} ->
                            {ok, node(), NameDomain, started};
                        {error, {already_started, _Pid}} ->
                            validate_running_distribution(node());
                        {error, NetKernelReason} ->
                            {error, {
                                net_kernel_start_failed,
                                AliveName,
                                NameDomain,
                                NetKernelReason
                            }}
                    end;
                {error, _Reason} = Error ->
                    Error
            end;
        {error, HostnameReason} ->
            {error, {hostname_lookup_failed, HostnameReason}}
    end.

configured_name_domain(Hostname) ->
    case application:get_env(damage, node_name_domain, auto) of
        auto ->
            {ok, infer_name_domain(Hostname)};
        shortnames ->
            validate_requested_name_domain(shortnames, Hostname);
        longnames ->
            validate_requested_name_domain(longnames, Hostname);
        Invalid ->
            {error, {invalid_node_name_domain, Invalid, [auto, shortnames, longnames]}}
    end.

infer_name_domain(Hostname) ->
    case lists:member($., Hostname) of
        true -> longnames;
        false -> shortnames
    end.

validate_requested_name_domain(longnames, Hostname) ->
    case lists:member($., Hostname) of
        true -> {ok, longnames};
        false ->
            {error, {longnames_requires_fully_qualified_hostname, Hostname,
                "use shortnames or configure a fully qualified hostname"}}
    end;
validate_requested_name_domain(shortnames, Hostname) ->
    case lists:member($., Hostname) of
        false -> {ok, shortnames};
        true ->
            {error, {shortnames_requires_unqualified_hostname, Hostname}}
    end.

validate_running_distribution(nonode@nohost) ->
    {error, erlang_distribution_not_started};
validate_running_distribution(RunningNode) ->
    case node_host(RunningNode) of
        {ok, Hostname} ->
            case net_kernel:get_state() of
                #{started := Started, name_domain := NameDomain} when
                    Started =/= no,
                    (NameDomain =:= shortnames orelse NameDomain =:= longnames)
                ->
                    validate_running_name_domain(RunningNode, Hostname, NameDomain);
                State ->
                    {error, {invalid_distribution_state, RunningNode, State}}
            end;
        {error, _Reason} = Error ->
            Error
    end.

validate_running_name_domain(RunningNode, Hostname, NameDomain) ->
    case validate_requested_name_domain(NameDomain, Hostname) of
        {ok, NameDomain} -> {ok, RunningNode, NameDomain, already_started};
        {error, Reason} -> {error, {invalid_running_node_name, RunningNode, Reason}}
    end.

node_host(NodeName) ->
    case string:split(atom_to_list(NodeName), "@", all) of
        [_Alive, Hostname] -> {ok, Hostname};
        _ -> {error, {invalid_node_name, NodeName}}
    end.
