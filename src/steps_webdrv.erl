-module(steps_webdrv).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

-export([step/6]).
-export([test/0]).
-export([ensure_session/2]).

-define(CHROMEDRIVER, "http://localhost:9515/").

ensure_session(Config, Context) ->
  case catch maps:get(chromedriver, Context, none) of
    none ->
      {chromedriver, ChromeDriver} = lists:keyfind(chromedriver, 1, Config),
      case
      catch
      webdrv_session:start_session(
        default,
        ChromeDriver,
        webdrv_cap:default_chrome(),
        10000
      ) of
        {ok, WebDriverPid} -> maps:put(chromedriver, WebDriverPid, Context);

        {error, {already_started, WebDriverPid}} ->
          maps:put(chromedriver, WebDriverPid, Context);

        {error, {html_error, {failed_connect, Error}}} ->
          logger:error("Webdriver error ~p", [Error]),
          maps:put(
            fail,
            <<"Webdriver error, please try again later.">>,
            Context
          )
      end;

    _WebDriverPid0 -> Context
  end.


step(Config, Context, <<"And">>, _N, ["I click on the link", Link], _) ->
  Context = ensure_session(Config, Context),
  case webdrv_session:click_element(default, Link) of
    Link -> Context;

    _Other ->
      Url0 = list_to_binary(Link),
      maps:put(fail, <<"Page url is ", Url0>>, Context)
  end;

step(_Config, Context, <<"And">>, _N, ["I open the site", _Site], _) ->
  Context;

step(Config, Context, <<"And">>, _N, ["I open the url", Url], _) ->
  Context = ensure_session(Config, Context),
  case webdrv_session:set_url(default, Url) of
    ok -> Context;

    Reason ->
      Msg =
        damage_utils:strf("Failed to open url ~p Reason ~p ", [Url, Reason]),
      logger:error(Msg),
      maps:put(fail, Msg, Context)
  end;

step(
  Config,
  Context,
  <<"Then">>,
  _N,
  ["I expect that the url is", Url],
  _Args
) ->
  Context = ensure_session(Config, Context),
  case webdrv_session:get_url(default) of
    Url -> Context;

    Other ->
      maps:put(
        fail,
        damage_utils:strf("Page url is ~p not ~p", [Url, Other]),
        Context
      )
  end;

step(
  Config,
  Context0,
  <<"Then">>,
  N,
  ["I expect that the url is not", Url],
  Args
) ->
  step(Config, Context0, <<"Given">>, N, ["the page url is not", Url], Args);

step(Config, Context0, <<"Given">>, _N, ["the page url is not", Url], _) ->
  Context = ensure_session(Config, Context0),
  case webdrv_session:get_url(default) of
    Url ->
      Url0 = list_to_binary(Url),
      maps:put(fail, <<"Page url is ", Url0>>, Context);

    _Other -> Context
  end.


test() ->
  %{ok, _Pid} =
  %  webdrv_session:start_session(
  %    test,
  %    ?CHROMEDRIVER,
  %    webdrv_cap:default_chrome(),
  %    10000
  %  ),
  ensure_session([], #{chromedriver => "http://localhost:9515/"}),
  ?debugFmt("test get_url ~p", [webdrv_session:get_url(default)]),
  ensure_session([], #{chromedriver => "http://localhost:9515/"}),
  webdrv_session:set_url(default, "http://www.random.org/integers/"),
  ?debugFmt("default get_url ~p", [webdrv_session:get_url(default)]),
  {ok, Emin} = webdrv_session:find_element(default, "name", "min"),
  webdrv_session:clear_element(default, Emin),
  webdrv_session:send_value(default, Emin, "5"),
  {ok, Emax} = webdrv_session:find_element(default, "name", "max"),
  webdrv_session:clear_element(default, Emax),
  webdrv_session:send_value(default, Emax, "15"),
  webdrv_session:submit(default, Emax),
  {ok, PageSource} = webdrv_session:get_page_source(default),
  true = string:str(PageSource, "Here are your random numbers") > 0,
  webdrv_session:stop_session(default).
