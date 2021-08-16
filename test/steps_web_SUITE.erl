-module(steps_web_SUITE).

-compile([export_all,nowarn_export_all]).
%-export([all/0, suite/0, step_get_request/1]).

-define(CONFIG, [{host, localhost}, {port, 8080}]).

all() -> [step_get_request].

step_get_request(_TestConfig) ->
  Context = dict:new(),
  Context0 =
    steps_web:step(?CONFIG, Context, when_keyword, 0,["I make a GET request to", "/v4/debug"], []),
  [{status_code, 200}, _, _] = dict:fetch(response, Context0).

step_post_csrf_request(_TestConfig) ->
  Context = dict:new(),
  Context0 =
    steps_web:step(?CONFIG, Context, when_keyword, 0,["I make a GET request to", "/v4/debug"], []),
  [{status_code, 200}, _, _] = dict:fetch(response, Context0).
