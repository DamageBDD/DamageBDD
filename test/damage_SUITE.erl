-module(damage_SUITE).

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
-define(CONFIG, [{host, localhost}, {port, 8088}]).

-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).

all() -> [{group, web}].

groups() -> [{web, [parallel], ct_helper:all(?MODULE)}].

init_per_group(Name, Config) ->
  {ok, _} = application:ensure_all_started(ranch),
  {ok, _} = application:ensure_all_started(gun),
  {ok, _} = application:ensure_all_started(cowboy),
  cowboy_test:init_http(
    Name,
    #{env => #{dispatch => init_dispatch(Config)}},
    Config
  ),
  {ok, _} =
    cowboy:start_clear(
      ?FUNCTION_NAME,
      [{port, 8088}],
      #{env => #{dispatch => init_dispatch(Config)}, chunked => false}
    ).


end_per_group(Name, _) -> cowboy:stop_listener(Name).

init_dispatch(_) ->
  cowboy_router:compile(
    [{"localhost", [{"/", hello_h, []}, {"/ws_echo", ws_echo, []}]}]
  ).

execute_test(_TestConfig) ->
  {ok, Config} = file:consult(filename:join("config", "damage.config")),
  ok = damage:execute(Config, "localhost").
