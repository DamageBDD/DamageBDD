-module(steps_webdrv_SUITE).

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).

-include_lib("eunit/include/eunit.hrl").

-define(CHROMEDRIVER, "http://localhost:9515/").

all() -> [{group, webdrv}].

groups() -> [{webdrv, [parallel], [step_page_url_is_not]}].

init_per_suite(Config0) ->
  Config =
    [
      {host, localhost},
      {feature_dirs, ["../../../../features/", "../features/"]},
      {account, "test"},
      {chromedriver, ?CHROMEDRIVER} | Config0
    ],
  {chromedriver, ChromeDriver} = lists:keyfind(chromedriver, 1, Config),
  ?debugFmt("Chromedriver ~p", [ChromeDriver]),
  {ok, _WebDriverPid} =
    webdrv_session:start_session(
      default,
      ChromeDriver,
      webdrv_cap:default_chrome(),
      10000
    ),
  damage_test:init_per_suite(Config).


init_per_group(Name, Config) ->
  damage_test:init_http(
    Name,
    #{env => #{dispatch => init_dispatch(Name)}},
    Config
  ).

end_per_group(Name, _) -> cowboy:stop_listener(Name).

end_per_suite(Config) -> damage_test:end_per_suite(Config).

init_dispatch(_) ->
  cowboy_router:compile([{"localhost", [{"/", hello_h, []}]}]).

step_page_url_is_not(Config) ->
  Context = maps:new(),
  Context0 =
    steps_webdrv:step(
      Config,
      Context,
      given_keyword,
      0,
      ["the page url is not", "/"],
      []
    ),
  [{status_code, 200}, _, _] = maps:get(response, Context0).
