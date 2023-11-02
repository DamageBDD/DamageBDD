-module(steps_web_SUITE).

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).

all() -> [{group, http}, {group, https}].

groups() ->
  [
    {
      http,
      [parallel],
      [
        step_get_request,
        step_post_csrf_request,
        step_post_request,
        step_store_json_in,
        step_jsonpath
      ]
    },
    {https, [parallel], [step_get_request_tls]}
  ].

init_per_suite(Config) -> damage_test:init_per_suite(Config).

init_per_group(Name, Config) ->
  damage_test:init_http(
    Name,
    #{env => #{dispatch => init_dispatch(Name)}},
    [
      {host, localhost},
      {feature_dirs, ["../../../../features/", "../features/"]},
      {account, "test"} | Config
    ]
  ).

end_per_group(Name, _) -> cowboy:stop_listener(Name).

end_per_suite(Config) -> damage_test:end_per_suite(Config).

init_dispatch(_) ->
  cowboy_router:compile([{"localhost", [{"/", hello_h, []}]}]).

step_get_request_tls(Config) ->
  Context = maps:new(),
  Context0 =
    steps_web:step(
      Config,
      Context,
      when_keyword,
      0,
      ["I make a GET request to", "/"],
      []
    ),
  [{status_code, 200}, _, _] = maps:get(response, Context0).


step_get_request(Config) ->
  Context = maps:new(),
  Context0 =
    steps_web:step(
      Config,
      Context,
      when_keyword,
      0,
      ["I make a GET request to", "/"],
      []
    ),
  [{status_code, 200}, _, _] = maps:get(response, Context0).


step_post_csrf_request(Config) ->
  Context = maps:put(headers, [], maps:new()),
  Context0 =
    steps_web:step(
      Config,
      Context,
      when_keyword,
      0,
      ["I make a CSRF POST request to", "/"],
      []
    ),
  [{status_code, 303}, _, _] = maps:get(response, Context0).


step_post_request(Config) ->
  Context = maps:new(),
  Context0 =
    steps_web:step(
      Config,
      Context,
      when_keyword,
      0,
      ["I make a POST request to", "/"],
      []
    ),
  [{status_code, 303}, _, _] = maps:get(response, Context0).


step_store_json_in(Config) ->
  TestId = <<"testid">>,
  Context =
    maps:put(
      response,
      [{status_code, 200}, maps:new(), {body, jsx:encode(#{id => TestId})}],
      maps:new()
    ),
  Context0 =
    steps_web:step(
      Config,
      Context,
      then_keyword,
      0,
      ["I store the JSON at path", "$.id", "in", "installid"],
      []
    ),
  TestId = maps:get(installid, Context0).


step_jsonpath(Config) ->
  Context =
    maps:put(
      response,
      #{
        num_open => 6,
        results
        =>
        [
          {22, <<"open">>},
          {80, <<"open">>},
          {443, <<"open">>},
          {8080, <<"open">>},
          {9999, <<"open">>},
          {24800, <<"open">>}
        ]
      },
      maps:new()
    ),
  Context0 =
    steps_web:step(
      Config,
      Context,
      then_keyword,
      0,
      ["the json at path", "$.num_open", "must be", "6"],
      []
    ),
  ok = maps:get(fail, Context0, ok),
  6 = maps:get(num_open, maps:get(response, Context0)).
