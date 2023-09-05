-module(steps_websockets_SUITE).

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).

all() -> [{group, ws}].

groups() -> [{ws, [parallel], ct_helper:all(?MODULE)}].

init_per_suite(Config) ->
  {ok, _} = application:ensure_all_started(ranch),
  {ok, _} = application:ensure_all_started(gun),
  Routes = [{"/", ws_echo, []}],
  {ok, _} =
    cowboy:start_clear(
      ws,
      [],
      #{
        enable_connect_protocol => true,
        env => #{dispatch => cowboy_router:compile([{'_', Routes}])}
      }
    ),
  Port = ranch:get_port(ws),
  Config0 = [{port, Port} | Config],
  [{host, localhost} | Config0].


end_per_suite(_) -> cowboy:stop_listener(ws).

step_websocket(Config) ->
  Context = maps:new(),
  Context0 =
    steps_websockets:step(
      Config,
      Context,
      given_keyword,
      0,
      ["I open a websocket connection to", "/"],
      []
    ),
  Context1 =
    steps_websockets:step(
      Config,
      Context0,
      when_keyword,
      0,
      ["I send data on the websocket"],
      [{test, true}]
    ),
  Context2 =
    steps_websockets:step(
      Config,
      Context1,
      when_keyword,
      0,
      ["I should receive data on the websocket"],
      [{test, true}]
    ),
  {text, <<"{\"test\":true}">>} = maps:get(response, Context2).
