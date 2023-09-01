-module(steps_web_SUITE).

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

step_get_request(_TestConfig) ->
  Context = maps:new(),
  Context0 =
    steps_web:step(
      ?CONFIG,
      Context,
      when_keyword,
      0,
      ["I make a GET request to", "/"],
      []
    ),
  [{status_code, 200}, _, _] = maps:get(response, Context0).


step_post_csrf_request(_TestConfig) ->
  Context = maps:put(headers, [], maps:new()),
  Context0 =
    steps_web:step(
      ?CONFIG,
      Context,
      when_keyword,
      0,
      ["I make a CSRF POST request to", "/"],
      []
    ),
  [{status_code, 303}, _, _] = maps:get(response, Context0).


step_post_request(_Config) ->
  Context = maps:new(),
  Context0 =
    steps_web:step(
      ?CONFIG,
      Context,
      when_keyword,
      0,
      ["I make a POST request to", "/"],
      []
    ),
  [{status_code, 303}, _, _] = maps:get(response, Context0).


step_store_json_in(_TestConfig) ->
  TestId = <<"testid">>,
  Context =
    maps:put(
      response,
      [{status_code, 200}, maps:new(), {body, jsx:encode(#{id => TestId})}],
      maps:new()
    ),
  Context0 =
    steps_web:step(
      ?CONFIG,
      Context,
      then_keyword,
      0,
      ["I store the JSON at path", "$.id", "in", "installid"],
      []
    ),
  TestId = maps:get(installid, Context0).


step_websocket_test(_Config) ->
  Context = maps:new(),
  Context0 =
    steps_web:step(
      ?CONFIG,
      Context,
      given_keyword,
      0,
      ["I open a websocket connection to", "/ws_echo"],
      []
    ),
  Context1 =
    steps_web:step(
      ?CONFIG,
      Context0,
      when_keyword,
      0,
      ["I send data on the websocket"],
      [{test, true}]
    ),
  Context2 =
    steps_web:step(
      ?CONFIG,
      Context1,
      when_keyword,
      0,
      ["I should receive data on the websocket"],
      [{test, true}]
    ),
  [{status_code, 303}, _, _] = maps:get(response, Context2).
