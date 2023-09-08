-module(steps_web).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

-export([step/6]).

response_to_list({StatusCode, Headers, Body}) ->
  [{status_code, StatusCode}, {headers, Headers}, {body, Body}].

gun_post(Config, Context, Path, Headers, Data) ->
  {host, Host} = lists:keyfind(host, 1, Config),
  {port, Port} = lists:keyfind(port, 1, Config),
  {ok, ConnPid} = gun:open(Host, Port),
  ?debugFmt("Data : ~p", [Data]),
  StreamRef = gun:post(ConnPid, Path, Headers, Data),
  case gun:await(ConnPid, StreamRef) of
    {response, fin, Status, Headers0} ->
      logger:debug("POST Response: ~p", [Status]),
      maps:put(response, response_to_list({Status, Headers0, <<"">>}), Context);

    {response, nofin, Status, Headers0} ->
      {ok, Body} = gun:await_body(ConnPid, StreamRef),
      logger:debug("POST Response: ~p", [Body]),
      maps:put(response, response_to_list({Status, Headers0, Body}), Context);

    Default -> logger:debug("POST Response: ~p", [Default])
  end.


gun_get(Config, Context, Path, Headers) ->
  {host, Host} = lists:keyfind(host, 1, Config),
  {port, Port} = lists:keyfind(port, 1, Config),
  {ok, ConnPid} = gun:open(Host, Port),
  StreamRef = gun:get(ConnPid, Path, Headers),
  case gun:await(ConnPid, StreamRef) of
    {response, fin, Status, Headers0} ->
      maps:put(response, response_to_list({Status, Headers0, ""}), Context);

    {response, nofin, Status, Headers0} ->
      {ok, Body} = gun:await_body(ConnPid, StreamRef),
      logger:debug("GET Response: ~s~n", [Body]),
      maps:put(response, response_to_list({Status, Headers0, Body}), Context)
  end.


step(Config, Context, when_keyword, _N, ["I make a GET request to", Path], _) ->
  %io:format("DEBUG step_when I make a GET request to ~p ~n~p ~n", [Url,_Given]),
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
  gun_post(
    Config,
    Context,
    Path,
    [
      {<<"accept">>, "application/json"},
      {<<"user-agent">>, "revolver/1.0"},
      {<<"content-type">>, "application/json"}
    ],
    Data
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
  ["the json at path", Path, "must be", Json],
  _
) ->
  case maps:get(response, Context) of
    [{status_code, _}, _Headers, {body, Body}] ->
      Json0 = list_to_binary(Json),
      case ejsonpath:q(Path, jsx:decode(Body, [return_maps])) of
        {[Json0 | _], _} -> Context;

        UnExpected ->
          maps:put(
            fail,
            damage_utils:strf(
              "the json at path ~p is not ~p, it is ~p.",
              [Path, Json, UnExpected]
            )
          )
      end;

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
  maps:put(headers, {list_to_binary(Header), list_to_binary(Value)}, Context),
  logger:debug("Header Set: ~p", [Context]),
  Context;

step(_Config, Context, given_keyword, _N, ["I store cookies"], _) ->
  [_, _StatusCode, {headers, Headers}, _Body] = maps:get(response, Context),
  logger:debug("Response Headers:  ~p", [Headers]),
  Cookies =
    lists:foldl(
      fun
        ({<<"Set-Cookie">>, Header}, Acc) -> [Acc | Header];
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
  end.
