-module(steps_http).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").

-export([step/6]).
-export([gun_get/4]).
-export([test_get_headers/0]).

-define(DEFAULT_WAIT_SECONDS, 3).
-define(DEFAULT_NUM_ATTEMPTS, 3).
-define(DEFAULT_HTTP_TIMEOUT, 60000).
-define(
  DEFAULT_HEADERS,
  [
    {<<"accept">>, "application/json,text/html"},
    {<<"user-agent">>, "damagebdd/1.0"},
    {<<"content-type">>, "application/json"}
  ]
).

get_headers(Context, DefaultHeaders) ->
  maps:to_list(
    maps:merge(
      maps:from_list(DefaultHeaders),
      maps:from_list(maps:get(headers, Context, []))
    )
  ).

response_to_list({StatusCode, Headers, Body}) ->
  [{status_code, StatusCode}, {headers, Headers}, {body, Body}].

get_gun_config(Config0, Context) ->
  Host = damage_utils:get_context_value(host, Context, Config0),
  Port = damage_utils:get_context_value(port, Context, Config0),
  case damage_domains:is_allowed_domain(Host) of
    true ->
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
      Opts0 =
        case maps:get(basic_auth, Context, none) of
          none -> Opts;

          {User, Pass} ->
            maps:put(username, User, maps:put(password, Pass, Context))
        end,
      {ok, ConnPid} =
        gun:open(
          Host,
          Port,
          maps:put(connect_timeout, ?DEFAULT_HTTP_TIMEOUT, Opts0)
        ),
      ConnPid;

    _ ->
          throw(
        <<
          "Host is not allowed please add dns txt record with dns token from a valid account. Check documentation at https://damagebdd.com/manual.html"
        >>
      )
  end.


gun_await(ConnPid, StreamRef, Context) ->
  case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
    {response, fin, Status, Headers} ->
      maps:put(response, response_to_list({Status, Headers, <<"">>}), Context);

    {response, nofin, Status, Headers} ->
      {ok, Body} = gun:await_body(ConnPid, StreamRef),
      maps:put(response, response_to_list({Status, Headers, Body}), Context);

    Default ->
      maps:put(fail, damage_utils:strf("Gun request failed: ~p", [Default]), Context)
  end.


gun_post(Config0, Context, Path, Headers, Data) ->
  ConnPid = get_gun_config(Config0, Context),
  StreamRef = gun:post(ConnPid, Path, Headers, Data),
  ?LOG_DEBUG("Post ~p", [Headers]),
  gun_await(ConnPid, StreamRef, Context).


gun_patch(Config0, Context, Path, Headers, Data) ->
  ConnPid = get_gun_config(Config0, Context),
  StreamRef = gun:patch(ConnPid, Path, Headers, Data),
  gun_await(ConnPid, StreamRef, Context).


gun_put(Config0, Context, Path, Headers, Data) ->
  ConnPid = get_gun_config(Config0, Context),
  StreamRef = gun:put(ConnPid, Path, Headers, Data),
  gun_await(ConnPid, StreamRef, Context).


gun_get(Config0, Context, Path, Headers) ->
  ConnPid = get_gun_config(Config0, Context),
  StreamRef = gun:get(ConnPid, Path, Headers),
  gun_await(ConnPid, StreamRef, Context).


gun_options(Config0, Context, Path, Headers) ->
  ConnPid = get_gun_config(Config0, Context),
  StreamRef = gun:options(ConnPid, Path, Headers),
  gun_await(ConnPid, StreamRef, Context).


gun_head(Config0, Context, Path, Headers) ->
  ConnPid = get_gun_config(Config0, Context),
  StreamRef = gun:head(ConnPid, Path, Headers),
  gun_await(ConnPid, StreamRef, Context).


gun_delete(Config0, Context, Path, Headers) ->
  ConnPid = get_gun_config(Config0, Context),
  StreamRef = gun:delete(ConnPid, Path, Headers),
  gun_await(ConnPid, StreamRef, Context).


retry_get(Config, Context, Path, Headers, N, WaitSecs, Attempt) ->
  ConnPid = get_gun_config(Config, Context),
  StreamRef = gun:get(ConnPid, Path, Headers),
  case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
    {response, nofin, Status, Headers} ->
      {ok, Body} = gun:await_body(ConnPid, StreamRef),
      {ok, {Status, Headers, Body}};

    Default ->
      case Attempt < N of
        true ->
          % Wait in milliseconds
          timer:sleep(WaitSecs * 1000),
          retry_get(Config, Context, Path, Headers, N, WaitSecs, Attempt + 1);

        false ->
          {
            fail,
            damage_utils:strf(
              "Maximum attempts reached. Exiting. ~p",
              [Default]
            )
          }
      end
  end.


retry_get_ejsonmatch(
  Config,
  Context,
  JsonPath,
  Expected,
  Path,
  Headers,
  N,
  WaitSecs,
  Attempt
) ->
  case retry_get(Config, Context, Path, Headers, N, WaitSecs, Attempt) of
    {ok, {_Status, _Headers, Body}} ->
      Context0 = ejsonpath_match(JsonPath, Body, Expected, Context),
      case maps:get(fail, Context0, none) of
        none -> Context0;

        _ ->
          retry_get_ejsonmatch(
            Config,
            Context0,
            JsonPath,
            Expected,
            Path,
            Headers,
            N,
            WaitSecs,
            Attempt
          )
      end;

    _ ->
      retry_get_ejsonmatch(
        Config,
        Context,
        JsonPath,
        Expected,
        Path,
        Headers,
        N,
        WaitSecs,
        Attempt
      )
  end.


ejsonpath_match(Path, Data, Expected, Context) ->
  Expected0 =
    case re:run(Expected, "^[0-9]*$") of
      nomatch -> Expected;
      _ -> list_to_integer(Expected)
    end,
  case catch ejsonpath:q(Path, Data) of
    {[Expected0 | _], _} -> Context;

    UnExpected ->
      Mesg = "the object at path ~p is not ~p, body ~p it is ~p.",
      Args = [Path, Expected0, Data, UnExpected],
      ?LOG_INFO(Mesg, Args),
      maps:put(fail, damage_utils:strf(Mesg, Args), Context)
  end.


step(
  _Config,
  Context,
  <<"Then">>,
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

step(Config, Context, <<"When">>, _N, ["I make a GET request to", Path], _) ->
  gun_get(
    Config,
    Context,
    string:concat(maps:get(base_url, Context, ""), Path),
    get_headers(Context, ?DEFAULT_HEADERS)
  );

step(Config, Context, <<"When">>, _N, ["I make a POST request to", Path], Data) ->
  Path0 = string:concat(maps:get(base_url, Context, ""), Path),
  ?LOG_DEBUG("POST REQUEST HEADers ~p", [Context]),
  Headers = get_headers(Context, ?DEFAULT_HEADERS),
  ?LOG_DEBUG("POST HEADERS ~p", [Headers]),
  gun_post(Config, Context, Path0, Headers, Data);

step(Config, Context, <<"When">>, _N, ["I make a PATCH request to", Path], Data) ->
  Headers = get_headers(Context, ?DEFAULT_HEADERS),
  Path0 = string:concat(maps:get(base_url, Context, ""), Path),
  gun_patch(Config, Context, Path0, Headers, Data);

step(Config, Context, <<"When">>, _N, ["I make a PUT request to", Path], Data) ->
  Headers = get_headers(Context, ?DEFAULT_HEADERS),
  Path0 = string:concat(maps:get(base_url, Context, ""), Path),
  gun_put(Config, Context, Path0, Headers, Data);

step(
  Config,
  Context,
  <<"When">>,
  _N,
  ["I make a OPTIONS request to", Path],
  _Data
) ->
  gun_options(
    Config,
    Context,
    string:concat(maps:get(base_url, Context, ""), Path),
    get_headers(Context, ?DEFAULT_HEADERS)
  );

step(
  Config,
  Context,
  <<"When">>,
  _N,
  ["I make a DELETE request to", Path],
  _Data
) ->
  gun_delete(
    Config,
    Context,
    string:concat(maps:get(base_url, Context, ""), Path),
    get_headers(Context, ?DEFAULT_HEADERS)
  );

step(
  _Config,
  Context,
  <<"When">>,
  _N,
  ["I make a TRACE request to", _Path],
  _Data
) ->
  maps:put(fail, <<"Step not implemented">>, Context);

step(
  Config,
  Context,
  <<"When">>,
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
      ?LOG_DEBUG(
        "POSTResponse: ~p:~p:~p:~p:~p",
        [StatusCode, Headers, Body, CSRFToken, SessionId]
      ),
      gun_post(
        Config,
        Context,
        string:concat(maps:get(base_url, Context, ""), Path),
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
  <<"Then">>,
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
  <<"Then">>,
  _N,
  ["the yaml at path", Path, "must be", Expected0],
  _
) ->
  Expected = list_to_binary(Expected0),
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
  <<"Then">>,
  _N,
  ["the json at path", Path, "must be", Expected0],
  _
) ->
  Expected = list_to_binary(Expected0),
  case maps:get(response, Context) of
    [{status_code, _}, _Headers, {body, Body}] ->
      case catch jsx:decode(Body, [return_maps]) of
        {'EXIT', Msg} ->
          ?LOG_ERROR("Unexpected ~p ~p", [Body, Msg]),
          maps:put(fail, damage_utils:strf("invalid json: ~p", [Body]), Context);

        Json -> ejsonpath_match(Path, Json, Expected, Context)
      end;

    Dict when is_map(Dict) ->
      ejsonpath_match(Path, jsx:decode(jsx:encode(Dict)), Expected, Context);

    UnExpected ->
      Msg = damage_utils:strf("Unexpected response ~p", [UnExpected]),
      ?LOG_ERROR("Unexpected ~p", [Msg]),
      maps:put(fail, Msg, Context)
  end;

step(
  _Config,
  Context,
  <<"Then">>,
  _N,
  ["the response status must be one of", Statuses],
  _
) ->
  ?LOG_DEBUG("the response status must be one of ~p.", [Statuses]),
  case maps:get(response, Context) of
    [_, {status_code, StatusCode}, _Headers, _Body] ->
      case
      lists:member(
        StatusCode,
        lists:map(fun erlang:list_to_integer/1, string:split(Statuses, ","))
      ) of
        true -> Context;

        _ ->
          ?LOG_DEBUG("the response status must be one of ~p.", [StatusCode]),
          maps:put(
            fail,
            damage_utils:strf(
              "Response status ~p is not one of ~p",
              [StatusCode, Statuses]
            ),
            Context
          )
      end;

    UnExpected ->
      ?LOG_ERROR("unexpected response in context ~p.", [UnExpected]),
      maps:put(
        fail,
        damage_utils:strf("Unexpected response ~p", [UnExpected]),
        Context
      )
  end;

step(
  _Config,
  Context,
  <<"Then">>,
  _N,
  ["the", Var, "header should be", Value],
  _
) ->
  case maps:get(response, Context) of
    {_, Headers, _} ->
      case lists:keyfind(Var, 1, Headers) of
        {Var, Value} -> Context;

        Unexpected ->
          maps:put(
            fail,
            damage_utils:strf(
              "the ~p header is not ~p, it is ~p",
              [Var, Value, Unexpected]
            )
          )
      end;

    Unexpected ->
      maps:put(
        fail,
        damage_utils:strf(
          "the ~p header is not ~p, request failed ~p",
          [Var, Value, Unexpected]
        )
      )
  end;

step(Config, Context, <<"Then">>, N, ["I print the response"], _) ->
  Response = maps:get(response, Context, <<"">>),
  formatter:format(
    Config,
    print,
    {
      <<"Then">>,
      N,
      ["Response:"],
      list_to_binary(damage_utils:strf("~p", [Response])),
      Context,
      success
    }
  ),
  Context;

step(_Config, Context, _Keyword, _N, ["I set", Header, "header to", Value], _) ->
  Headers0 = maps:from_list(get_headers(Context, ?DEFAULT_HEADERS)),
  Headers =
    maps:to_list(
      maps:put(list_to_binary(string:to_lower(Header)), Value, Headers0)
    ),
  maps:put(headers, Headers, Context);

step(_Config, Context, <<"Given">>, _N, ["I store cookies"], _) ->
  [_, _StatusCode, {headers, Headers}, _Body] = maps:get(response, Context),
  ?LOG_DEBUG("Response Headers:  ~p", [Headers]),
  Cookies =
    lists:foldl(
      fun
        ({<<"set-cookie">>, Header}, Acc) -> [Acc | Header];
        (_Other, Acc) -> Acc
      end,
      [],
      Headers
    ),
  ?LOG_DEBUG("Response:  ~p", [Headers, Cookies]),
  maps:put(cookies, Cookies, Context);

step(
  _Config,
  Context,
  <<"Then">>,
  _N,
  ["I store the JSON at path", Path, "in", Variable],
  _
) ->
  case maps:get(response, Context) of
    [{status_code, 200}, _Headers, {body, Body}] ->
      Variable0 = list_to_atom(Variable),
      case ejsonpath:q(Path, jsx:decode(Body, [return_maps])) of
        {[Json0 | _], _} ->
          ?LOG_DEBUG("storing json at path ~p json ~p", [Path, Json0]),
          maps:put(Variable0, Json0, Context);

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
      ?LOG_DEBUG("failed to store json at path ~p error ~p", [Path, UnExpected]),
      maps:put(
        fail,
        damage_utils:strf("Unexpected response ~p", [UnExpected]),
        Context
      )
  end;

step(_Config, Context, <<"Given">>, _N, ["I am using server", Server], _) ->
  case uri_string:parse(Server) of
    #{port := Port, scheme := _Scheme, path := _Path, host := Host} ->
      maps:put(port, Port, maps:put(host, Host, Context));

    #{scheme := "https", host := Host, path := _Path} ->
      maps:put(port, 443, maps:put(host, Host, Context));

    #{scheme := "http", host := Host, path := _Path} ->
      maps:put(port, 80, maps:put(host, Host, Context));

    #{path := Host} -> maps:put(host, Host, Context)
  end;

step(_Config, Context, <<"Given">>, _N, ["I set base URL to", URL], _) ->
  maps:put(base_url, URL, Context);

step(
  _Config,
  Context,
  <<"Given">>,
  _N,
  ["I set BasicAuth username to ", User, "and password to", Password],
  _
) ->
  maps:put(basic_auth, {User, Password}, Context);

step(
  _Config,
  Context,
  <<"Given">>,
  _N,
  ["I use query OAuth with key=", Key, "and secret=", Secret],
  _
) ->
  maps:put(oauth_query_auth, {Key, Secret}, Context);

step(
  _Config,
  Context,
  <<"Given">>,
  _N,
  ["I use header OAuth with key=", Key, "and secret=", Secret],
  _
) ->
  maps:put(oauth_header_auth, {Key, Secret}, Context);

step(_Config, Context, _, _N, ["I set the variable", Variable, "to", Value], _) ->
  maps:put(Variable, Value, Context);

step(_Config, Context, _, _N, ["I do not want to verify server certificate"], _) ->
  maps:put(verify_ssl, false, Context);

step(
  Config,
  Context,
  _,
  _N,
  [
    "I keep sending GET requests to",
    UrlPathSegment,
    "until JSON at path",
    JsonPath,
    "is"
  ],
  Args
) ->
  NAttempts = maps:get(n_attempts, Context, ?DEFAULT_NUM_ATTEMPTS),
  retry_get_ejsonmatch(
    Config,
    Context,
    JsonPath,
    Args,
    UrlPathSegment,
    [],
    NAttempts,
    ?DEFAULT_WAIT_SECONDS,
    0
  );

step(Config, Context, _, _N, ["I make a HEAD request to", Path], _) ->
  gun_head(
    Config,
    Context,
    string:concat(maps:get(base_url, Context, ""), Path),
    get_headers(Context, ?DEFAULT_HEADERS)
  );

step(_Config, Context, _, _N, ["the JSON should be"], Args) ->
  case maps:get(response, Context) of
    {_Status, _Headers, Args} -> Context;

    Unexpected ->
      maps:put(
        fail,
        damage_utils:strf("The JSON is ~p not ~p", [Unexpected, Args]),
        Context
      )
  end;

step(
  _Config,
  Context,
  _,
  _N,
  ["the variable", Variable, "should be equal to JSON", Value],
  _
) ->
  Value = maps:get(Variable, Context, none);

step(
  _Config,
  Context,
  _,
  _N,
  ["the variable", Variable, "should be equal to JSON"],
  Args
) ->
  Args = maps:get(Variable, Context, none);

step(
  Config,
  Context,
  KeyWord,
  LineNo,
  ["the JSON at path", JsonPath, "should be"],
  Args
) ->
  step(
    Config,
    Context,
    KeyWord,
    LineNo,
    ["the json at path", JsonPath, "must be", Args],
    <<>>
  ).


test_get_headers() ->
  Context =
    #{
      port => 8080,
      host => "localhost",
      modified => <<"20240424223344">>,
      headers
      =>
      [
        {<<"accept">>, "application/json"},
        {<<"content-type">>, "application/json"},
        {<<"user-agent">>, "damagebdd/1.0"},
        {<<"content-type">>, "application/x-yaml"}
      ],
      step_found => false,
      example_context_variable
      =>
      #{value => <<"non redaacted">>, secret => false},
      example_context_variable_redacted
      =>
      #{value => <<"ths will be redaacted">>, secret => true}
    },
  Headers = get_headers(Context, ?DEFAULT_HEADERS),
  logger:info("Headers ~p", [Headers]).
