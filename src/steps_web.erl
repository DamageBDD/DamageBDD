-module(steps_web).

-export([step/6]).

step(Config, Context, when_keyword, _N, ["I make a GET request to", Url], _) ->
  %io:format("DEBUG step_when I make a GET request to ~p ~n~p ~n", [Url,_Given]),
  {url, ServerUrl} = lists:keyfind(url, 1, Config),
  maps:put(
    response,
    hackney:request(
      get,
      ServerUrl ++ list_to_binary(Url),
      [],
      <<>>,
      [{pool, default}, {with_body, true}]
    ),
    Context
  );

step(Config, Context, when_keyword, _N, ["I make a CSRF form POST request to", Path], Data) ->
  {url, BaseUrl} = lists:keyfind(url, 1, Config),
  Url = list_to_binary(BaseUrl ++ Path),
  {ok, StatusCode, Headers, Body} = hackney:request(get, Url, [], <<>>, [{pool, default}]),
  lager:debug("Status: ~p, Headers: ~p, Body: ~p", [StatusCode, Headers, Body]),
  {_, CSRFToken} = lists:keyfind(<<"X-CSRFToken">>, 1, Headers),
  {_, SessionId} = lists:keyfind(<<"X-SessionID">>, 1, Headers),
  maps:put(
    response,
    hackney:request(
      post,
      Url,
      [
        {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
        {<<"X-CSRFToken">>, CSRFToken},
        {<<"X-SessionID">>, SessionId},
        {<<"Referer">>, Url},
        {<<"X-Requested-with">>, <<"XMLHttpRequest">>}
      ],
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
  [{_, Status0, _, _} | _] = Context,
  true;

step(_Config, Context, then_keyword, _N, ["the json at path", Path, "must be", Json], _) ->
  #{response := {ok, _StatusCode, _Headers, Body}} = Context,
  Json0 = list_to_binary(Json),
  io:format("DEBUG step_then the json at path ~p must be ~p~n~p~n", [Path, Json0, Body]),
  io:format("DEBUG ~p~n", [ejsonpath:q(Path, jsx:decode(Body, [return_maps]))]),
  {[Json0 | _], _} = ejsonpath:q(Path, jsx:decode(Body, [return_maps])),
  %io:format("DEBUG step_then result ~p should NOT have ~p on the page~n", [Body, Json0]),
  true;

step(_Config, Context, then_keyword, _N, ["the response status should be one of", Responses], _) ->
  #{response := {_, StatusCode, _Headers, _Body}} = Context,
  lists:member(StatusCode, lists:map(fun erlang:list_to_integer/1, string:split(Responses, ",")));

step(_Config, Context, then_keyword, _N, ["I print the response"], _) ->
  #{response := {_, _StatusCode, _Headers, Body}} = Context,
  lager:info("Response: ~p", [Body]),
  true.
