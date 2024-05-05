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
      damage_static,
      damage_http,
      damage_publish,
      damage_schedule,
      damage_accounts,
      damage_tests,
      damage_analytics,
      damage_reports,
      damage_ai,
      cowboy_swagger_handler
    ],
  Trails =
    [
      {"/", cowboy_static, {priv_file, damage, "static/dealdamage.html"}},
      {"/static/[...]", cowboy_static, {priv_dir, damage, "static/"}},
      {"/docs/[...]", cowboy_static, {priv_dir, damage, "docs/"}},
      {"/steps.json", cowboy_static, {priv_file, damage, "static/steps.json"}},
      {"/steps.yaml", cowboy_static, {priv_file, damage, "static/steps.yaml"}},
      {"/metrics/[:registry]", prometheus_cowboy2_handler, #{}}
      | trails:trails(Handlers)
    ],
  trails:store(Trails),
  trails:single_host_compile(Trails).


-spec start_phase(atom(), application:start_type(), []) -> ok.
start_phase(start_vanillae, _StartType, []) ->
  logger:info("Starting vanilla."),
  damage_utils:setup_vanillae_deps(),
  {ok, _} = application:ensure_all_started(vanillae),
  ok = vanillae:network_id("ae_uat"),
  {ok, AeNodes} = application:get_env(damage, ae_nodes),
  ok = vanillae:ae_nodes(AeNodes),
  logger:info("Started vanilla."),
  ok;

start_phase(start_trails_http, _StartType, []) ->
  logger:info("Starting Damage."),
  {ok, _} = application:ensure_all_started(fast_yaml),
  {ok, _} = application:ensure_all_started(prometheus),
  {ok, _} = application:ensure_all_started(prometheus_cowboy),
  {ok, _} = application:ensure_all_started(cowboy_telemetry),
  {ok, _} = application:ensure_all_started(erlexec),
  {ok, _} = application:ensure_all_started(throttle),
  {ok, _} = application:ensure_all_started(gen_smtp),
  {ok, _} = application:ensure_all_started(gun),
  {ok, _} = application:ensure_all_started(ssh),
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
        stream_handlers
        =>
        [cowboy_telemetry_h, cowboy_metrics_h, cowboy_stream_h]
      }
    ),
  logger:info("Started cowboy."),
  metrics:init(),
  logger:info("Started Damage."),
  case init:get_plain_arguments() of
    [_, "shell"] ->
      ?LOG_INFO("Sourc sync enabled.", []),
      sync:go();

    _ ->
      ?LOG_INFO("Sourc sync disabled.", []),
      ok
  end,
  ok.


stop(_State) ->
  ok = cowboy:stop_listener(http),
  application:stop(gun),
  ok.

%% internal functions
