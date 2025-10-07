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
    get_trails/0,
    setup_vanillae_deps/0
]).

-include_lib("kernel/include/logger.hrl").

start(_StartType, _StartArgs) -> damage_sup:start_link().

get_trails() ->
    Handlers =
        [
            damage_context,
            damage_domains,
            damage_webhooks,
            damage_static,
            damage_http,
            damage_install_http,
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
            damage_dashboard
        ],
    Trails =
        [
            %{"/", cowboy_static, {priv_file, damage, "static/dealdamage.html"}},
            {"/terms", cowboy_static, {priv_file, damage, "static/terms.html"}},
            {"/.well-known/security.txt", cowboy_static,
                {priv_file, damage, "static/.well-known/security.txt"}},
            {"/.well-known/security.txt.asc", cowboy_static,
                {priv_file, damage, "static/.well-known/security.txt.asc"}},
            {"/token_tos", cowboy_static, {priv_file, damage, "static/token_tos.html"}},
            {"/static/[...]", cowboy_static, {priv_dir, damage, "static/"}},
            {"/docs/[...]", cowboy_static, {priv_dir, damage, "docs/"}},
            {"/steps.json", cowboy_static, {priv_file, damage, "static/steps.json"}},
            {"/steps.yaml", cowboy_static, {priv_file, damage, "static/steps.yaml"}},
            {"/metrics/[:registry]", prometheus_cowboy2_handler, #{}},
            {"/ws/auth", lightning_auth_ws, #{}}
            | trails:trails(Handlers)
        ],
    trails:store(Trails),
    trails:single_host_compile(Trails).

setup_vanillae_deps() ->
    %true = code:add_path("_checkouts/vanillae/ebin"),
    %true = code:add_path("_checkouts/vw/ebin"),
    ZxBin = filename:join(os:getenv("HOME"), "zomp/zx"),
    Vanillae =
        "otpr-vanillae-" ++ lists:droplast(os:cmd(ZxBin ++ " latest otpr-vanillae")),
    Deps = string:lexemes(os:cmd(ZxBin ++ " list deps " ++ Vanillae), "\n"),
    ZX =
        "otpr-zx-" ++
            lists:nth(2, string:lexemes(lists:droplast(os:cmd(ZxBin ++ " --version")), " ")),
    Packages = [ZX, Vanillae | Deps],
    ZompLib = filename:join(os:getenv("HOME"), "zomp/lib"),
    ?LOG_DEBUG("Packages paths ~p", [Packages]),
    Converted =
        [string:join(string:lexemes(Package, "-"), "/") || Package <- Packages],
    PackagePaths =
        [filename:join([ZompLib, PackagePath, "ebin"]) || PackagePath <- Converted],
    ?LOG_DEBUG("Code paths ~p", [PackagePaths]),
    ok = code:add_paths(PackagePaths).

-spec start_phase(atom(), application:start_type(), []) -> ok.
start_phase(start_vanillae, _StartType, []) ->
    ?LOG_INFO("Starting vanilla."),
    %Version = "0.13.9",
    %true = os:putenv("zx_include", filename:join([os:getenv("HOME"), "/zomp/lib/otpr/zx/",Version,"include"])),
    setup_vanillae_deps(),
    application:ensure_started(vanillae),
    {ok, NetworkId} = application:get_env(damage, ae_network_id),
    vanillae:network_id(NetworkId),
    {ok, AeNodes} = application:get_env(damage, ae_nodes),
    {ok, AeTls} = application:get_env(damage, ae_tls),
    Nodes = [{Host, Port} || {Host, Port, _} <- AeNodes],
    vanillae:tls(AeTls),
    ok = vanillae:ae_nodes(Nodes),
    ?LOG_INFO("Started vanilla."),
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
    {ok, WsPort} = application:get_env(damage, port),
    {ok, _} =
        cowboy:start_clear(
            http,
            %[{ip, {0, 0, 0, 0}}, {port, WsPort}],
            [{port, WsPort}],
            #{
                env => #{dispatch => Dispatch},
                metrics_callback => fun prometheus_cowboy2_instrumenter:observe/1,
                stream_handlers =>
                    [cowboy_telemetry_h, cowboy_metrics_h, cowboy_stream_h]
            }
        ),
    metrics:init(),
    ?LOG_INFO("Started cowboy.");
start_phase(damage, _StartType, []) ->
    damage_schedule:load_all_schedules(),
    damage_ae:start_batch_spend_timer(),
    ?LOG_INFO("Started Damage.");
start_phase(register_node, _StartType, []) ->
    ?LOG_INFO("registering node."),
    {ok, Hostname} = inet:gethostname(),
    NodeName = list_to_atom("damage@" ++ Hostname),
    {ok, _Pid} = net_kernel:start([NodeName, longnames]),
    ok;
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

    ok = damage_utils:ensure_group("damage"),
    ok = damage_utils:ensure_user("damage", "damage"),

    ok = damage_utils:ensure_dir("/var/lib/damagebdd/sshtest_user/.ssh/"),
    ok = damage_utils:chown_r("/var/lib/damagebdd/", "damage:damage"),

    ok = damage_utils:ensure_dir("/var/lib/damagebdd/ssh_daemon/"),
    ok = damage_utils:ensure_ssh_host_key("/var/lib/damagebdd/ssh_daemon/ssh_host_rsa_key"),

    ok = damage_ipfs:ensure_ipfs_asset(
        "Qmehdmv1CT7qXbmSHp31at6GhkyPhAnj2ePYCfvXzPDkZC",
        "bin/lightpanda-x86_64-linux"
    ),

    ?LOG_INFO("setup_essentials: done."),
    ok;
start_phase(os_tune, _StartType, []) ->
    ?LOG_INFO("Tuning os."),
    {ok, _} = exec:run("ulimit -n 100000", [sync]),
    ok.

stop(_State) ->
    ok = cowboy:stop_listener(http),
    application:stop(gun),
    ok.

%% internal functions
