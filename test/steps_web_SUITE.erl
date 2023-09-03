-module(steps_web_SUITE).

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
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
    #{env => #{dispatch => init_dispatch(Name)}},
    Config
  ).


end_per_group(Name, _) -> cowboy:stop_listener(Name).

init_dispatch(_) ->
  cowboy_router:compile([{"localhost", [{"/", hello_h, []}]}]).

step_get_request(TestConfig) ->
  {ok, _} =
    cowboy:start_clear(
      ?FUNCTION_NAME,
      [{port, 0}],
      #{env => #{dispatch => init_dispatch(TestConfig)}, chunked => false}
    ),
  Port = ranch:get_port(?FUNCTION_NAME),
  Context = maps:new(),
  Context0 =
    steps_web:step(
      [{host, localhost}, {port, Port}],
      Context,
      when_keyword,
      0,
      ["I make a GET request to", "/"],
      []
    ),
  [{status_code, 200}, _, _] = maps:get(response, Context0).


step_post_csrf_request(TestConfig) ->
  {ok, _} =
    cowboy:start_clear(
      ?FUNCTION_NAME,
      [{port, 0}],
      #{env => #{dispatch => init_dispatch(TestConfig)}, chunked => false}
    ),
  Port = ranch:get_port(?FUNCTION_NAME),
  Context = maps:put(headers, [], maps:new()),
  Context0 =
    steps_web:step(
      [{host, localhost}, {port, Port}],
      Context,
      when_keyword,
      0,
      ["I make a CSRF POST request to", "/"],
      []
    ),
  [{status_code, 303}, _, _] = maps:get(response, Context0).


step_post_request(Config) ->
  {ok, _} =
    cowboy:start_clear(
      ?FUNCTION_NAME,
      [{port, 0}],
      #{env => #{dispatch => init_dispatch(Config)}, chunked => false}
    ),
  Port = ranch:get_port(?FUNCTION_NAME),
  Context = maps:new(),
  Context0 =
    steps_web:step(
      [{host, localhost}, {port, Port}],
      Context,
      when_keyword,
      0,
      ["I make a POST request to", "/"],
      []
    ),
  [{status_code, 303}, _, _] = maps:get(response, Context0).


step_store_json_in(TestConfig) ->
  {ok, _} =
    cowboy:start_clear(
      ?FUNCTION_NAME,
      [{port, 0}],
      #{env => #{dispatch => init_dispatch(TestConfig)}, chunked => false}
    ),
  Port = ranch:get_port(?FUNCTION_NAME),
  TestId = <<"testid">>,
  Context =
    maps:put(
      response,
      [{status_code, 200}, maps:new(), {body, jsx:encode(#{id => TestId})}],
      maps:new()
    ),
  Context0 =
    steps_web:step(
      [{host, localhost}, {port, Port}],
      Context,
      then_keyword,
      0,
      ["I store the JSON at path", "$.id", "in", "installid"],
      []
    ),
  TestId = maps:get(installid, Context0).
