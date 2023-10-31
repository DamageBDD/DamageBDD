-module(steps_webdrv).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

-export([step/6]).
-export([test/0]).

-define(CHROMEDRIVER, "http://localhost:9515/").

ensure_session(Config, Context) ->
  case maps:get(chromedriver, Context, none) of
    none ->
      {chromedriver, ChromeDriver} = lists:keyfind(chromedriver, 1, Config),
      {ok, WebDriverPid} =
        webdrv_session:start_session(
          default,
          ChromeDriver,
          webdrv_cap:default_chrome(),
          10000
        ),
      maps:put(chromedriver, WebDriverPid, Context);

    _ -> Context
  end.


step(_Config, Context, and_keyword, _N, ["I open the site", _Site], _) ->
  Context;

step(_Config, Context, and_keyword, _N, ["I open the url", _Url], _) -> Context;

step(Config, Context0, given_keyword, _N, ["the page url is not", Url], _) ->
  Context = ensure_session(Config, Context0),
  case webdrv_session:get_url(default) of
    Url ->
      Url0 = list_to_binary(Url),
      maps:put(fail, <<"Page url is ", Url0>>, Context);

    _Other -> Context
  end.


test() ->
  {ok, _Pid} =
    webdrv_session:start_session(
      test,
      ?CHROMEDRIVER,
      webdrv_cap:default_chrome(),
      10000
    ),
  ?debugFmt("test get_url ~p", [webdrv_session:get_url(test)]),
  webdrv_session:set_url(test, "http://www.random.org/integers/"),
  {ok, Emin} = webdrv_session:find_element(test, "name", "min"),
  webdrv_session:clear_element(test, Emin),
  webdrv_session:send_value(test, Emin, "5"),
  {ok, Emax} = webdrv_session:find_element(test, "name", "max"),
  webdrv_session:clear_element(test, Emax),
  webdrv_session:send_value(test, Emax, "15"),
  webdrv_session:submit(test, Emax),
  {ok, PageSource} = webdrv_session:get_page_source(test),
  true = string:str(PageSource, "Here are your random numbers") > 0,
  webdrv_session:stop_session(test).
