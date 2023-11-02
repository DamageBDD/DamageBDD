-module(steps_web).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

-export([step/6]).
-export([gun_get/4]).

response_to_list({StatusCode, Headers, Body}) ->
  [{status_code, StatusCode}, {headers, Headers}, {body, Body}].

get_gun_config(Config0, Context) ->
  Host = damage_utils:get_context_value(host, Context, Config0),
  Port = damage_utils:get_context_value(port, Context, Config0),
  Config =
    case Port of
      443 -> [{transport, tls} | Config0];
      _ -> Config0
    end,
  Opts =
    case lists:keyfind(transport, 1, Config) of
      false -> #{transport => tcp};
      _ -> #{transport => tls, tls_opts => [{verify, verify_none}]}
    end,
  {ok, ConnPid} = gun:open(Host, Port, maps:put(connect_timeout, 36000, Opts)),
  ConnPid.


gun_post(Config0, Context, Path, Headers, Data) ->
  ConnPid = get_gun_config(Config0, Context),
  ?debugFmt("Data : ~p", [Data]),
  StreamRef = gun:post(ConnPid, Path, Headers, Data),
  case gun:await(ConnPid, StreamRef, 36000) of
    {response, fin, Status, Headers0} ->
      logger:debug("POST Response: ~p", [Status]),
      maps:put(response, response_to_list({Status, Headers0, <<"">>}), Context);

    {response, nofin, Status, Headers0} ->
      {ok, Body} = gun:await_body(ConnPid, StreamRef),
      logger:debug("POST Response: ~p", [Body]),
      maps:put(response, response_to_list({Status, Headers0, Body}), Context);

    Default ->
      logger:debug("POST Response: ~p", [Default]),
      maps:put(fail, damage_utils:strf("POST failed: ~p", [Default]), Context)
  end.


gun_get(Config0, Context, Path, Headers) ->
  ConnPid = get_gun_config(Config0, Context),
  StreamRef = gun:get(ConnPid, Path, Headers),
  case gun:await(ConnPid, StreamRef) of
    {response, fin, Status, Headers0} ->
      maps:put(response, response_to_list({Status, Headers0, ""}), Context);

    {response, nofin, Status, Headers0} ->
      {ok, Body} = gun:await_body(ConnPid, StreamRef),
      maps:put(response, response_to_list({Status, Headers0, Body}), Context)
  end.


gun_options(Config0, Context, Path, Headers) ->
  ConnPid = get_gun_config(Config0, Context),
  StreamRef = gun:options(ConnPid, Path, Headers),
  case gun:await(ConnPid, StreamRef) of
    {response, fin, Status, Headers0} ->
      maps:put(response, response_to_list({Status, Headers0, ""}), Context);

    {response, nofin, Status, Headers0} ->
      {ok, Body} = gun:await_body(ConnPid, StreamRef),
      maps:put(response, response_to_list({Status, Headers0, Body}), Context)
  end.


ejsonpath_match(Path, Data, Expected, Context) ->
  Expected0 =
    case re:run(Expected, "^[0-9]*$") of
      nomatch -> Expected;
      _ -> list_to_integer(Expected)
    end,
  ?debugFmt("Expected ejsonpath match ~p", [Expected0]),
  case catch ejsonpath:q(Path, Data) of
    {[Expected0 | _], _} -> Context;

    UnExpected ->
      Mesg = "the object at path ~p is not ~p, body ~p it is ~p.",
      Args = [Path, Expected0, Data, UnExpected],
      logger:info(Mesg, Args),
      maps:put(fail, damage_utils:strf(Mesg, Args), Context)
  end.


step(
  _Config,
  Context,
  then_keyword,
  _N,
  ["the response must contain text", Contains],
  _
) ->
  [_, _Headers, {body, Body}] = maps:get(response, Context),
  case string:str(binary_to_list(Body), Contains) of
    0 ->
      maps:put(
        fail,
        damage_utils:strf("Response ~p does not contain ~p", [Body, Contains]),
        Context
      );

    _ -> Context
  end;

step(Config, Context, when_keyword, _N, ["I make a GET request to", Path], _) ->
  gun_get(
    Config,
    Context,
    Path,
    [{<<"accept">>, "application/json"}, {<<"user-agent">>, "revolver/1.0"}]
  );

step(
  Config,
  Context,
  when_keyword,
  _N,
  ["I make a POST request to", Path],
  Data
) ->
  Defaults =
    [
      {<<"accept">>, "application/json"},
      {<<"user-agent">>, "revolver/1.0"},
      {<<"content-type">>, "application/json"}
    ],
  Headers =
    proplists:from_map(
      proplists:to_map(
        lists:keymerge(1, maps:get(headers, Context, []), Defaults)
      )
    ),
  ?debugFmt("Test headers ~p data ~p", [Headers, Data]),
  gun_post(Config, Context, Path, Headers, Data);

step(
  Config,
  Context,
  when_keyword,
  _N,
  ["I make a OPTIONS request to", Path],
  _Data
) ->
  gun_options(
    Config,
    Context,
    Path,
    [
      {<<"accept">>, "application/json"},
      {<<"user-agent">>, "revolver/1.0"},
      {<<"content-type">>, "application/json"}
    ]
  );

step(
  Config,
  Context,
  when_keyword,
  _N,
  ["I make a CSRF POST request to", Path],
  Data
) ->
  Headers0 =
    lists:append(
      [
        {<<"accept">>, "application/json"},
        {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
        {<<"Referer">>, Path},
        {<<"X-Requested-with">>, <<"XMLHttpRequest">>}
      ],
      maps:get(headers, Context)
    ),
  Context0 = gun_get(Config, Context, Path, Headers0),
  case maps:get(response, Context0) of
    [StatusCode, {headers, Headers}, Body] ->
      {_, CSRFToken} = lists:keyfind(<<"x-csrftoken">>, 1, Headers),
      {_, SessionId} = lists:keyfind(<<"x-sessionid">>, 1, Headers),
      logger:debug(
        "POSTResponse: ~p:~p:~p:~p:~p",
        [StatusCode, Headers, Body, CSRFToken, SessionId]
      ),
      gun_post(
        Config,
        Context,
        Path,
        lists:append(
          Headers0,
          [{<<"X-CSRFToken">>, CSRFToken}, {<<"X-SessionID">>, SessionId}]
        ),
        Data
      )
  end;

step(
  _Config,
  Context,
  then_keyword,
  _N,
  ["the response status must be", Status],
  _
) ->
  Status0 = list_to_integer(Status),
  case maps:get(response, Context) of
    [{status_code, Status0}, _, _] -> Context;

    [{status_code, Status1}, _, _] ->
      maps:put(
        fail,
        damage_utils:strf(
          "Response status is not ~p, got ~p",
          [Status0, Status1]
        ),
        Context
      );

    Any ->
      maps:put(
        fail,
        damage_utils:strf("Response status is not ~p, got ~p", [Status0, Any]),
        Context
      )
  end;

step(
  _Config,
  Context,
  then_keyword,
  _N,
  ["the yaml at path", Path, "must be", Expected],
  _
) ->
  case maps:get(response, Context) of
    [{status_code, _}, _Headers, {body, Body}] ->
      {ok, [Data]} = fast_yaml:decode(Body, [maps]),
      ejsonpath_match(Path, Data, Expected, Context);

    Dict when is_map(Dict) ->
      ejsonpath_match(Path, jsx:decode(jsx:encode(Dict)), Expected, Context);

    UnExpected ->
      maps:put(
        fail,
        damage_utils:strf("Unexpected response ~p", [UnExpected]),
        Context
      )
  end;

step(
  _Config,
  Context,
  then_keyword,
  _N,
  ["the json at path", Path, "must be", Expected],
  _
) ->
  case maps:get(response, Context) of
    [{status_code, _}, _Headers, {body, Body}] ->
      ejsonpath_match(
        Path,
        jsx:decode(Body, [return_maps]),
        list_to_binary(Expected),
        Context
      );

    Dict when is_map(Dict) ->
      ejsonpath_match(Path, jsx:decode(jsx:encode(Dict)), Expected, Context);

    UnExpected ->
      maps:put(
        fail,
        damage_utils:strf("Unexpected response ~p", [UnExpected]),
        Context
      )
  end;

step(
  _Config,
  Context,
  then_keyword,
  _N,
  ["the response status must be one of", Responses],
  _
) ->
  logger:debug("the response status must be one of ~p.", [Responses]),
  case maps:get(response, Context) of
    [_, {status_code, StatusCode}, _Headers, _Body] ->
      case
      lists:member(
        StatusCode,
        lists:map(fun erlang:list_to_integer/1, string:split(Responses, ","))
      ) of
        true -> Context;

        _ ->
          logger:debug("the response status must be one of ~p.", [StatusCode]),
          maps:put(
            fail,
            damage_utils:strf(
              "Response status ~p is not one of ~p",
              [StatusCode, Responses]
            ),
            Context
          )
      end;

    UnExpected ->
      logger:error("unexpected response in context ~p.", [UnExpected]),
      maps:put(
        fail,
        damage_utils:strf("Unexpected response ~p", [UnExpected]),
        Context
      )
  end;

step(_Config, Context, then_keyword, _N, ["I print the response"], _) ->
  logger:info("Response: ~p", [maps:get(response, Context)]),
  Context;

step(_Config, Context, _Keyword, _N, ["I set", Header, "header to", Value], _) ->
  maps:put(
    headers,
    [{list_to_binary(string:to_lower(Header)), list_to_binary(Value)}],
    Context
  );

step(_Config, Context, given_keyword, _N, ["I store cookies"], _) ->
  [_, _StatusCode, {headers, Headers}, _Body] = maps:get(response, Context),
  logger:debug("Response Headers:  ~p", [Headers]),
  Cookies =
    lists:foldl(
      fun
        ({<<"set-cookie">>, Header}, Acc) -> [Acc | Header];
        (_Other, Acc) -> Acc
      end,
      [],
      Headers
    ),
  logger:debug("Response:  ~p", [Headers, Cookies]),
  maps:put(cookies, Cookies, Context);

step(
  _Config,
  Context,
  then_keyword,
  _N,
  ["I store the JSON at path", Path, "in", Variable],
  _
) ->
  case maps:get(response, Context) of
    [{status_code, 200}, _Headers, {body, Body}] ->
      Variable0 = list_to_atom(Variable),
      case ejsonpath:q(Path, jsx:decode(Body, [return_maps])) of
        {[Json0 | _], _} -> maps:put(Variable0, Json0, Context);

        UnExpected ->
          maps:put(
            fail,
            damage_utils:strf(
              "the json at path ~p is not ~p, it is ~p.",
              [Path, Variable, UnExpected]
            ),
            Context
          )
      end;

    UnExpected ->
      maps:put(
        fail,
        damage_utils:strf("Unexpected response ~p", [UnExpected]),
        Context
      )
  end;

step(_Config, Context, given_keyword, _N, ["I am using server", Server], _) ->
  case uri_string:parse(Server) of
    #{port := Port, scheme := _Scheme, path := _Path, host := Host} ->
      maps:put(port, Port, maps:put(host, Host, Context));

    #{scheme := "https", host := Host, path := _Path} ->
      maps:put(port, 443, maps:put(host, Host, Context));

    #{scheme := "http", host := Host, path := _Path} ->
      maps:put(port, 80, maps:put(host, Host, Context));

    #{path := Host} -> maps:put(host, Host, Context)
  end;

step(_Config, Context, given_keyword, _N, ["I set base URL to", URL], _) ->
  maps:put(base_url, URL, Context).


%step(
%  _Config,
%  Context,
%  given_keyword,
%  _N,
%  ["I set BasicAuth username to ", User,"and password to", Password],
%  _
%  )->
%    ok.
%
%
