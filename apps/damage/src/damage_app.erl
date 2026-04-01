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
    io:setopts(standard_io, [{encoding, utf8}]),
    io:setopts(standard_error, [{encoding, utf8}]),
    Cwd = application:get_env(damage, app_dir, "/opt/damage"),
    ok = file:set_cwd(Cwd),
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

-spec start_phase(atom(), application:start_type(), []) -> ok.
start_phase(start_vanillae, _StartType, []) ->
    ?LOG_INFO("Starting vanillae."),
    %Version = "0.13.9",
    %true = os:putenv("zx_include", filename:join([os:getenv("HOME"), "/zomp/lib/otpr/zx/",Version,"include"])),

    ok = application:ensure_started(base58),
    ok = application:ensure_started(getopt),
    ok = application:ensure_started(eblake2),
    ok = application:ensure_started(aeserialization),
    ok = application:ensure_started(aebytecode),
    ok = application:ensure_started(ec_utils),
    ok = application:ensure_started(syntax_tools),
    ok = application:ensure_started(aesophia),
    application:ensure_started(vanillae),
    {ok, NetworkId} = application:get_env(damage, ae_network_id),
    vanillae:network_id(NetworkId),
    {ok, AeNodes} = application:get_env(damage, ae_nodes),
    AeTls = application:get_env(damage, ae_tls, true),
    Nodes = [{Host, Port} || {Host, Port, _} <- AeNodes],
    vanillae:tls(AeTls),
    ok = vanillae:ae_nodes(Nodes),
    ?LOG_INFO("Started vanillae."),
    ok;
start_phase(start_trails_http, _StartType, []) ->
    ?LOG_INFO("Starting Damage."),
    {ok, _} = application:ensure_all_started(gun),
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
    metrics:init(),
    ?LOG_INFO("Started cowboy.");
start_phase(damage, _StartType, []) ->
    damage_schedule:load_all_schedules(),
    ?LOG_INFO("Started Damage.");
start_phase(register_node, _StartType, []) ->
    ?LOG_INFO("registering node."),
    {ok, Hostname} = inet:gethostname(),
    NodeName = list_to_atom("damage@" ++ Hostname),
    case net_kernel:start([NodeName, longnames]) of
        {ok, _Pid} ->
            ok;
        {error, {already_started, _}} ->
            ok
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
%% --- Essentials setup phase (parity with setup.sh) --------------------------
start_phase(setup_essentials, _StartType, []) ->
    ?LOG_INFO("setup_essentials: starting."),
    DataDir = application:get_env(damage, app_dir, "/var/lib/damage"),
    ok = damage_ipfs:ensure_ipfs_asset(
        "Qmehdmv1CT7qXbmSHp31at6GhkyPhAnj2ePYCfvXzPDkZC",
        filename:join([DataDir, "bin", "lightpanda-x86_64-linux"])
    ),

    ?LOG_INFO("setup_essentials: done."),
    ok.

stop(_State) ->
    ok = cowboy:stop_listener(http),
    application:stop(gun),
    ok.

%% internal functions
