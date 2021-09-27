-module(steps_web_SUITE).

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
-define(CONFIG, [{host, localhost}, {port, 8088}]).

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
  ).


end_per_group(Name, _) -> cowboy:stop_listener(Name).

init_dispatch(_) ->
  cowboy_router:compile([{"localhost", [{"/", hello_h, []}]}]).

step_get_request(_TestConfig) ->
  Context = dict:new(),
  Context0 =
    steps_web:step(
      ?CONFIG,
      Context,
      when_keyword,
      0,
      ["I make a GET request to", "/"],
      []
    ),
  [{status_code, 200}, _, _] = dict:fetch(response, Context0).


step_post_csrf_request(_TestConfig) ->
  Context = dict:store(headers, [], dict:new()),
  Context0 =
    steps_web:step(
      ?CONFIG,
      Context,
      when_keyword,
      0,
      ["I make a CSRF POST request to", "/"],
      []
    ),
  [{status_code, 303}, _, _] = dict:fetch(response, Context0).


step_post_request(Config) ->
  {ok, _} =
    cowboy:start_clear(
      ?FUNCTION_NAME,
      [{port, 8088}],
      #{env => #{dispatch => init_dispatch(Config)}, chunked => false}
    ),
  Context = dict:new(),
  Context0 =
    steps_web:step(
      ?CONFIG,
      Context,
      when_keyword,
      0,
      ["I make a POST request to", "/"],
      []
    ),
  [{status_code, 303}, _, _] = dict:fetch(response, Context0).


step_store_json_in(_TestConfig) ->
    TestId= <<"testid">>,
  Context =
    dict:store(
      response,
      [
        {status_code, 200},
        dict:new(),
        {body, jsx:encode(#{id => TestId})}
      ],
      dict:new()
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
  TestId = dict:fetch(installid, Context0).
