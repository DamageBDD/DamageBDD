-module(damage_SUITE).

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
-define(CONFIG,).

-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).

all() -> [{group, web}].

groups() -> [{web, [parallel], ct_helper:all(?MODULE)}].

init_per_group(Name, Config) ->
  {ok, _} = application:ensure_all_started(ranch),
  {ok, _} = application:ensure_all_started(gun),
  {ok, _} = application:ensure_all_started(cowboy),
  {ok, _} = application:ensure_all_started(prometheus),
  application:ensure_all_started(metrics),
  application:ensure_all_started(exometer),
  metrics:init(),
  cowboy_test:init_http(
    Name,
    #{env => #{dispatch => init_dispatch(Name)}},
    Config
  ).


end_per_group(Name, _) -> cowboy:stop_listener(Name).

init_dispatch(_) ->
  cowboy_router:compile(
    [{"localhost", [{"/", hello_h, []}, {"/ws_echo", ws_echo, []}]}]
  ).

execute_test(TestConfig) ->
  {ok, _} =
    cowboy:start_clear(
      ?FUNCTION_NAME,
      [{port, 0}],
      #{env => #{dispatch => init_dispatch(TestConfig)}, chunked => false}
    ),
  Port = ranch:get_port(?FUNCTION_NAME),
  ok =
    damage:execute(
      [
        {host, localhost},
        {port, Port},
        {feature_dirs, ["../../../../features/"]},
        {account, "test"}
      ],
      "localhost"
    ).


metrics_test(TestConfig) ->
  {ok, _} =
    cowboy:start_clear(
      ?FUNCTION_NAME,
      [{port, 0}],
      #{env => #{dispatch => init_dispatch(TestConfig)}, chunked => false}
    ),
  Port = ranch:get_port(?FUNCTION_NAME),
  ok =
    damage:execute(
      [
        {host, localhost},
        {port, Port},
        {feature_dirs, ["../../../../features/"]},
        {account, "test"}
      ],
      "metrics"
    ).
