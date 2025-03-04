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
-export([get_trails/0]).

-include_lib("kernel/include/logger.hrl").

start(_StartType, _StartArgs) -> damage_sup:start_link().

get_trails() ->
    Handlers =
        [
            damage_auth,
            damage_context,
            damage_domains,
            damage_webhooks,
            damage_static,
            damage_http,
            damage_market,
            damage_schedule,
            damage_accounts,
            damage_tests,
            damage_analytics,
            damage_reports,
            damage_ai,
            lnaddress,
            cowboy_swagger_handler,
            lightning_auth
        ],
    Trails =
        [
            {"/", cowboy_static, {priv_file, damage, "static/dealdamage.html"}},
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

-spec start_phase(atom(), application:start_type(), []) -> ok.
start_phase(start_vanillae, _StartType, []) ->
    logger:info("Starting vanilla."),
    damage_ae:setup_vanillae_deps(),
    {ok, _} = application:ensure_all_started(vanillae),
    {ok, AeNodes} = application:get_env(damage, ae_nodes),
    ok = vanillae:ae_nodes([{Host, Port} || {Host, Port, _} <- AeNodes]),
    logger:info("Started vanilla."),
    ok;
start_phase(start_trails_http, _StartType, []) ->
    logger:info("Starting Damage."),
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(fast_yaml),
    {ok, _} = application:ensure_all_started(prometheus),
    {ok, _} = application:ensure_all_started(prometheus_cowboy),
    {ok, _} = application:ensure_all_started(cowboy_telemetry),
    {ok, _} = application:ensure_all_started(erlexec),
    {ok, _} = application:ensure_all_started(throttle),
    {ok, _} = application:ensure_all_started(gen_smtp),
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
    damage_ssh:start(),
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
    ?LOG_INFO("Started cowboy."),
    metrics:init(),
    damage_schedule:load_all_schedules(),
    damage_ae:start_batch_spend_timer(),
    ?LOG_INFO("Started Damage.");
start_phase(register_node, _StartType, []) ->
    logger:info("registering node."),
    {ok, Hostname} = inet:gethostname(),
    NodeName = list_to_atom("damage@" ++ Hostname),
    {ok, _Pid} = net_kernel:start([NodeName, longnames]),
    ok;
start_phase(start_sync, _StartType, []) ->
    logger:info("Starting sync."),
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
start_phase(os_tune, _StartType, []) ->
    logger:info("Tuning os."),
    {ok, _} = exec:run("ulimit -n 1000000", [sync]),
    ok.

stop(_State) ->
    ok = cowboy:stop_listener(http),
    application:stop(gun),
    ok.

%% internal functions
