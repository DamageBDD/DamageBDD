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
  metrics:init(),
  damage_test:init_http(
    Name,
    #{env => #{dispatch => init_dispatch(Name)}},
    [
      {host, localhost},
      {feature_dirs, ["../../../../features/"]},
      {account, "test"} | Config
    ]
  ).


end_per_group(Name, _) -> cowboy:stop_listener(Name).

init_dispatch(_) ->
  cowboy_router:compile(
    [
      {
        "localhost",
        [
          {"/", hello_h, []},
          {"/echo/:key", echo_h, []},
          {"/api/:key", damage_http, []}
        ]
      }
    ]
  ).

execute_test(TestConfig) ->
  [#{response := [{status_code, 200} | _]} | _] =
    lists:flatten(damage:execute(TestConfig, "localhost")).

execute_http_api_test(TestConfig) ->
  erlang:trace_pattern({damage_http, '_', '_'}, true, [local]),
  [#{response := [{status_code, 200} | _]} | _] =
    damage:execute(TestConfig, "api"),
  erlang:trace(all, false, [call]).
