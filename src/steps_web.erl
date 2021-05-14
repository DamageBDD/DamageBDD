-module(steps_web).

-export([step/6]).

step(Config, Context, when_keyword, _N, ["I make a GET request to", Url], _) ->
  %io:format("DEBUG step_when I make a GET request to ~p ~n~p ~n", [Url,_Given]),
  {url, ServerUrl} = lists:keyfind(url, 1, Config),
  dict:store(
    response,
    hackney:request(
      get,
      ServerUrl ++ list_to_binary(Url),
      dict:fetch(headers, Context),
      <<>>,
      [{pool, default}, {with_body, true}]
    ),
    Context
  );

step(Config, Context, when_keyword, _N, ["I make a POST request to", Path], Data) ->
  {url, BaseUrl} = lists:keyfind(url, 1, Config),
  Url = list_to_binary(BaseUrl ++ Path),
  dict:store(
    response,
    hackney:request(post, Url, dict:fetch(headers, Context), Data, [{with_body, true}]),
    Context
  );

step(Config, Context, when_keyword, _N, ["I make a CSRF form POST request to", Path], Data) ->
  {url, BaseUrl} = lists:keyfind(url, 1, Config),
  Url = list_to_binary(BaseUrl ++ Path),
  Headers0 =
    lists:append(
      [
        {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
        {<<"Referer">>, Url},
        {<<"X-Requested-with">>, <<"XMLHttpRequest">>}
      ],
      dict:fetch(headers, Context)
    ),
  {ok, StatusCode, Headers, Body} = hackney:request(get, Url, Headers0, <<>>, [{pool, default}]),
  lager:debug("Status: ~p, Headers: ~p, Body: ~p", [StatusCode, Headers, Body]),
  {_, CSRFToken} = lists:keyfind(<<"X-CSRFToken">>, 1, Headers),
  {_, SessionId} = lists:keyfind(<<"X-SessionID">>, 1, Headers),
  dict:store(
    response,
    hackney:request(
      post,
      Url,
      lists:append(Headers0, [{<<"X-CSRFToken">>, CSRFToken}, {<<"X-SessionID">>, SessionId}]),
      {form, jsx:decode(Data)},
      [
        {
          cookie,
          [
            {<<"csrf_token">>, CSRFToken, [{path, <<"/">>}]},
            {<<"csrftoken">>, CSRFToken, [{path, <<"/">>}]}
          ]
        },
        {with_body, true}
      ]
    ),
    Context
  );

step(_Config, Context, then_keyword, _N, ["the response status must be", Status], _) ->
  Status0 = list_to_integer(Status),
  case dict:fetch(response, Context) of
    {_, Status0, _, _} -> true;

    {_, Status1, _, _} ->
      throw({fail, io_lib:format("Response status is not ~p, got ~p", [Status0, Status1])});

    Any -> throw({fail, io_lib:format("Response status is not ~p, got ~p", [Status0, Any])})
  end;

step(_Config, Context, then_keyword, _N, ["the json at path", Path, "must be", Json], _) ->
  case dict:fetch(response, Context) of
    {_, _StatusCode, _Headers, Body} ->
      Json0 = list_to_binary(Json),
      lager:debug("step_then the json at path ~p must be ~p~n~p~n", [Path, Json0, Body]),
      lager:debug("~p~n", [ejsonpath:q(Path, jsx:decode(Body, [return_maps]))]),
      {[Json0 | _], _} = ejsonpath:q(Path, jsx:decode(Body, [return_maps])),
      true;

    UnExpected -> throw(io_lib:format("Unexpected response ~p", [UnExpected]))
  end;

step(_Config, Context, then_keyword, _N, ["the response status should be one of", Responses], _) ->
  case dict:fetch(response, Context) of
    {_, StatusCode, _Headers, _Body} ->
      case
      lists:member(
        StatusCode,
        lists:map(fun erlang:list_to_integer/1, string:split(Responses, ","))
      ) of
        true -> true;

        _ ->
          throw(
            {fail, io_lib:format("Response status ~p is not one of ~p", [StatusCode, Responses])}
          )
      end;

    UnExpected -> throw(io_lib:format("Unexpected response ~p", [UnExpected]))
  end;

step(_Config, Context, then_keyword, _N, ["I print the response"], _) ->
  {_, _StatusCode, _Headers, Body} = dict:fetch(response, Context),
  lager:debug("Response: ~s", [Body]),
  true;

step(_Config, Context, then_keyword, _N, ["I set the variable ", Variable, " to value ", Value], _) ->
  dict:store(Variable, Value, Context);

step(_Config, Context, _Keyword, _N, ["I set", Header, "header to", Value], _) ->
  dict:append(headers, {list_to_binary(Header), list_to_binary(Value)}, Context);

step(_Config, Context, given_keyword, _N, ["I store cookies"], _) ->
  {_, _StatusCode, Headers, _Body} = dict:fetch(response, Context),
    Cookies = lists:foldl(fun ({<<"Set-Cookie">>, Header}, Acc) -> [Acc|Header] end, [], Headers), 
  lager:debug("Response:  ~p ~s", [Headers, Cookies]).
  %dict:append(headers, {list_to_binary(Header), list_to_binary(Value)}, Context).
